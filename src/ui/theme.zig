//! Colours.

pub const Color = struct { r: u8, g: u8, b: u8, a: u8 = 255 };

pub const Theme = struct {
    background: Color = .{ .r = 0x10, .g = 0x10, .b = 0x18 },
    foreground: Color = .{ .r = 0xd0, .g = 0xd0, .b = 0xd0 },
};
