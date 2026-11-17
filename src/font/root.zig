//! The built-in fonts, their metrics and the glyph atlas. SDL-free.
//! Import every file of this folder here, so `zig build test` runs its tests.

pub const atlas = @import("atlas.zig");
pub const fonts = @import("fonts.zig");
pub const truetype = @import("truetype.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
