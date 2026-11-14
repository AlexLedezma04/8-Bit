//! The SDL-free part of the UI: colors and layout math.
//! panels/ and widgets/ draw through platform/renderer.zig (SDL), so they are
//! not imported here. Keep their logic in SDL-free files when it needs tests.

pub const layout = @import("layout.zig");
pub const theme = @import("theme.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
