//! Bitmap font data and glyph atlas pixels. SDL-free.
//! Import every file of this folder here, so `zig build test` runs its tests.

pub const bitmap_font = @import("bitmap_font.zig");
pub const font8x8 = @import("font8x8.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
