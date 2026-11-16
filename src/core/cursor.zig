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

    /// Keeps the cursor on the same text after `old` became `new_len` bytes.
    /// A position inside the removed text goes to its start.
    pub fn shift(self: *Cursor, old: Range, new_len: usize) void {
        self.pos = shiftPos(self.pos, old, new_len);
        if (self.anchor) |anchor| self.anchor = shiftPos(anchor, old, new_len);
        self.goal_col = null;
    }

    fn shiftPos(pos: usize, old: Range, new_len: usize) usize {
        if (pos <= old.start) return pos;
        if (pos >= old.end) return pos - old.len() + new_len;
        return old.start;
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

test "shift keeps a cursor on the same text" {
    var c: Cursor = .{ .pos = 10, .anchor = 2 };
    c.shift(.{ .start = 4, .end = 6 }, 5);
    try testing.expectEqual(Cursor{ .pos = 13, .anchor = 2 }, c);
    c.shift(.{ .start = 1, .end = 3 }, 0);
    try testing.expectEqual(Cursor{ .pos = 11, .anchor = 1 }, c);
    c.shift(.{ .start = 11, .end = 11 }, 4);
    try testing.expectEqual(@as(usize, 11), c.pos);
}

test "selectAll" {
    var c: Cursor = .{ .pos = 3, .goal_col = 2 };
    c.selectAll(10);
    try testing.expectEqual(Range{ .start = 0, .end = 10 }, c.selection());
    try testing.expectEqual(@as(usize, 10), c.pos);
}
