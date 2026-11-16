//! Root of all SDL-free code. `zig build test` runs every test reachable from
//! here, and the integration tests in tests/ import it as "8-bit".
//! Only folder roots go here; each root imports the files of its folder.

pub const core = @import("core/root.zig");
pub const editor = @import("editor/root.zig");
pub const font = @import("font/root.zig");
pub const git = @import("git/root.zig");
pub const platform = @import("platform/root.zig");
pub const syntax = @import("syntax/root.zig");
pub const terminal = @import("terminal/root.zig");
pub const ui = @import("ui/root.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
