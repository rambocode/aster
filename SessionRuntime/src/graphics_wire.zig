const std = @import("std");
const vt = @import("vt.zig");

pub const Position = struct { column: u32, row: u32 };

/// Encodes one placement, with no cursor advance and no terminal replies.
/// Virtual placements have no physical anchor; callers restore cursor state.
pub fn placement(allocator: std.mem.Allocator, value: vt.Placement, position: ?Position, maximum: usize) ![]u8 {
    var buffer: [512]u8 = undefined;
    const bytes = if (value.virtual) virtual: {
        if (position != null) return error.UnexpectedVirtualAnchor;
        break :virtual try std.fmt.bufPrint(&buffer, "\x1b_Ga=p,U=1,i={d},p={d},c={d},r={d},X={d},Y={d},x={d},y={d},w={d},h={d},z={d},C=1,q=2\x1b\\", .{
            value.image_id, value.placement_id, value.columns,      value.rows,          value.x_offset, value.y_offset,
            value.source_x, value.source_y,     value.source_width, value.source_height, value.z,
        });
    } else pinned: {
        const point = position orelse return error.MissingPlacementAnchor;
        if (point.column >= 65535 or point.row >= 65535) return error.PlacementAnchorOutOfBounds;
        break :pinned try std.fmt.bufPrint(&buffer, "\x1b[?6l\x1b[{d};{d}H\x1b_Ga=p,i={d},p={d},c={d},r={d},X={d},Y={d},x={d},y={d},w={d},h={d},z={d},C=1,q=2\x1b\\", .{
            point.row + 1,  point.column + 1, value.image_id, value.placement_id, value.columns,      value.rows,
            value.x_offset, value.y_offset,   value.source_x, value.source_y,     value.source_width, value.source_height,
            value.z,
        });
    };
    if (bytes.len > maximum) return error.FrameTooLarge;
    return allocator.dupe(u8, bytes);
}
