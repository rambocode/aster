const std = @import("std");
const Geometry = @import("geometry.zig").Geometry;
const c = @cImport({
    @cInclude("ghostty/vt.h");
});

// Version-pinned headless extension; no application XCFramework ABI changes.
extern fn ghostty_aster_screen_format_buf(c.GhosttyTerminal, u32, bool, ?[*]u8, usize, *usize) c.GhosttyResult;

extern fn ghostty_aster_cursor_replay_buf(c.GhosttyTerminal, u32, ?[*]u8, usize, *usize) c.GhosttyResult;

extern fn ghostty_aster_saved_modes_buf(c.GhosttyTerminal, ?[*]u8, usize, *usize) c.GhosttyResult;

extern fn session_install_png_decoder() c_int;

extern fn ghostty_aster_image_ids(c.GhosttyTerminal, u32, ?[*]u32, usize, *usize) c.GhosttyResult;

extern fn ghostty_aster_placement_anchor(c.GhosttyTerminal, u32, c.GhosttyKittyGraphicsPlacementIterator, *u32, *u32) c.GhosttyResult;
extern fn ghostty_aster_screen_row_buf(c.GhosttyTerminal, u32, u32, ?[*]u8, usize, *usize) c.GhosttyResult;

extern fn ghostty_aster_graphics_for_screen(c.GhosttyTerminal, u32) ?*anyopaque;

extern fn ghostty_aster_screen_total_rows(c.GhosttyTerminal, u32, *usize) c.GhosttyResult;
extern fn ghostty_aster_placement_render_info(c.GhosttyTerminal, u32, c.GhosttyKittyGraphicsPlacementIterator, c.GhosttyKittyGraphicsImage, *c.GhosttyKittyGraphicsPlacementRenderInfo) c.GhosttyResult;

extern fn ghostty_aster_screen_state_buf(c.GhosttyTerminal, u32, bool, ?[*]u8, usize, *usize) c.GhosttyResult;

/// Actual page allocations charged to retained text history; mixed pages are
/// charged in full. Pool reserves and image pixels are outside this budget.
pub const HistoryUsage = extern struct { rows: usize, charged_bytes: usize, reclaimable_bytes: usize };
/// Serial identifies a page within one screen lifetime; range is zero-based
/// history/screen rows. A mixed page is charged its entire allocation.
pub const HistoryPage = extern struct { serial: u64, first_row: usize, rows: usize, charged_bytes: usize };
extern fn ghostty_aster_history_pages(c.GhosttyTerminal, u32, ?[*]HistoryPage, usize, *usize) c.GhosttyResult;
pub const HistoryTrim = struct { removed_rows: usize, remaining: HistoryUsage };
extern fn ghostty_aster_history_usage(c.GhosttyTerminal, u32, *HistoryUsage) c.GhosttyResult;
extern fn ghostty_aster_history_trim(c.GhosttyTerminal, u32, usize, *usize, *HistoryUsage) c.GhosttyResult;

pub const Image = struct {
    width: u32,
    height: u32,
    channels: u8,
    pixels: []u8,
    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    /// Re-encodes copied pixels as inline Kitty transmissions, never filenames.
    /// Chunks are <=4096 base64 bytes; q=2 prevents replies during restoration.
    pub fn transmission(self: Image, allocator: std.mem.Allocator, id: u32, maximum: usize) ![]u8 {
        if (id == 0 or self.width == 0 or self.height == 0 or (self.channels != 3 and self.channels != 4)) return error.InvalidImageData;
        const expected = try std.math.mul(usize, try std.math.mul(usize, self.width, self.height), self.channels);
        if (self.pixels.len != expected) return error.InvalidImageData;
        const encoder = std.base64.standard.Encoder;
        const encoded_size = encoder.calcSize(self.pixels.len);
        if (encoded_size > maximum) return error.ImageTooLarge;
        const encoded = try allocator.alloc(u8, encoded_size);
        defer allocator.free(encoded);
        _ = encoder.encode(encoded, self.pixels);
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        var offset: usize = 0;
        while (offset < encoded.len) {
            const count = @min(4096, encoded.len - offset);
            const more: u8 = if (offset + count < encoded.len) 1 else 0;
            const header = if (offset == 0)
                try std.fmt.allocPrint(allocator, "\x1b_Ga=t,f={d},s={d},v={d},i={d},q=2,m={d};", .{ @as(u16, self.channels) * 8, self.width, self.height, id, more })
            else
                try std.fmt.allocPrint(allocator, "\x1b_Gq=2,m={d};", .{more});
            defer allocator.free(header);
            if (header.len + count + 2 > maximum - output.items.len) return error.ImageTooLarge;
            try output.appendSlice(allocator, header);
            try output.appendSlice(allocator, encoded[offset..][0..count]);
            try output.appendSlice(allocator, "\x1b\\");
            offset += count;
        }
        return output.toOwnedSlice(allocator);
    }
};

/// Image-pixel coordinates, resolved against decoded image bounds by Ghostty.
/// Zero raw extents mean the remaining image extent; resolved extents are
/// clipped to the image edge. These are source pixels, not viewport coordinates
/// or the rendered destination size.
pub const SourceRectangle = struct { x: u32 = 0, y: u32 = 0, width: u32 = 0, height: u32 = 0 };

pub const Placement = struct {
    image_id: u32,
    placement_id: u32,
    virtual: bool,
    x_offset: u32,
    y_offset: u32,
    columns: u32,
    rows: u32,
    z: i32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
    /// Resolved render source; raw source_* fields above remain unchanged for
    /// protocol replay (including zero/default and oversized extents).
    resolved_source: SourceRectangle = .{},
    pixel_width: u32,
    pixel_height: u32,
    viewport: ?struct { column: i32, row: i32 },
    anchor: ?struct { column: u32, row: u32 },
};

pub const Screen = enum(u32) { primary = 0, alternate = 1 };

/// Owned headless terminal. Keep pinned C ABI types private to this adapter.
/// This object is confined to its session event loop; callers must not copy it.
pub const Terminal = struct {
    handle: c.GhosttyTerminal,

    pub fn init(cols: u16, rows: u16, scrollback: usize) !Terminal {
        if (cols == 0 or rows == 0) return error.InvalidDimensions;
        var handle: c.GhosttyTerminal = null;
        if (c.ghostty_terminal_new(null, &handle, .{
            .cols = cols,
            .rows = rows,
            .max_scrollback = scrollback,
        }) != c.GHOSTTY_SUCCESS) return error.TerminalInitializationFailed;
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Terminal) void {
        c.ghostty_terminal_free(self.handle);
        self.handle = null;
    }

    /// Sink must remain at a stable address until this terminal is destroyed or
    /// another sink is installed. Callbacks only queue bytes, never recurse.
    pub fn setResponseSink(self: *Terminal, sink: *ResponseSink) !void {
        if (c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_USERDATA, sink) != c.GHOSTTY_SUCCESS or
            c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_WRITE_PTY, @ptrCast(&ResponseSink.receive)) != c.GHOSTTY_SUCCESS)
            return error.CallbackConfigurationFailed;
    }

    /// Feeds raw PTY bytes, retaining parser state across partial UTF-8 reads.
    pub fn write(self: *Terminal, bytes: []const u8) void {
        c.ghostty_terminal_vt_write(self.handle, bytes.ptr, bytes.len);
    }

    /// Replays indexed OSC overrides relative to the source theme, leaving
    /// unchanged palette entries client-owned as existing snapshots do. Explicit
    /// effective foreground/background/cursor colors are retained when present;
    /// absent colors do not invent a source theme. Only numeric RGB OSCs escape
    /// this boundary, never terminal-supplied strings. Does not mutate the VT.
    pub fn paletteReplay(self: *const Terminal, allocator: std.mem.Allocator, maximum: usize) ![]u8 {
        var current: [256]c.GhosttyColorRgb = undefined;
        var defaults: [256]c.GhosttyColorRgb = undefined;
        if (c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_COLOR_PALETTE, &current) != c.GHOSTTY_SUCCESS or
            c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, &defaults) != c.GHOSTTY_SUCCESS) return error.TerminalReadFailed;
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        var buffer: [80]u8 = undefined;
        for (current, defaults, 0..) |color, original, index| {
            if (color.r == original.r and color.g == original.g and color.b == original.b) continue;
            const bytes = try std.fmt.bufPrint(&buffer, "\x1b]4;{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\", .{ index, color.r, color.g, color.b });
            if (bytes.len > maximum - output.items.len) return error.FrameTooLarge;
            try output.appendSlice(allocator, bytes);
        }
        const keys = [_]c.GhosttyTerminalData{ c.GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND, c.GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND, c.GHOSTTY_TERMINAL_DATA_COLOR_CURSOR };
        for (keys, 10..) |key, osc| {
            var color: c.GhosttyColorRgb = undefined;
            const status = c.ghostty_terminal_get(self.handle, key, &color);
            if (status == c.GHOSTTY_NO_VALUE) continue;
            if (status != c.GHOSTTY_SUCCESS) return error.TerminalReadFailed;
            const bytes = try std.fmt.bufPrint(&buffer, "\x1b]{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\", .{ osc, color.r, color.g, color.b });
            if (bytes.len > maximum - output.items.len) return error.FrameTooLarge;
            try output.appendSlice(allocator, bytes);
        }
        return output.toOwnedSlice(allocator);
    }

    /// Formats the current active screen with a caller-enforced allocation cap.
    /// This is not a full session snapshot: inactive screens and image caches
    /// must be transported separately before the client can claim restoration.
    pub fn formatActiveScreen(self: *const Terminal, allocator: std.mem.Allocator, styled: bool, maximum: usize) ![]u8 {
        var options = std.mem.zeroes(c.GhosttyFormatterTerminalOptions);
        options.size = @sizeOf(c.GhosttyFormatterTerminalOptions);
        options.emit = if (styled) c.GHOSTTY_FORMATTER_FORMAT_VT else c.GHOSTTY_FORMATTER_FORMAT_PLAIN;
        options.trim = true;
        options.extra.size = @sizeOf(c.GhosttyFormatterTerminalExtra);
        options.extra.screen.size = @sizeOf(c.GhosttyFormatterScreenExtra);
        options.extra.modes = styled;
        options.extra.scrolling_region = styled;
        options.extra.tabstops = styled;
        options.extra.keyboard = styled;
        options.extra.screen.cursor = styled;
        options.extra.screen.style = styled;
        options.extra.screen.hyperlink = styled;
        options.extra.screen.protection = styled;
        options.extra.screen.kitty_keyboard = styled;
        options.extra.screen.charsets = styled;
        // CWD is metadata, not an OSC that a remote frame may use to access the
        // client's filesystem. Palette stays client-owned until negotiated.
        var formatter: c.GhosttyFormatter = null;
        if (c.ghostty_formatter_terminal_new(null, &formatter, self.handle, options) != c.GHOSTTY_SUCCESS)
            return error.FormatterInitializationFailed;
        defer c.ghostty_formatter_free(formatter);
        var required: usize = 0;
        const measured = c.ghostty_formatter_format_buf(formatter, null, 0, &required);
        if (measured != c.GHOSTTY_OUT_OF_SPACE and measured != c.GHOSTTY_SUCCESS)
            return error.FormattingFailed;
        if (required > maximum) return error.FrameTooLarge;
        const result = try allocator.alloc(u8, required);
        errdefer allocator.free(result);
        var written: usize = 0;
        if (c.ghostty_formatter_format_buf(formatter, result.ptr, result.len, &written) != c.GHOSTTY_SUCCESS or written != required)
            return error.FormattingFailed;
        return result;
    }

    /// Reads an explicitly selected screen without modifying live active state.
    /// An alternate screen never initialized by the child is represented by null.
    pub fn formatScreen(self: *const Terminal, allocator: std.mem.Allocator, screen: Screen, styled: bool, maximum: usize) !?[]u8 {
        var required: usize = 0;
        const measured = ghostty_aster_screen_format_buf(self.handle, @intFromEnum(screen), styled, null, 0, &required);
        if (measured == c.GHOSTTY_INVALID_VALUE and screen == .alternate) return null;
        if (measured != c.GHOSTTY_OUT_OF_SPACE and measured != c.GHOSTTY_SUCCESS) return error.FormattingFailed;
        if (required > maximum) return error.FrameTooLarge;
        const result = try allocator.alloc(u8, required);
        errdefer allocator.free(result);
        var written: usize = 0;
        if (ghostty_aster_screen_format_buf(self.handle, @intFromEnum(screen), styled, result.ptr, result.len, &written) != c.GHOSTTY_SUCCESS or written != required)
            return error.FormattingFailed;
        return result;
    }

    /// Encodes the selected screen saved/current cursor state without mutating VT.
    pub fn cursorReplay(self: *const Terminal, allocator: std.mem.Allocator, screen: Screen, maximum: usize) ![]u8 {
        var required: usize = 0;
        const measured = ghostty_aster_cursor_replay_buf(self.handle, @intFromEnum(screen), null, 0, &required);
        if (measured != c.GHOSTTY_OUT_OF_SPACE and measured != c.GHOSTTY_SUCCESS) return error.FormattingFailed;
        if (required > maximum) return error.FrameTooLarge;
        const output = try allocator.alloc(u8, required);
        errdefer allocator.free(output);
        var written: usize = 0;
        if (ghostty_aster_cursor_replay_buf(self.handle, @intFromEnum(screen), output.ptr, output.len, &written) != c.GHOSTTY_SUCCESS or written != required)
            return error.FormattingFailed;
        return output;
    }

    /// Restores DEC saved values before screen reconstruction. Current values
    /// are applied later by the active screen formatter.
    pub fn savedModes(self: *const Terminal, allocator: std.mem.Allocator, maximum: usize) ![]u8 {
        var required: usize = 0;
        const measured = ghostty_aster_saved_modes_buf(self.handle, null, 0, &required);
        if (measured != c.GHOSTTY_OUT_OF_SPACE and measured != c.GHOSTTY_SUCCESS) return error.FormattingFailed;
        if (required > maximum) return error.FrameTooLarge;
        const output = try allocator.alloc(u8, required);
        errdefer allocator.free(output);
        var written: usize = 0;
        if (ghostty_aster_saved_modes_buf(self.handle, output.ptr, output.len, &written) != c.GHOSTTY_SUCCESS or written != required)
            return error.FormattingFailed;
        return output;
    }

    /// Enables bounded inline images. File, temporary-file and shared-memory
    /// media stay disabled so terminal output cannot read host filesystem data.
    /// Copies page descriptors in oldest-first order. Caller bounds descriptor
    /// allocation independently of the retained-history byte budget.
    pub fn historyPages(self: *const Terminal, allocator: std.mem.Allocator, screen: Screen, maximum_pages: usize) ![]HistoryPage {
        var count: usize = 0;
        const measured = ghostty_aster_history_pages(self.handle, @intFromEnum(screen), null, 0, &count);
        if (measured != c.GHOSTTY_SUCCESS and measured != c.GHOSTTY_OUT_OF_SPACE) return error.HistoryReadFailed;
        if (count > maximum_pages) return error.HistoryPageLimit;
        const result = try allocator.alloc(HistoryPage, count);
        errdefer allocator.free(result);
        var written: usize = 0;
        if (ghostty_aster_history_pages(self.handle, @intFromEnum(screen), result.ptr, result.len, &written) != c.GHOSTTY_SUCCESS or written != count)
            return error.HistoryReadFailed;
        return result;
    }

    /// Reads page-backed history usage without touching viewport or terminal IO.
    pub fn historyUsage(self: *const Terminal, screen: Screen) !HistoryUsage {
        var result: HistoryUsage = undefined;
        if (ghostty_aster_history_usage(self.handle, @intFromEnum(screen), &result) != c.GHOSTTY_SUCCESS)
            return error.HistoryReadFailed;
        return result;
    }

    /// Evicts an oldest history prefix only. The caller must invalidate history
    /// projections after nonzero removed_rows; active cells and PTY stay intact.
    pub fn trimHistory(self: *Terminal, screen: Screen, maximum: usize) !HistoryTrim {
        var result: HistoryTrim = undefined;
        if (ghostty_aster_history_trim(self.handle, @intFromEnum(screen), maximum, &result.removed_rows, &result.remaining) != c.GHOSTTY_SUCCESS)
            return error.HistoryTrimFailed;
        return result;
    }

    pub fn enableGraphics(self: *Terminal, limit: u64) !void {
        if (limit == 0 or limit > 16 * 1024 * 1024) return error.InvalidImageLimit;
        if (session_install_png_decoder() != 1) return error.GraphicsUnavailable;
        const disabled = false;
        for ([_]c.GhosttyTerminalOption{
            c.GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE,
            c.GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE,
            c.GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM,
        }) |option| {
            if (c.ghostty_terminal_set(self.handle, option, &disabled) != c.GHOSTTY_SUCCESS) return error.GraphicsUnavailable;
        }
        if (c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &limit) != c.GHOSTTY_SUCCESS)
            return error.GraphicsUnavailable;
    }

    /// Copies validated decoded RGB/RGBA pixels before the terminal can mutate.
    /// Missing IDs return null; unhandled formats fail explicitly.
    pub fn copyImage(self: *const Terminal, allocator: std.mem.Allocator, id: u32, maximum: usize) !?Image {
        return self.copyScreenImage(allocator, try self.activeScreen(), id, maximum);
    }

    /// Copies a selected screen's image without changing the live active screen.
    pub fn copyScreenImage(self: *const Terminal, allocator: std.mem.Allocator, screen: Screen, id: u32, maximum: usize) !?Image {
        const raw = ghostty_aster_graphics_for_screen(self.handle, @intFromEnum(screen)) orelse return null;
        const storage: c.GhosttyKittyGraphics = @ptrCast(@alignCast(raw));
        const image = c.ghostty_kitty_graphics_image(storage, id) orelse return null;
        var width: u32 = 0;
        var height: u32 = 0;
        var format: c.GhosttyKittyImageFormat = 0;
        var compression: c.GhosttyKittyImageCompression = 0;
        var length: usize = 0;
        var bytes: [*c]const u8 = null;
        if (c.ghostty_kitty_graphics_image_get(image, c.GHOSTTY_KITTY_IMAGE_DATA_WIDTH, &width) != c.GHOSTTY_SUCCESS or
            c.ghostty_kitty_graphics_image_get(image, c.GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, &height) != c.GHOSTTY_SUCCESS or
            c.ghostty_kitty_graphics_image_get(image, c.GHOSTTY_KITTY_IMAGE_DATA_FORMAT, &format) != c.GHOSTTY_SUCCESS or
            c.ghostty_kitty_graphics_image_get(image, c.GHOSTTY_KITTY_IMAGE_DATA_COMPRESSION, &compression) != c.GHOSTTY_SUCCESS or
            c.ghostty_kitty_graphics_image_get(image, c.GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN, &length) != c.GHOSTTY_SUCCESS or
            c.ghostty_kitty_graphics_image_get(image, c.GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR, @ptrCast(&bytes)) != c.GHOSTTY_SUCCESS)
            return error.InvalidImageData;
        const channels: usize = switch (format) {
            c.GHOSTTY_KITTY_IMAGE_FORMAT_RGB => 3,
            c.GHOSTTY_KITTY_IMAGE_FORMAT_RGBA => 4,
            else => return error.UnsupportedImageFormat,
        };
        if (compression != c.GHOSTTY_KITTY_IMAGE_COMPRESSION_NONE) return error.UnsupportedImageFormat;
        const pixels = try std.math.mul(usize, width, height);
        const expected = try std.math.mul(usize, pixels, channels);
        if (expected == 0 or expected != length or bytes == null) return error.InvalidImageData;
        if (length > maximum) return error.ImageTooLarge;
        return .{ .width = width, .height = height, .channels = @intCast(channels), .pixels = try allocator.dupe(u8, bytes[0..length]) };
    }

    /// Copies placement metadata while storage is borrowed. Fully off-screen
    /// or virtual placements retain an explicit null viewport, not a fake (0,0).
    pub fn placements(self: *const Terminal, allocator: std.mem.Allocator, maximum: usize) ![]Placement {
        return self.screenPlacements(allocator, try self.activeScreen(), maximum);
    }

    pub fn screenPlacements(self: *const Terminal, allocator: std.mem.Allocator, screen: Screen, maximum: usize) ![]Placement {
        // Text-only history snapshots need no pixel geometry to enumerate an empty cache.
        if (try self.imageCount(screen) == 0) return allocator.alloc(Placement, 0);
        const pixels = try self.pixelSize();
        if (pixels.width == 0 or pixels.height == 0) return error.PixelGeometryUnavailable;
        const raw = ghostty_aster_graphics_for_screen(self.handle, @intFromEnum(screen)) orelse return allocator.alloc(Placement, 0);
        const storage: c.GhosttyKittyGraphics = @ptrCast(@alignCast(raw));
        var iterator: c.GhosttyKittyGraphicsPlacementIterator = null;
        if (c.ghostty_kitty_graphics_placement_iterator_new(null, &iterator) != c.GHOSTTY_SUCCESS) return error.PlacementReadFailed;
        defer c.ghostty_kitty_graphics_placement_iterator_free(iterator);
        if (c.ghostty_kitty_graphics_get(storage, c.GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR, @ptrCast(&iterator)) != c.GHOSTTY_SUCCESS)
            return error.PlacementReadFailed;
        var result: std.ArrayList(Placement) = .empty;
        errdefer result.deinit(allocator);
        while (c.ghostty_kitty_graphics_placement_next(iterator)) {
            if (result.items.len >= maximum) return error.TooManyPlacements;
            var item: Placement = std.mem.zeroes(Placement);
            const keys = [_]c.GhosttyKittyGraphicsPlacementData{
                c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID,     c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_PLACEMENT_ID,
                c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL,   c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_X_OFFSET,
                c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Y_OFFSET,     c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_COLUMNS,
                c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_ROWS,         c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z,
                c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_SOURCE_X,     c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_SOURCE_Y,
                c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_SOURCE_WIDTH, c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_SOURCE_HEIGHT,
            };
            const values = [_]?*anyopaque{ &item.image_id, &item.placement_id, &item.virtual, &item.x_offset, &item.y_offset, &item.columns, &item.rows, &item.z, &item.source_x, &item.source_y, &item.source_width, &item.source_height };
            for (keys, values) |key, value| {
                if (c.ghostty_kitty_graphics_placement_get(iterator, key, value) != c.GHOSTTY_SUCCESS) return error.PlacementReadFailed;
            }
            const image = c.ghostty_kitty_graphics_image(storage, item.image_id) orelse return error.ImageMissing;
            var info = std.mem.zeroes(c.GhosttyKittyGraphicsPlacementRenderInfo);
            info.size = @sizeOf(c.GhosttyKittyGraphicsPlacementRenderInfo);
            if (ghostty_aster_placement_render_info(self.handle, @intFromEnum(screen), iterator, image, &info) != c.GHOSTTY_SUCCESS)
                return error.PlacementReadFailed;
            item.resolved_source = .{ .x = info.source_x, .y = info.source_y, .width = info.source_width, .height = info.source_height };
            item.pixel_width = info.pixel_width;
            item.pixel_height = info.pixel_height;
            item.viewport = if (info.viewport_visible) .{ .column = info.viewport_col, .row = info.viewport_row } else null;
            var anchor_column: u32 = 0;
            var anchor_row: u32 = 0;
            const anchor_result = ghostty_aster_placement_anchor(self.handle, @intFromEnum(screen), iterator, &anchor_column, &anchor_row);
            if (anchor_result == c.GHOSTTY_SUCCESS) item.anchor = .{ .column = anchor_column, .row = anchor_row } else if (anchor_result != c.GHOSTTY_NO_VALUE) return error.PlacementReadFailed;
            try result.append(allocator, item);
        }
        return result.toOwnedSlice(allocator);
    }

    /// Enumerates all cached image IDs, including uploads without placements.
    /// Output is sorted for deterministic snapshots and bounded before allocation.
    pub fn imageCount(self: *const Terminal, screen: Screen) !usize {
        var count: usize = 0;
        const result = ghostty_aster_image_ids(self.handle, @intFromEnum(screen), null, 0, &count);
        if (result != c.GHOSTTY_SUCCESS and result != c.GHOSTTY_OUT_OF_SPACE) return error.GraphicsUnavailable;
        return count;
    }

    pub fn imageIDs(self: *const Terminal, allocator: std.mem.Allocator, screen: Screen, maximum: usize) ![]u32 {
        var count: usize = 0;
        const measured = ghostty_aster_image_ids(self.handle, @intFromEnum(screen), null, 0, &count);
        if (measured != c.GHOSTTY_SUCCESS and measured != c.GHOSTTY_OUT_OF_SPACE) return error.GraphicsUnavailable;
        if (count > maximum) return error.TooManyImages;
        const result = try allocator.alloc(u32, count);
        errdefer allocator.free(result);
        var written: usize = 0;
        if (ghostty_aster_image_ids(self.handle, @intFromEnum(screen), result.ptr, result.len, &written) != c.GHOSTTY_SUCCESS or written != count)
            return error.ImageReadFailed;
        return result;
    }

    pub fn formatRow(self: *const Terminal, allocator: std.mem.Allocator, screen: Screen, row: u32, maximum: usize) ![]u8 {
        var required: usize = 0;
        const measured = ghostty_aster_screen_row_buf(self.handle, @intFromEnum(screen), row, null, 0, &required);
        if (measured != c.GHOSTTY_SUCCESS and measured != c.GHOSTTY_OUT_OF_SPACE) return error.InvalidScreenRow;
        if (required > maximum) return error.FrameTooLarge;
        const result = try allocator.alloc(u8, required);
        errdefer allocator.free(result);
        var written: usize = 0;
        if (ghostty_aster_screen_row_buf(self.handle, @intFromEnum(screen), row, result.ptr, result.len, &written) != c.GHOSTTY_SUCCESS or written != required)
            return error.FormattingFailed;
        return result;
    }

    pub fn screenMetrics(self: *const Terminal) !Metrics {
        return self.metricsForScreen(try self.activeScreen());
    }

    pub const Metrics = struct { rows: u16, columns: u16, total_rows: usize };

    pub fn metricsForScreen(self: *const Terminal, screen: Screen) !Metrics {
        var rows: u16 = 0;
        var columns: u16 = 0;
        var total: usize = 0;
        if (c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_ROWS, &rows) != c.GHOSTTY_SUCCESS or
            c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_COLS, &columns) != c.GHOSTTY_SUCCESS or
            ghostty_aster_screen_total_rows(self.handle, @intFromEnum(screen), &total) != c.GHOSTTY_SUCCESS)
            return error.TerminalReadFailed;
        return .{ .rows = rows, .columns = columns, .total_rows = total };
    }

    pub fn graphemeClustering(self: *const Terminal) !bool {
        var enabled = false;
        if (c.ghostty_terminal_mode_get(self.handle, c.ghostty_mode_new(2027, false), &enabled) != c.GHOSTTY_SUCCESS)
            return error.TerminalReadFailed;
        return enabled;
    }

    pub fn modeEnabled(self: *const Terminal, number: u16) !bool {
        var enabled = false;
        if (c.ghostty_terminal_mode_get(self.handle, c.ghostty_mode_new(number, false), &enabled) != c.GHOSTTY_SUCCESS)
            return error.TerminalReadFailed;
        return enabled;
    }

    pub fn screenState(self: *const Terminal, allocator: std.mem.Allocator, screen: Screen, before: bool, maximum: usize) ![]u8 {
        var required: usize = 0;
        const measured = ghostty_aster_screen_state_buf(self.handle, @intFromEnum(screen), before, null, 0, &required);
        if (measured != c.GHOSTTY_SUCCESS and measured != c.GHOSTTY_OUT_OF_SPACE) return error.TerminalReadFailed;
        if (required > maximum) return error.FrameTooLarge;
        const result = try allocator.alloc(u8, required);
        errdefer allocator.free(result);
        var written: usize = 0;
        if (ghostty_aster_screen_state_buf(self.handle, @intFromEnum(screen), before, result.ptr, result.len, &written) != c.GHOSTTY_SUCCESS or written != required)
            return error.FormattingFailed;
        return result;
    }

    pub fn hasScreen(self: *const Terminal, screen: Screen) !bool {
        var count: usize = 0;
        const result = ghostty_aster_screen_total_rows(self.handle, @intFromEnum(screen), &count);
        if (result == c.GHOSTTY_NO_VALUE) return false;
        if (result != c.GHOSTTY_SUCCESS) return error.TerminalReadFailed;
        return true;
    }

    pub fn activeScreen(self: *const Terminal) !Screen {
        var screen: c.GhosttyTerminalScreen = 0;
        if (c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen) != c.GHOSTTY_SUCCESS)
            return error.TerminalReadFailed;
        return std.meta.intToEnum(Screen, screen) catch error.TerminalReadFailed;
    }

    pub const Viewport = struct { total: u64, offset: u64, length: u64 };

    /// Active screen's actual viewport, including history rows. Alternate screen
    /// has no scrollback; scrolling it does not synthesize application key input.
    pub fn viewport(self: *const Terminal) !Viewport {
        var value: c.GhosttyTerminalScrollbar = undefined;
        if (c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_SCROLLBAR, &value) != c.GHOSTTY_SUCCESS)
            return error.TerminalReadFailed;
        return .{ .total = value.total, .offset = value.offset, .length = value.len };
    }

    /// Negative rows move toward older history; positive rows move toward the
    /// active bottom. Ghostty clamps extremes; zero and clamped moves return false.
    pub fn scrollViewport(self: *Terminal, rows: i32) !bool {
        const before = try self.viewport();
        c.ghostty_terminal_scroll_viewport(self.handle, .{
            .tag = c.GHOSTTY_SCROLL_VIEWPORT_DELTA,
            .value = .{ .delta = rows },
        });
        return !std.meta.eql(before, try self.viewport());
    }

    pub fn resize(self: *Terminal, cols: u16, rows: u16) !void {
        try self.resizeGeometry(.{ .rows = rows, .columns = cols });
    }

    pub fn resizeGeometry(self: *Terminal, geometry: Geometry) !void {
        try geometry.validate();
        if (c.ghostty_terminal_resize(self.handle, geometry.columns, geometry.rows, geometry.cellWidth(), geometry.cellHeight()) != c.GHOSTTY_SUCCESS)
            return error.TerminalResizeFailed;
    }

    pub fn pixelSize(self: *const Terminal) !struct { width: u32, height: u32 } {
        var width: u32 = 0;
        var height: u32 = 0;
        if (c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_WIDTH_PX, &width) != c.GHOSTTY_SUCCESS or
            c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_HEIGHT_PX, &height) != c.GHOSTTY_SUCCESS)
            return error.TerminalReadFailed;
        return .{ .width = width, .height = height };
    }

    pub fn cursorColumn(self: *const Terminal) !u16 {
        var column: u16 = 0;
        if (c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_CURSOR_X, &column) != c.GHOSTTY_SUCCESS)
            return error.TerminalReadFailed;
        return column;
    }
};

test "headless VT preserves partial UTF-8 and wide-character cursor width" {
    var terminal = try Terminal.init(80, 24, 100);
    defer terminal.deinit();
    const chinese = "中";
    terminal.write(chinese[0..1]);
    try std.testing.expectEqual(@as(u16, 0), try terminal.cursorColumn());
    terminal.write(chinese[1..]);
    try std.testing.expectEqual(@as(u16, 2), try terminal.cursorColumn());
    terminal.write("A");
    try std.testing.expectEqual(@as(u16, 3), try terminal.cursorColumn());
}

test "zero terminal dimensions are rejected before allocation" {
    try std.testing.expectError(error.InvalidDimensions, Terminal.init(0, 24, 100));
}

test "active screen formatter restores overwritten content and cursor" {
    var source = try Terminal.init(80, 24, 100);
    defer source.deinit();
    source.write("old text\r\x1b[2K\x1b[38;2;12;34;56m中A");
    const plain = try source.formatActiveScreen(std.testing.allocator, false, 32768);
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "old text") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "中A") != null);
    const frame = try source.formatActiveScreen(std.testing.allocator, true, 32768);
    defer std.testing.allocator.free(frame);
    var restored = try Terminal.init(80, 24, 100);
    defer restored.deinit();
    restored.write(frame);
    try std.testing.expectEqual(try source.cursorColumn(), try restored.cursorColumn());
    const restored_plain = try restored.formatActiveScreen(std.testing.allocator, false, 32768);
    defer std.testing.allocator.free(restored_plain);
    try std.testing.expectEqualStrings(plain, restored_plain);
}

test "formatter rejects output beyond the requested allocation cap" {
    var terminal = try Terminal.init(80, 24, 0);
    defer terminal.deinit();
    terminal.write("hello");
    try std.testing.expectError(error.FrameTooLarge, terminal.formatActiveScreen(std.testing.allocator, true, 1));
}

/// Bounded query output queue. Callers must treat overflow as a connection error
/// and may clear only after forwarding all bytes to the owned child PTY.
pub const ResponseSink = struct {
    buffer: [65536]u8 = undefined,
    used: usize = 0,
    overflow: bool = false,

    pub fn bytes(self: *const ResponseSink) ![]const u8 {
        if (self.overflow) return error.ResponseOverflow;
        return self.buffer[0..self.used];
    }

    fn receive(_: c.GhosttyTerminal, userdata: ?*anyopaque, data: [*c]const u8, count: usize) callconv(.c) void {
        const self: *ResponseSink = @ptrCast(@alignCast(userdata orelse return));
        if (self.overflow) return;
        if (count > self.buffer.len - self.used) {
            self.overflow = true;
            return;
        }
        @memcpy(self.buffer[self.used..][0..count], data[0..count]);
        self.used += count;
    }
};

test "server handles a cursor query once and emitted screen has no query" {
    var source = try Terminal.init(80, 24, 0);
    defer source.deinit();
    var responses: ResponseSink = .{};
    try source.setResponseSink(&responses);
    source.write("ABC\x1b[6n");
    try std.testing.expectEqualStrings("\x1b[1;4R", try responses.bytes());
    const frame = try source.formatActiveScreen(std.testing.allocator, true, 32768);
    defer std.testing.allocator.free(frame);
    var client = try Terminal.init(80, 24, 0);
    defer client.deinit();
    var client_responses: ResponseSink = .{};
    try client.setResponseSink(&client_responses);
    client.write(frame);
    try std.testing.expectEqual(@as(usize, 0), (try client_responses.bytes()).len);
}

test "query output overflow is observable instead of silently dropping replies" {
    var terminal = try Terminal.init(80, 24, 0);
    defer terminal.deinit();
    var responses: ResponseSink = .{};
    try terminal.setResponseSink(&responses);
    responses.used = responses.buffer.len - 1;
    terminal.write("\x1b[6n");
    try std.testing.expectError(error.ResponseOverflow, responses.bytes());
}

test "exporting inactive primary preserves the live alternate screen" {
    var terminal = try Terminal.init(80, 24, 100);
    defer terminal.deinit();
    terminal.write("PRIMARY\x1b[?1049hALT中");
    const original_column = try terminal.cursorColumn();
    const primary = (try terminal.formatScreen(std.testing.allocator, .primary, false, 32768)).?;
    defer std.testing.allocator.free(primary);
    const alternate = (try terminal.formatScreen(std.testing.allocator, .alternate, false, 32768)).?;
    defer std.testing.allocator.free(alternate);
    try std.testing.expect(std.mem.indexOf(u8, primary, "PRIMARY") != null);
    try std.testing.expect(std.mem.indexOf(u8, primary, "ALT") == null);
    try std.testing.expect(std.mem.indexOf(u8, alternate, "ALT中") != null);
    try std.testing.expectEqual(Screen.alternate, try terminal.activeScreen());
    try std.testing.expectEqual(original_column, try terminal.cursorColumn());
    terminal.write("\x1b[?1049l");
    try std.testing.expectEqual(Screen.primary, try terminal.activeScreen());
    try std.testing.expectEqual(@as(u16, 7), try terminal.cursorColumn());
}

test "absent alternate screen remains absent after export" {
    var terminal = try Terminal.init(80, 24, 0);
    defer terminal.deinit();
    try std.testing.expect((try terminal.formatScreen(std.testing.allocator, .alternate, true, 32768)) == null);
    try std.testing.expectEqual(Screen.primary, try terminal.activeScreen());
}

test "both exported screens survive reconstruction and screen switching" {
    var source = try Terminal.init(80, 24, 100);
    defer source.deinit();
    source.write("PRIMARY\x1b[?1049hALT中");
    const primary = (try source.formatScreen(std.testing.allocator, .primary, true, 32768)).?;
    defer std.testing.allocator.free(primary);
    const alternate = (try source.formatScreen(std.testing.allocator, .alternate, true, 32768)).?;
    defer std.testing.allocator.free(alternate);
    var destination = try Terminal.init(80, 24, 100);
    defer destination.deinit();
    destination.write(primary);
    destination.write("\x1b[?1049h");
    destination.write(alternate);
    const alt_plain = (try destination.formatScreen(std.testing.allocator, .alternate, false, 32768)).?;
    defer std.testing.allocator.free(alt_plain);
    try std.testing.expect(std.mem.indexOf(u8, alt_plain, "ALT中") != null);
    destination.write("\x1b[?1049l");
    const primary_plain = try destination.formatActiveScreen(std.testing.allocator, false, 32768);
    defer std.testing.allocator.free(primary_plain);
    try std.testing.expect(std.mem.indexOf(u8, primary_plain, "PRIMARY") != null);
    try std.testing.expectEqual(@as(u16, 7), try destination.cursorColumn());
}

test "scroll viewport moves through history clamps extremes and isolates alternate screen" {
    var terminal = try Terminal.init(20, 3, 100);
    defer terminal.deinit();
    terminal.write("one\r\ntwo\r\nthree\r\nfour\r\nfive");
    const bottom = try terminal.viewport();
    try std.testing.expect(bottom.offset > 0);
    try std.testing.expectEqual(@as(u64, 3), bottom.length);
    try std.testing.expect(try terminal.scrollViewport(-1));
    try std.testing.expectEqual(bottom.offset - 1, (try terminal.viewport()).offset);
    try std.testing.expect(!try terminal.scrollViewport(0));
    try std.testing.expect(try terminal.scrollViewport(std.math.minInt(i32)));
    try std.testing.expectEqual(@as(u64, 0), (try terminal.viewport()).offset);
    try std.testing.expect(!try terminal.scrollViewport(-1));
    try std.testing.expect(try terminal.scrollViewport(std.math.maxInt(i32)));
    try std.testing.expectEqualDeep(bottom, try terminal.viewport());
    try std.testing.expect(!try terminal.scrollViewport(1));
    terminal.write("\x1b[?1049hALT");
    const alternate = try terminal.viewport();
    try std.testing.expectEqual(@as(u64, 0), alternate.offset);
    try std.testing.expect(!try terminal.scrollViewport(std.math.minInt(i32)));
    try std.testing.expect(!try terminal.scrollViewport(std.math.maxInt(i32)));
    try std.testing.expectEqualDeep(alternate, try terminal.viewport());
    terminal.write("\x1b[?1049l");
    try std.testing.expectEqualDeep(bottom, try terminal.viewport());
}
