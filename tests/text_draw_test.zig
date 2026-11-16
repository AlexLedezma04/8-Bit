//! End to end without SDL: text -> placed glyphs -> atlas pixels, drawn into
//! a small picture the same way the renderer draws quads.
const std = @import("std");
const app = @import("8-bit");

const testing = std.testing;
const bitmap_font = app.font.bitmap_font;
const width = bitmap_font.width;
const height = bitmap_font.height;

/// Draws `text` as rows of '#' and '.', one row per line of pixels.
fn drawAsArt(comptime columns: usize, text: []const u8) [height][columns * width]u8 {
    var atlas: [bitmap_font.atlas_bytes]u8 = undefined;
    bitmap_font.drawAtlas(&atlas);

    var art: [height][columns * width]u8 = @splat(@splat('.'));
    var glyphs: bitmap_font.GlyphIterator = .{ .text = text };
    while (glyphs.next()) |glyph| {
        for (0..height) |y| for (0..width) |x| {
            const pixel = (glyph.atlas_y + y) * bitmap_font.atlas_width + glyph.atlas_x + x;
            if (atlas[pixel * 4 + 3] != 0) art[y][glyph.column * width + x] = '#';
        };
    }
    return art;
}

test "a line of text becomes the right pixels" {
    // ASCII, a space, Latin-1, box drawing and a character the font lacks.
    const art = drawAsArt(6, "H \u{E9}\u{2502}\u{1F600}");
    const expected = [height][]const u8{
        "...........................##...................",
        "....................##.....##...................",
        "##...##............##......##...................",
        "##...##...........##.......##....######.........",
        "##...##....................##....#....#.........",
        "##...##..........######....##....#....#.........",
        "#######.........##...##....##....#....#.........",
        "##...##.........##...##....##....#....#.........",
        "##...##.........#######....##....#....#.........",
        "##...##.........##.........##....#....#.........",
        "##...##.........##.........##....#....#.........",
        "##...##..........######....##....#....#.........",
        "...........................##....######.........",
        "...........................##...................",
        "...........................##...................",
        "...........................##...................",
    };
    for (expected, art) |want, row| try testing.expectEqualStrings(want, &row);
}
