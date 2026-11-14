//! App state, commands, key bindings and config. SDL-free.
//! Import every file of this folder here, so `zig build test` runs its tests.

pub const commands = @import("commands.zig");
pub const config = @import("config.zig");
pub const editor = @import("editor.zig");
pub const keymap = @import("keymap.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
