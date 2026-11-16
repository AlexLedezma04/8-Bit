//! One cursor: a position, an optional selection anchor and a goal column.
const std = @import("std");
const Range = @import("buffer.zig").Range;

pub const Cursor = struct {
    pos: usize = 0,
    anchor: ?usize = null,
    /// Column that up and down moves try to keep.
    goal_col: ?usize = null,

    /// Empty when nothing is selected.
    pub fn selection(self: Cursor) Range {
        return .between(self.anchor orelse self.pos, self.pos);
    }

    pub fn clearSelection(self: *Cursor) void {
        self.anchor = null;
    }

    pub fn selectAll(self: *Cursor, len: usize) void {
        self.* = .{ .anchor = 0, .pos = len };
    }

    /// `extend` keeps the anchor, or drops one at the old position.
    pub fn moveTo(self: *Cursor, pos: usize, extend: bool) void {
        const anchor = if (extend) self.anchor orelse self.pos else null;
        self.* = .{ .pos = pos, .anchor = anchor };
    }
};

const testing = std.testing;

test "selection is ordered in both directions" {
    var c: Cursor = .{ .pos = 5 };
    try testing.expectEqual(Range{ .start = 5, .end = 5 }, c.selection());
    c.moveTo(2, true);
    try testing.expectEqual(Range{ .start = 2, .end = 5 }, c.selection());
    c.moveTo(9, true);
    try testing.expectEqual(Range{ .start = 5, .end = 9 }, c.selection());
}

test "a plain move and clearSelection drop the selection" {
    var c: Cursor = .{ .pos = 1 };
    c.moveTo(4, true);
    c.clearSelection();
    try testing.expectEqual(@as(usize, 0), c.selection().len());
    try testing.expectEqual(@as(usize, 4), c.pos);
    c.moveTo(6, true);
    c.moveTo(3, false);
    try testing.expectEqual(Cursor{ .pos = 3 }, c);
}

test "selectAll" {
    var c: Cursor = .{ .pos = 3, .goal_col = 2 };
    c.selectAll(10);
    try testing.expectEqual(Range{ .start = 0, .end = 10 }, c.selection());
    try testing.expectEqual(@as(usize, 10), c.pos);
}
