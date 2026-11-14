//! Git integration through the git CLI. SDL-free.
//! Import every file of this folder here, so `zig build test` runs its tests.

pub const diff = @import("diff.zig");
pub const log = @import("log.zig");
pub const repo = @import("repo.zig");
pub const status = @import("status.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
