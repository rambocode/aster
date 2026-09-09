/// Geometry reported by a real PTY. Zero pixel dimensions mean unavailable,
/// never an invented cell size. Division removes any partial trailing cell.
pub const Geometry = struct {
    rows: u16,
    columns: u16,
    pixel_width: u16 = 0,
    pixel_height: u16 = 0,

    pub fn validate(self: Geometry) !void {
        if (self.rows == 0 or self.columns == 0) return error.InvalidDimensions;
        if ((self.pixel_width == 0) != (self.pixel_height == 0)) return error.InvalidPixelDimensions;
        if (self.pixel_width != 0 and (self.pixel_width < self.columns or self.pixel_height < self.rows))
            return error.InvalidPixelDimensions;
    }
    pub fn cellWidth(self: Geometry) u32 {
        return self.pixel_width / self.columns;
    }
    pub fn cellHeight(self: Geometry) u32 {
        return self.pixel_height / self.rows;
    }
};
