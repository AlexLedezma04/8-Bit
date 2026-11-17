//! End to end without SDL: text -> placed glyphs -> atlas pixels, drawn into
//! a small picture the same way the renderer draws quads.
const std = @import("std");
const app = @import("8-bit");

const testing = std.testing;
const fonts = app.font.fonts;
const Atlas = app.font.atlas.Atlas;

const height = fonts.row_height;

/// Draws one line of text as '#' where a pixel is at least half covered.
fn drawAsArt(comptime w: usize, atlas: *const Atlas, kind: fonts.Kind, text: []const u8) [height][w]u8 {
    var art: [height][w]u8 = @splat(@splat('.'));
    var pen: fonts.Pen = .init(kind, 1, text);
    while (pen.next()) |placed| {
        const glyph = atlas.glyph(kind, placed.cp);
        for (0..glyph.h) |dy| for (0..glyph.w) |dx| {
            const alpha = atlas.pixels[((glyph.y + dy) * atlas.width + glyph.x + dx) * 4 + 3];
            const x: isize = @as(isize, @intFromFloat(placed.x)) + glyph.left + @as(isize, @intCast(dx));
            const y: isize = glyph.top + @as(isize, @intCast(dy));
            if (alpha >= 128 and x >= 0 and x < w and y >= 0 and y < height) art[@intCast(y)][@intCast(x)] = '#';
        };
    }
    return art;
}

fn inked(art: anytype, x0: usize, x1: usize) usize {
    var count: usize = 0;
    for (art) |row| for (row[x0..x1]) |pixel| {
        count += @intFromBool(pixel == '#');
    };
    return count;
}

test "code text: one character per 8 pixel cell, box drawing fills its row" {
    var atlas: Atlas = try .init(testing.allocator, 1);
    defer atlas.deinit(testing.allocator);
    const art = drawAsArt(32, &atlas, .code, "H \u{2502}\u{1F600}");
    // H has two stems: its left and right columns are inked on most rows.
    var stems: usize = 0;
    for (art) |row| stems += @intFromBool(std.mem.count(u8, row[0..8], "#") >= 2);
    try testing.expect(stems >= 8);
    try testing.expectEqual(@as(usize, 0), inked(art, 8, 16));
    // The vertical line runs from the top of the row to the bottom.
    var line: usize = 0;
    for (art) |row| line += @intFromBool(std.mem.indexOfScalar(u8, row[16..24], '#') != null);
    try testing.expectEqual(@as(usize, height), line);
    // A missing character is a box, not nothing.
    try testing.expect(inked(art, 24, 32) > 0);
}

test "UI text is proportional: narrow letters take less room" {
    var atlas: Atlas = try .init(testing.allocator, 1);
    defer atlas.deinit(testing.allocator);
    const narrow = fonts.width(.ui, "iiii", 1);
    const wide = fonts.width(.ui, "MMMM", 1);
    try testing.expect(narrow < wide / 2);
    const art = drawAsArt(64, &atlas, .ui, "iiiiMMMM");
    try testing.expect(inked(art, 0, @intFromFloat(narrow)) > 0);
    try testing.expect(inked(art, @intFromFloat(narrow + wide), 64) == 0);
}
