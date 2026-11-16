//! App state, commands, key bindings and config. SDL-free.
//! Import every file of this folder here, so `zig build test` runs its tests.

pub const commands = @import("commands.zig");
pub const config = @import("config.zig");
pub const decoration = @import("decoration.zig");
pub const editor = @import("editor.zig");
pub const keymap = @import("keymap.zig");
pub const view = @import("view.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
