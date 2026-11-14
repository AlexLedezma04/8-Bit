//! VT parser, screen grid and terminal session. SDL-free.
//! Import every file of this folder here, so `zig build test` runs its tests.

pub const grid = @import("grid.zig");
pub const terminal = @import("terminal.zig");
pub const vt = @import("vt.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
