//! Text model: buffer, cursor, edits, undo, search, UTF-8. SDL-free.
//! Import every file of this folder here, so `zig build test` runs its tests.

pub const buffer = @import("buffer.zig");
pub const cursor = @import("cursor.zig");
pub const edit = @import("edit.zig");
pub const newline = @import("newline.zig");
pub const search = @import("search.zig");
pub const undo = @import("undo.zig");
pub const utf8 = @import("utf8.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
