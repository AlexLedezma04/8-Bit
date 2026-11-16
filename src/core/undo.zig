//! Undo history: a list of recorded changes and how far into it we are.
//! It stores changes; `edit.zig` applies them.
const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Range = @import("buffer.zig").Range;
const Cursor = @import("cursor.zig").Cursor;
const utf8 = @import("utf8.zig");

/// Close changes of the same kind form one step; `other` is always its own.
pub const Kind = enum { insert, delete, other };

pub const Direction = enum { back, forward };

pub const Entry = struct {
    pos: usize,
    /// The removed text followed by the inserted text.
    text: []u8,
    removed_len: usize,
    /// Cursor before the change.
    before: Cursor,
    kind: Kind,
    /// Undone and redone together with the entry before it.
    chained: bool = false,

    pub fn removed(self: Entry) []const u8 {
        return self.text[0..self.removed_len];
    }

    pub fn inserted(self: Entry) []const u8 {
        return self.text[self.removed_len..];
    }

    fn size(self: Entry) usize {
        return @sizeOf(Entry) + self.text.len;
    }

    /// Typing continues until a new word starts; deletes continue while they touch.
    fn continues(self: Entry, last: Entry) bool {
        if (self.kind != last.kind) return false;
        switch (self.kind) {
            .insert => {
                const old = last.inserted();
                const new = self.inserted();
                if (self.removed_len > 0 or old.len == 0 or new.len == 0) return false;
                if (self.pos != last.pos + old.len) return false;
                return utf8.isWord(old[old.len - 1]) or !utf8.isWord(new[0]);
            },
            .delete => return self.pos == last.pos or self.pos + self.removed_len == last.pos,
            .other => return false,
        }
    }
};

pub const History = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// Entries before this index are applied; the rest can be redone.
    done: usize = 0,
    size: usize = 0,
    /// Oldest entries are dropped when `size` passes this many bytes.
    max_size: usize = 8 * 1024 * 1024,
    group: enum { none, first, rest } = .none,
    /// Value of `done` when the text was last saved; null once that state
    /// cannot be reached by undo or redo any more.
    saved: ?usize = 0,
    /// The next entry starts a new step, so undo can stop at the saved state.
    sealed: bool = false,

    pub fn init(allocator: std.mem.Allocator) History {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *History) void {
        self.done = 0;
        self.dropRedo();
        self.entries.deinit(self.allocator);
    }

    /// Forgets everything, for a newly loaded text.
    pub fn clear(self: *History) void {
        self.done = 0;
        self.dropRedo();
        self.markSaved();
    }

    pub fn markSaved(self: *History) void {
        self.saved = self.done;
        self.sealed = true;
    }

    /// True when the text differs from the last saved state.
    pub fn isModified(self: *const History) bool {
        return self.saved != self.done;
    }

    /// Changes pushed until `endGroup` form one step.
    pub fn beginGroup(self: *History) void {
        self.group = .first;
    }

    pub fn endGroup(self: *History) void {
        self.group = .none;
    }

    /// Builds the entry for a change that is about to happen and makes room
    /// for it. Then `push` it, or `discard` it if the change failed.
    pub fn capture(self: *History, buffer: *const Buffer, range: Range, inserted: []const u8, before: Cursor, kind: Kind) !Entry {
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        const text = try self.allocator.alloc(u8, range.len() + inserted.len);
        _ = buffer.copy(range.start, text[0..range.len()]);
        @memcpy(text[range.len()..], inserted);
        return .{ .pos = range.start, .text = text, .removed_len = range.len(), .before = before, .kind = kind };
    }

    pub fn discard(self: *History, entry: Entry) void {
        self.allocator.free(entry.text);
    }

    pub fn push(self: *History, captured: Entry) void {
        self.dropRedo();
        var entry = captured;
        switch (self.group) {
            .none => entry.chained = !self.sealed and self.done > 0 and entry.continues(self.entries.items[self.done - 1]),
            .first => self.group = .rest,
            .rest => entry.chained = true,
        }
        if (self.group != .none) entry.kind = .other;
        self.sealed = false;
        self.entries.appendAssumeCapacity(entry);
        self.done += 1;
        self.size += entry.size();
        self.dropOldest();
    }

    /// The entry that `step` in the same direction would pass.
    pub fn peek(self: *const History, direction: Direction) ?*const Entry {
        const items = self.entries.items;
        return switch (direction) {
            .back => if (self.done > 0) &items[self.done - 1] else null,
            .forward => if (self.done < items.len) &items[self.done] else null,
        };
    }

    pub fn step(self: *History, direction: Direction) void {
        switch (direction) {
            .back => self.done -= 1,
            .forward => self.done += 1,
        }
    }

    fn release(self: *History, entries: []const Entry) void {
        for (entries) |entry| {
            self.size -= entry.size();
            self.discard(entry);
        }
    }

    fn dropRedo(self: *History) void {
        self.release(self.entries.items[self.done..]);
        self.entries.shrinkRetainingCapacity(self.done);
        if (self.saved) |saved| if (saved > self.done) {
            self.saved = null;
        };
    }

    fn dropOldest(self: *History) void {
        const items = self.entries.items;
        var count: usize = 0;
        var freed: usize = 0;
        while (self.size - freed > self.max_size) : (count += 1) freed += items[count].size();
        self.release(items[0..count]);
        self.entries.replaceRangeAssumeCapacity(0, count, &.{});
        self.done -= count;
        if (self.saved) |saved| self.saved = if (saved < count) null else saved - count;
    }
};

const testing = std.testing;

fn pushInsert(history: *History, buffer: *const Buffer, pos: usize, text: []const u8, kind: Kind) !void {
    history.push(try history.capture(buffer, .{ .start = pos, .end = pos }, text, .{}, kind));
}

test "capture keeps the removed and the inserted text" {
    var buffer = Buffer.init(testing.allocator);
    defer buffer.deinit();
    try buffer.load("hello world");
    var history = History.init(testing.allocator);
    defer history.deinit();

    history.push(try history.capture(&buffer, .{ .start = 6, .end = 11 }, "you", .{ .pos = 11 }, .other));
    const entry = history.peek(.back).?;
    try testing.expectEqualStrings("world", entry.removed());
    try testing.expectEqualStrings("you", entry.inserted());
    try testing.expectEqual(@as(usize, 11), entry.before.pos);
}

test "typing chains until a new word starts" {
    var buffer = Buffer.init(testing.allocator);
    defer buffer.deinit();
    try buffer.load("0123456789abcdef");
    var history = History.init(testing.allocator);
    defer history.deinit();

    for ("hi you", 0..) |*char, pos| try pushInsert(&history, &buffer, pos, char[0..1], .insert);
    const chained = [_]bool{ false, true, true, false, true, true };
    for (history.entries.items, chained) |entry, expected| try testing.expectEqual(expected, entry.chained);

    try pushInsert(&history, &buffer, 0, "x", .insert);
    try testing.expect(!history.peek(.back).?.chained);
    try pushInsert(&history, &buffer, 1, "y", .other);
    try testing.expect(!history.peek(.back).?.chained);
}

test "a group chains everything pushed inside it" {
    var buffer = Buffer.init(testing.allocator);
    defer buffer.deinit();
    try buffer.load("0123456789abcdef");
    var history = History.init(testing.allocator);
    defer history.deinit();

    try pushInsert(&history, &buffer, 0, "a", .insert);
    history.beginGroup();
    try pushInsert(&history, &buffer, 1, "b", .insert);
    try pushInsert(&history, &buffer, 9, "c", .insert);
    history.endGroup();
    try pushInsert(&history, &buffer, 10, "d", .insert);

    const chained = [_]bool{ false, false, true, false };
    for (history.entries.items, chained) |entry, expected| try testing.expectEqual(expected, entry.chained);
}

test "step moves between undo and redo, and a push drops the redo entries" {
    var buffer = Buffer.init(testing.allocator);
    defer buffer.deinit();
    try buffer.load("0123456789abcdef");
    var history = History.init(testing.allocator);
    defer history.deinit();
    try testing.expect(history.peek(.back) == null);

    try pushInsert(&history, &buffer, 0, "a", .other);
    try pushInsert(&history, &buffer, 1, "b", .other);
    history.step(.back);
    try testing.expectEqualStrings("a", history.peek(.back).?.inserted());
    try testing.expectEqualStrings("b", history.peek(.forward).?.inserted());

    try pushInsert(&history, &buffer, 1, "c", .other);
    try testing.expect(history.peek(.forward) == null);
    try testing.expectEqual(@as(usize, 2), history.entries.items.len);
}

test "the oldest entries are dropped past the size limit" {
    var buffer = Buffer.init(testing.allocator);
    defer buffer.deinit();
    try buffer.load("0123456789abcdef");
    var history = History.init(testing.allocator);
    defer history.deinit();
    history.max_size = 3 * (@sizeOf(Entry) + 1);

    for ("abcde", 0..) |*char, pos| try pushInsert(&history, &buffer, pos, char[0..1], .other);
    try testing.expectEqual(@as(usize, 3), history.entries.items.len);
    try testing.expectEqual(@as(usize, 3), history.done);
    try testing.expectEqualStrings("c", history.entries.items[0].inserted());

    const too_big: [1024]u8 = @splat('x');
    try pushInsert(&history, &buffer, 5, &too_big, .other);
    try testing.expectEqual(@as(usize, 0), history.entries.items.len);
    try testing.expectEqual(@as(usize, 0), history.size);
}

test "modified follows undo and redo back to the saved state" {
    var buffer = Buffer.init(testing.allocator);
    defer buffer.deinit();
    try buffer.load("0123456789abcdef");
    var history = History.init(testing.allocator);
    defer history.deinit();
    try testing.expect(!history.isModified());

    try pushInsert(&history, &buffer, 0, "a", .insert);
    try testing.expect(history.isModified());
    history.markSaved();
    try testing.expect(!history.isModified());

    // Typing after a save starts a new step.
    try pushInsert(&history, &buffer, 1, "b", .insert);
    try testing.expect(!history.peek(.back).?.chained);
    try testing.expect(history.isModified());
    history.step(.back);
    try testing.expect(!history.isModified());
    history.step(.back);
    try testing.expect(history.isModified());

    // A new change drops the redo entries, and the saved state with them.
    try pushInsert(&history, &buffer, 0, "c", .other);
    history.step(.back);
    try testing.expect(history.isModified());

    history.clear();
    try testing.expect(!history.isModified());
    try testing.expectEqual(@as(usize, 0), history.entries.items.len);
}

test "dropping old entries can drop the saved state" {
    var buffer = Buffer.init(testing.allocator);
    defer buffer.deinit();
    try buffer.load("0123456789abcdef");
    var history = History.init(testing.allocator);
    defer history.deinit();
    history.max_size = 2 * (@sizeOf(Entry) + 1);

    for ("abc", 0..) |*char, pos| try pushInsert(&history, &buffer, pos, char[0..1], .other);
    try testing.expectEqual(@as(?usize, null), history.saved);
    history.markSaved();
    try pushInsert(&history, &buffer, 3, "d", .other);
    try testing.expectEqual(@as(?usize, 1), history.saved);
}
