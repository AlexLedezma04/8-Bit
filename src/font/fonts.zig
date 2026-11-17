//! The built-in fonts: JetBrains Mono for code, Inter for the UI. At zoom 1
//! a code character is 8 pixels wide and a row is 16 high, like IntelliJ's
//! 13 pixel fonts with 1.2 line spacing. Code text keeps to that cell grid;
//! UI text moves by each character's own advance.
const std = @import("std");
const assets = @import("assets");
const Face = @import("truetype.zig").Face;
const utf8 = @import("../core/utf8.zig");

pub const Kind = enum { code, ui };

/// At zoom 1, in pixels.
pub const cell_width = 8;
pub const row_height = 16;
const ui_em = 13;

var faces: ?[2]Face = null;

pub fn face(kind: Kind) *const Face {
    if (faces == null) faces = .{ .init(assets.code_font), .init(assets.ui_font) };
    return &faces.?[@intFromEnum(kind)];
}

/// Font units to pixels.
pub fn scale(kind: Kind, zoom: u8) f32 {
    const z: f32 = @floatFromInt(zoom);
    const font = face(kind);
    return switch (kind) {
        .code => cell_width * z / font.advance(font.glyphOf('0')),
        .ui => font.scaleForEm(ui_em * z),
    };
}

/// Pixels from the top of a row to the baseline, which centers the text.
pub fn baseline(kind: Kind, zoom: u8) f32 {
    const ascent, const descent = face(kind).vertical();
    const row: f32 = @floatFromInt(row_height * @as(u32, zoom));
    return @round((row + (ascent + descent) * scale(kind, zoom)) / 2);
}

/// Where each character of a line goes.
pub const Pen = struct {
    kind: Kind,
    zoom: u8,
    text: []const u8,
    x: f32 = 0,
    scale: f32,

    pub const Placed = struct { cp: u21, glyph: u32, x: f32 };

    pub fn init(kind: Kind, zoom: u8, text: []const u8) Pen {
        return .{ .kind = kind, .zoom = zoom, .text = text, .scale = scale(kind, zoom) };
    }

    pub fn next(self: *Pen) ?Placed {
        if (self.text.len == 0) return null;
        const char = utf8.decode(self.text);
        self.text = self.text[char.len..];
        const font = face(self.kind);
        const glyph = font.glyphOf(char.cp);
        const placed: Placed = .{ .cp = char.cp, .glyph = glyph, .x = @round(self.x) };
        self.x += switch (self.kind) {
            .code => @floatFromInt(cell_width * @as(u32, self.zoom)),
            .ui => font.advance(glyph) * self.scale,
        };
        return placed;
    }
};

/// Width of a line in pixels.
pub fn width(kind: Kind, text: []const u8, zoom: u8) f32 {
    var pen: Pen = .init(kind, zoom, text);
    while (pen.next()) |_| {}
    return @round(pen.x);
}

const testing = std.testing;

test "code text keeps to the cell grid; UI text is proportional" {
    try testing.expectEqual(@as(f32, 3 * 8), width(.code, "iiW", 1));
    try testing.expectEqual(@as(f32, 3 * 16), width(.code, "iiW", 2));
    try testing.expect(width(.ui, "iii", 1) < width(.ui, "WWW", 1));
    try testing.expect(width(.ui, "Files", 2) > 1.9 * width(.ui, "Files", 1));
    try testing.expectEqual(@as(f32, 0), width(.ui, "", 1));
}

test "the code font is 8 pixels a character; text sits inside the row" {
    const font = face(.code);
    try testing.expectApproxEqAbs(@as(f32, 8), font.advance(font.glyphOf('M')) * scale(.code, 1), 0.01);
    for ([_]Kind{ .code, .ui }) |kind| {
        const line = baseline(kind, 1);
        try testing.expect(line > 10 and line < 16);
        try testing.expect(baseline(kind, 2) > line);
    }
}

test "a missing character is glyph 0, the box" {
    try testing.expectEqual(@as(u32, 0), face(.ui).glyphOf(0x1F600));
    try testing.expect(face(.code).glyphOf(0x2502) != 0);
}
