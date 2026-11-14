//! Cursor and selection.

pub const Cursor = struct {
    pos: usize = 0,
    anchor: ?usize = null,
};

test "default cursor" {
    const c: Cursor = .{};
    try @import("std").testing.expectEqual(@as(usize, 0), c.pos);
}
