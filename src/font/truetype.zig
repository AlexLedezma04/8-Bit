//! One TrueType font through stb_truetype: metrics and glyph coverage.
const c = @import("stb");

pub const Face = struct {
    info: c.stbtt_fontinfo,

    /// `bytes` must outlive the face. A built-in font always loads.
    pub fn init(bytes: []const u8) Face {
        var info: c.stbtt_fontinfo = undefined;
        if (c.stbtt_InitFont(&info, bytes.ptr, 0) == 0) @panic("bad built-in font");
        return .{ .info = info };
    }

    /// Scale from font units to pixels for an em of `px` pixels.
    pub fn scaleForEm(self: *const Face, px: f32) f32 {
        return c.stbtt_ScaleForMappingEmToPixels(&self.info, px);
    }

    /// Glyph index; 0 is the box for a missing character.
    pub fn glyphOf(self: *const Face, cp: u21) u32 {
        return @intCast(c.stbtt_FindGlyphIndex(&self.info, cp));
    }

    /// Advance of a glyph, in font units.
    pub fn advance(self: *const Face, glyph: u32) f32 {
        var width: c_int = 0;
        var bearing: c_int = 0;
        c.stbtt_GetGlyphHMetrics(&self.info, @intCast(glyph), &width, &bearing);
        return @floatFromInt(width);
    }

    /// Ascent (up, positive) and descent (down, negative), in font units.
    pub fn vertical(self: *const Face) [2]f32 {
        var ascent: c_int = 0;
        var descent: c_int = 0;
        var gap: c_int = 0;
        c.stbtt_GetFontVMetrics(&self.info, &ascent, &descent, &gap);
        return .{ @floatFromInt(ascent), @floatFromInt(descent) };
    }

    pub const Box = struct { x0: i32, y0: i32, x1: i32, y1: i32 };

    /// The pixels a glyph covers, relative to the pen on the baseline.
    pub fn box(self: *const Face, glyph: u32, scale: f32) Box {
        var b: [4]c_int = undefined;
        c.stbtt_GetGlyphBitmapBox(&self.info, @intCast(glyph), scale, scale, &b[0], &b[1], &b[2], &b[3]);
        return .{ .x0 = b[0], .y0 = b[1], .x1 = b[2], .y1 = b[3] };
    }

    /// Writes the coverage of a glyph, 0 to 255, into `out` rows of `stride`.
    pub fn render(self: *const Face, glyph: u32, scale: f32, out: []u8, w: usize, h: usize, stride: usize) void {
        c.stbtt_MakeGlyphBitmap(&self.info, out.ptr, @intCast(w), @intCast(h), @intCast(stride), scale, scale, @intCast(glyph));
    }
};
