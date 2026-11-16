//! Turns the font bits into atlas pixels and places the glyphs of a text.
//! The renderer uploads the atlas and draws the placed glyphs.
const std = @import("std");
const font = @import("spleen.zig");
const utf8 = @import("../core/utf8.zig");

/// Size of one character cell, in font pixels.
pub const width = font.width;
pub const height = font.height;

const atlas_columns = 32;
pub const atlas_width = atlas_columns * width;
pub const atlas_height = (font.glyphs.len + atlas_columns - 1) / atlas_columns * height;
pub const atlas_bytes = atlas_width * atlas_height * 4;

/// Fills `pixels` as RGBA: white where a glyph has a pixel, transparent
/// elsewhere, so the draw color can tint it.
pub fn drawAtlas(pixels: *[atlas_bytes]u8) void {
    @memset(pixels, 0xFF);
    for (font.glyphs, 0..) |glyph, index| {
        const origin = atlasOrigin(index);
        for (glyph, origin.y..) |bits, y| {
            for (0..width, origin.x..) |bit, x| {
                const on = bits >> @intCast(bit) & 1 == 1;
                if (!on) pixels[(y * atlas_width + x) * 4 + 3] = 0;
            }
        }
    }
}

const Origin = struct { x: usize, y: usize };

fn atlasOrigin(index: usize) Origin {
    return .{ .x = index % atlas_columns * width, .y = index / atlas_columns * height };
}

/// One character of a line: its column and where its glyph is in the atlas.
pub const PlacedGlyph = struct { column: usize, atlas_x: usize, atlas_y: usize };

/// Walks one line of UTF-8 text. Every character takes one column; spaces
/// take a column but are not returned.
pub const GlyphIterator = struct {
    text: []const u8,
    column: usize = 0,

    pub fn next(self: *GlyphIterator) ?PlacedGlyph {
        while (self.text.len > 0) {
            const char = utf8.decode(self.text);
            self.text = self.text[char.len..];
            defer self.column += 1;
            if (char.cp == ' ') continue;
            const origin = atlasOrigin(font.index(char.cp));
            return .{ .column = self.column, .atlas_x = origin.x, .atlas_y = origin.y };
        }
        return null;
    }
};

const testing = std.testing;

fn atlasAlpha(pixels: *const [atlas_bytes]u8, x: usize, y: usize) u8 {
    return pixels[(y * atlas_width + x) * 4 + 3];
}

test "the atlas has room for every glyph" {
    try testing.expect(atlas_width / width * (atlas_height / height) >= font.glyphs.len);
    const last = atlasOrigin(font.glyphs.len - 1);
    try testing.expect(last.x + width <= atlas_width and last.y + height <= atlas_height);
}

test "atlas pixels are white, with alpha from the glyph bits" {
    var pixels: [atlas_bytes]u8 = undefined;
    drawAtlas(&pixels);
    for (0..atlas_bytes / 4) |i| {
        try testing.expectEqualSlices(u8, &.{ 0xFF, 0xFF, 0xFF }, pixels[i * 4 ..][0..3]);
    }
    const a = atlasOrigin(font.index('A'));
    const top_row = [width]u8{ 0, 255, 255, 255, 255, 255, 0, 0 };
    for (top_row, 0..) |alpha, x| try testing.expectEqual(alpha, atlasAlpha(&pixels, a.x + x, a.y + 2));
    const space = atlasOrigin(font.index(' '));
    try testing.expectEqual(@as(u8, 0), atlasAlpha(&pixels, space.x + 3, space.y + 8));
}

test "glyphs are placed one column per character, skipping spaces" {
    var glyphs: GlyphIterator = .{ .text = "a \u{E9}\xFF\u{2500}" };
    const expected = [_]struct { column: usize, cp: u21 }{
        .{ .column = 0, .cp = 'a' },
        .{ .column = 2, .cp = 0xE9 },
        .{ .column = 3, .cp = utf8.replacement },
        .{ .column = 4, .cp = 0x2500 },
    };
    for (expected) |want| {
        const origin = atlasOrigin(font.index(want.cp));
        const placed: PlacedGlyph = .{ .column = want.column, .atlas_x = origin.x, .atlas_y = origin.y };
        try testing.expectEqual(placed, glyphs.next().?);
    }
    try testing.expectEqual(@as(?PlacedGlyph, null), glyphs.next());
}
