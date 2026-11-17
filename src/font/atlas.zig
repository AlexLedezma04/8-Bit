//! The glyphs of both fonts at one zoom, packed in rows into one picture.
//! White pixels with the coverage as alpha, so the draw color tints them.
//! The renderer uploads it and makes it again when the zoom changes.
const std = @import("std");
const fonts = @import("fonts.zig");
const Kind = fonts.Kind;

/// Where a glyph is in the picture, and where it goes from the pen and
/// the top of the row.
pub const Glyph = struct { x: u16 = 0, y: u16 = 0, w: u16 = 0, h: u16 = 0, left: i16 = 0, top: i16 = 0 };

/// Characters that get a glyph. The rest share the box of glyph 0.
const ranges = [_][2]u21{
    .{ 0x20, 0x7E },     .{ 0xA0, 0xFF },     .{ 0x2022, 0x2022 }, .{ 0x2026, 0x2026 },
    .{ 0x2190, 0x2193 }, .{ 0x2500, 0x259F }, .{ 0x25B6, 0x25BF }, .{ 0x25CF, 0x25CF },
};

const count = blk: {
    var total = 0;
    for (ranges) |range| total += range[1] - range[0] + 1;
    break :blk total;
};

/// Slot of a character; 0 is the box.
fn slot(cp: u21) usize {
    var base: usize = 1;
    for (ranges) |range| {
        if (cp >= range[0] and cp <= range[1]) return base + cp - range[0];
        base += range[1] - range[0] + 1;
    }
    return 0;
}

pub const Atlas = struct {
    width: usize = 1024,
    height: usize,
    /// RGBA.
    pixels: []u8,
    glyphs: [2][count + 1]Glyph,

    /// Pixels between glyphs, so sampling never bleeds into a neighbor.
    const pad = 1;

    pub fn init(allocator: std.mem.Allocator, zoom: u8) !Atlas {
        var atlas: Atlas = .{ .height = 0, .pixels = &.{}, .glyphs = undefined };
        // Place every glyph, then draw them all at once.
        var x: usize = pad;
        var y: usize = pad;
        var shelf: usize = 0;
        for (std.enums.values(Kind)) |kind| {
            const font = fonts.face(kind);
            const s = fonts.scale(kind, zoom);
            const top = fonts.baseline(kind, zoom);
            for (&atlas.glyphs[@backingInt(kind)], 0..) |*entry, i| {
                const box = font.box(glyphAt(kind, i), s);
                const w: usize = @intCast(box.x1 - box.x0);
                const h: usize = @intCast(box.y1 - box.y0);
                if (x + w + pad > atlas.width) {
                    x = pad;
                    y += shelf + pad;
                    shelf = 0;
                }
                entry.* = .{ .x = @intCast(x), .y = @intCast(y), .w = @intCast(w), .h = @intCast(h), .left = @intCast(box.x0), .top = @intFromFloat(top + @as(f32, @floatFromInt(box.y0))) };
                x += w + pad;
                shelf = @max(shelf, h);
            }
        }
        atlas.height = y + shelf + pad;
        const coverage = try allocator.alloc(u8, atlas.width * atlas.height);
        defer allocator.free(coverage);
        @memset(coverage, 0);
        for (std.enums.values(Kind)) |kind| {
            const s = fonts.scale(kind, zoom);
            for (atlas.glyphs[@backingInt(kind)], 0..) |entry, i| {
                if (entry.w == 0) continue;
                const at = @as(usize, entry.y) * atlas.width + entry.x;
                fonts.face(kind).render(glyphAt(kind, i), s, coverage[at..], entry.w, entry.h, atlas.width);
            }
        }
        atlas.pixels = try allocator.alloc(u8, coverage.len * 4);
        for (coverage, 0..) |alpha, i| atlas.pixels[i * 4 ..][0..4].* = .{ 0xFF, 0xFF, 0xFF, alpha };
        return atlas;
    }

    pub fn deinit(self: *Atlas, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    pub fn glyph(self: *const Atlas, kind: Kind, cp: u21) Glyph {
        return self.glyphs[@backingInt(kind)][slot(cp)];
    }

    /// The font's glyph for a slot.
    fn glyphAt(kind: Kind, index: usize) u32 {
        if (index == 0) return 0;
        var base: usize = 1;
        for (ranges) |range| {
            const len = range[1] - range[0] + 1;
            if (index < base + len) return fonts.face(kind).glyphOf(@intCast(range[0] + index - base));
            base += len;
        }
        unreachable;
    }
};

const testing = std.testing;

fn alphaSum(atlas: *const Atlas, glyph: Glyph) usize {
    var sum: usize = 0;
    for (0..glyph.h) |dy| for (0..glyph.w) |dx| {
        sum += atlas.pixels[((glyph.y + dy) * atlas.width + glyph.x + dx) * 4 + 3];
    };
    return sum;
}

test "every glyph is drawn inside the picture; a space has none" {
    var atlas: Atlas = try .init(testing.allocator, 1);
    defer atlas.deinit(testing.allocator);
    for (atlas.glyphs) |set| for (set) |entry| {
        try testing.expect(entry.x + entry.w <= atlas.width and entry.y + entry.h <= atlas.height);
    };
    try testing.expect(alphaSum(&atlas, atlas.glyph(.code, 'H')) > 0);
    try testing.expect(alphaSum(&atlas, atlas.glyph(.ui, '\u{E9}')) > 0);
    try testing.expectEqual(@as(u16, 0), atlas.glyph(.code, ' ').w);
    // A character outside the ranges is the box.
    try testing.expectEqual(atlas.glyph(.code, 0), atlas.glyph(.code, 0x1F600));
    try testing.expect(alphaSum(&atlas, atlas.glyph(.code, 0x1F600)) > 0);
}

test "glyphs sit in the row and grow with the zoom" {
    var one: Atlas = try .init(testing.allocator, 1);
    defer one.deinit(testing.allocator);
    var two: Atlas = try .init(testing.allocator, 2);
    defer two.deinit(testing.allocator);
    const h = one.glyph(.code, 'H');
    try testing.expect(h.top > 0 and @as(i32, h.top) + h.h <= fonts.row_height);
    try testing.expect(two.glyph(.code, 'H').h >= 2 * h.h - 1);
    // 'g' goes below the baseline, so lower than 'H' ends.
    const g = one.glyph(.ui, 'g');
    const cap = one.glyph(.ui, 'H');
    try testing.expect(@as(i32, g.top) + g.h > @as(i32, cap.top) + cap.h);
}
