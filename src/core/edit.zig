//! One open text: buffer, cursor and undo history, and every way to change
//! the text or move the cursor. All text changes go through `apply`.
const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Range = @import("buffer.zig").Range;
const Cursor = @import("cursor.zig").Cursor;
const undo_zig = @import("undo.zig");
const History = undo_zig.History;
const utf8 = @import("utf8.zig");

pub const Move = union(enum) {
    left,
    right,
    word_left,
    word_right,
    line_start,
    line_end,
    up,
    down,
    /// Payload: lines per page.
    page_up: usize,
    page_down: usize,
    file_start,
    file_end,

    fn isVertical(self: Move) bool {
        return switch (self) {
            .up, .down, .page_up, .page_down => true,
            else => false,
        };
    }
};

pub const Document = struct {
    buffer: Buffer,
    cursor: Cursor = .{},
    history: History,

    pub fn init(allocator: std.mem.Allocator) Document {
        return .{ .buffer = .init(allocator), .history = .init(allocator) };
    }

    pub fn deinit(self: *Document) void {
        self.buffer.deinit();
        self.history.deinit();
    }

    /// Replaces `range` with `text` and returns the range the new text takes.
    /// Not recorded for undo. Leaves the buffer unchanged on failure.
    pub fn apply(self: *Document, range: Range, text: []const u8) !Range {
        try self.buffer.insert(range.end, text);
        self.buffer.delete(range.start, range.len());
        return .{ .start = range.start, .end = range.start + text.len };
    }

    /// Typed text: replaces the selection and groups with nearby typing.
    pub fn insert(self: *Document, text: []const u8) !void {
        try self.edit(self.cursor.selection(), text, .insert);
    }

    /// Replaces the selection as one undo step.
    pub fn paste(self: *Document, text: []const u8) !void {
        try self.replace(self.cursor.selection(), text);
    }

    /// Replaces `range` as one undo step.
    pub fn replace(self: *Document, range: Range, text: []const u8) !void {
        try self.edit(range, text, .other);
    }

    /// Deletes the selection, or from the cursor to where `to` would move it:
    /// `.left` is backspace, `.right` is delete, `.word_left` deletes a word.
    pub fn delete(self: *Document, to: Move) !void {
        const selection = self.cursor.selection();
        const range = if (selection.len() > 0) selection else Range.between(self.cursor.pos, self.target(to));
        try self.edit(range, "", .delete);
    }

    pub fn move(self: *Document, to: Move, extend: bool) void {
        const goal = if (to.isVertical()) self.goalColumn() else null;
        self.cursor.moveTo(self.target(to), extend);
        self.cursor.goal_col = goal;
    }

    pub fn selectAll(self: *Document) void {
        self.cursor.selectAll(self.buffer.len());
    }

    /// Returns false when there is nothing to undo.
    pub fn undo(self: *Document) !bool {
        return self.replay(.back);
    }

    pub fn redo(self: *Document) !bool {
        return self.replay(.forward);
    }

    fn edit(self: *Document, range: Range, text: []const u8, kind: undo_zig.Kind) !void {
        if (range.len() == 0 and text.len == 0) return;
        const entry = try self.history.capture(&self.buffer, range, text, self.cursor, kind);
        errdefer self.history.discard(entry);
        const changed = try self.apply(range, text);
        self.history.push(entry);
        self.cursor = .{ .pos = changed.end };
    }

    /// Undoes or redoes one step: an entry and all entries chained to it.
    fn replay(self: *Document, direction: undo_zig.Direction) !bool {
        var chained = false;
        while (self.history.peek(direction)) |entry| {
            if (direction == .forward and chained and !entry.chained) break;
            const old, const new = switch (direction) {
                .back => .{ entry.inserted(), entry.removed() },
                .forward => .{ entry.removed(), entry.inserted() },
            };
            const changed = try self.apply(.{ .start = entry.pos, .end = entry.pos + old.len }, new);
            self.cursor = if (direction == .back) entry.before else .{ .pos = changed.end };
            self.history.step(direction);
            chained = true;
            if (direction == .back and !entry.chained) break;
        }
        return chained;
    }

    fn target(self: *const Document, to: Move) usize {
        const pos = self.cursor.pos;
        const line = self.buffer.lineOf(pos);
        return switch (to) {
            .left => self.prev(pos),
            .right => self.next(pos),
            .word_left => self.wordLeft(pos),
            .word_right => self.wordRight(pos),
            .line_start => self.buffer.lineStart(line),
            .line_end => self.buffer.lineEnd(line),
            .up => self.atGoalColumn(line -| 1),
            .down => self.atGoalColumn(line + 1),
            .page_up => |lines| self.atGoalColumn(line -| lines),
            .page_down => |lines| self.atGoalColumn(line +| lines),
            .file_start => 0,
            .file_end => self.buffer.len(),
        };
    }

    /// Character boundary after `pos`. CRLF is one character.
    fn next(self: *const Document, pos: usize) usize {
        var window: [4]u8 = undefined;
        const text = self.buffer.copy(pos, &window);
        if (text.len == 0) return pos;
        if (std.mem.startsWith(u8, text, "\r\n")) return pos + 2;
        return pos + utf8.decode(text).len;
    }

    fn prev(self: *const Document, pos: usize) usize {
        var window: [4]u8 = undefined;
        const text = self.buffer.copy(pos -| window.len, window[0..@min(window.len, pos)]);
        if (std.mem.endsWith(u8, text, "\r\n")) return pos - 2;
        return pos - (text.len - utf8.prev(text, text.len));
    }

    fn isWordAt(self: *const Document, pos: usize) bool {
        var window: [4]u8 = undefined;
        return utf8.isWord(utf8.decode(self.buffer.copy(pos, &window)).cp);
    }

    /// End of the word at or after `from`.
    fn wordRight(self: *const Document, from: usize) usize {
        const end = self.buffer.len();
        var pos = from;
        while (pos < end and !self.isWordAt(pos)) pos = self.next(pos);
        while (pos < end and self.isWordAt(pos)) pos = self.next(pos);
        return pos;
    }

    /// Start of the word at or before `from`.
    fn wordLeft(self: *const Document, from: usize) usize {
        var pos = from;
        while (pos > 0 and !self.isWordAt(self.prev(pos))) pos = self.prev(pos);
        while (pos > 0 and self.isWordAt(self.prev(pos))) pos = self.prev(pos);
        return pos;
    }

    fn goalColumn(self: *const Document) usize {
        if (self.cursor.goal_col) |goal| return goal;
        var column: usize = 0;
        var pos = self.buffer.lineStart(self.buffer.lineOf(self.cursor.pos));
        while (pos < self.cursor.pos) : (column += 1) pos = self.next(pos);
        return column;
    }

    /// Position at the goal column of `line`, or at its end if it is shorter.
    fn atGoalColumn(self: *const Document, line: usize) usize {
        const target_line = @min(line, self.buffer.lineCount() - 1);
        const end = self.buffer.lineEnd(target_line);
        var pos = self.buffer.lineStart(target_line);
        for (0..self.goalColumn()) |_| {
            if (pos >= end) break;
            pos = self.next(pos);
        }
        return pos;
    }
};

const testing = std.testing;
const expectText = @import("buffer.zig").expectText;

fn testDocument(text: []const u8) !Document {
    var doc = Document.init(testing.allocator);
    errdefer doc.deinit();
    try doc.buffer.load(text);
    return doc;
}

fn expectMove(doc: *Document, to: Move, expected: usize) !void {
    doc.move(to, false);
    try testing.expectEqual(expected, doc.cursor.pos);
}

test "apply returns the changed range" {
    var doc = try testDocument("hello world");
    defer doc.deinit();
    const changed = try doc.apply(.{ .start = 6, .end = 11 }, "you");
    try testing.expectEqual(Range{ .start = 6, .end = 9 }, changed);
    try expectText(&doc.buffer, "hello you");
    try testing.expectEqual(Range{ .start = 0, .end = 0 }, try doc.apply(.{ .start = 0, .end = 6 }, ""));
    try expectText(&doc.buffer, "you");
}

test "insert replaces the selection" {
    var doc = try testDocument("hello world");
    defer doc.deinit();
    doc.move(.word_right, true);
    try doc.insert("bye");
    try expectText(&doc.buffer, "bye world");
    try testing.expectEqual(Cursor{ .pos = 3 }, doc.cursor);
}

test "backspace, delete and delete word" {
    var doc = try testDocument("one two three");
    defer doc.deinit();
    try doc.delete(.left);
    try expectText(&doc.buffer, "one two three");

    doc.cursor.pos = 4;
    try doc.delete(.left);
    try expectText(&doc.buffer, "onetwo three");
    try doc.delete(.right);
    try expectText(&doc.buffer, "onewo three");
    try doc.delete(.word_right);
    try expectText(&doc.buffer, "one three");
    try doc.delete(.word_left);
    try expectText(&doc.buffer, " three");
    try testing.expectEqual(@as(usize, 0), doc.cursor.pos);

    doc.move(.file_end, true);
    try doc.delete(.left);
    try expectText(&doc.buffer, "");
}

test "moves by character stop on UTF-8 boundaries and treat CRLF as one" {
    var doc = try testDocument("a\u{E9}\u{20AC}\u{1F600}\xFF\r\nz");
    defer doc.deinit();
    const bounds = [_]usize{ 0, 1, 3, 6, 10, 11, 13, 14 };
    for (bounds[1..]) |bound| try expectMove(&doc, .right, bound);
    try expectMove(&doc, .right, 14);
    var i = bounds.len - 1;
    while (i > 0) : (i -= 1) try expectMove(&doc, .left, bounds[i - 1]);
    try expectMove(&doc, .left, 0);

    doc.cursor.pos = 13;
    try doc.delete(.left);
    try expectText(&doc.buffer, "a\u{E9}\u{20AC}\u{1F600}\xFFz");
}

test "moves by word" {
    var doc = try testDocument("foo_1, b\u{E9}r\n  baz");
    defer doc.deinit();
    for ([_]usize{ 5, 11, 17, 17 }) |stop| try expectMove(&doc, .word_right, stop);
    for ([_]usize{ 14, 7, 0, 0 }) |stop| try expectMove(&doc, .word_left, stop);
}

test "moves to line and file start and end" {
    var doc = try testDocument("one\r\ntwo\nthree");
    defer doc.deinit();
    doc.cursor.pos = 6;
    try expectMove(&doc, .line_end, 8);
    try expectMove(&doc, .line_start, 5);
    try expectMove(&doc, .file_end, 14);
    try expectMove(&doc, .line_start, 9);
    try expectMove(&doc, .file_start, 0);
    try expectMove(&doc, .line_end, 3);
}

test "up and down keep the goal column" {
    var doc = try testDocument("long line\n\u{E9}\u{E9}\n\nlonger line");
    defer doc.deinit();
    doc.cursor.pos = 7;
    try expectMove(&doc, .down, 14);
    try expectMove(&doc, .down, 15);
    try expectMove(&doc, .down, 23);
    try expectMove(&doc, .down, 23);
    try expectMove(&doc, .up, 15);
    try expectMove(&doc, .up, 14);
    try expectMove(&doc, .up, 7);
    try expectMove(&doc, .up, 7);

    try expectMove(&doc, .down, 14);
    try expectMove(&doc, .left, 12);
    try expectMove(&doc, .up, 1);
}

test "page moves take the page size" {
    var doc = try testDocument("a0\nb1\nc2\nd3\ne4");
    defer doc.deinit();
    doc.cursor.pos = 1;
    try expectMove(&doc, .{ .page_down = 3 }, 10);
    try expectMove(&doc, .{ .page_down = 3 }, 13);
    try expectMove(&doc, .{ .page_up = 2 }, 7);
    try expectMove(&doc, .{ .page_up = 9 }, 1);
}

test "every move can extend the selection" {
    var doc = try testDocument("one two\nthree");
    defer doc.deinit();
    doc.cursor.pos = 4;
    const moves = [_]Move{ .right, .word_right, .down, .{ .page_up = 1 }, .line_start, .left, .word_left, .line_end, .up, .{ .page_down = 1 }, .file_start, .file_end };
    for (moves) |to| {
        doc.move(to, true);
        try testing.expectEqual(@as(?usize, 4), doc.cursor.anchor);
        try testing.expectEqual(Range.between(4, doc.cursor.pos), doc.cursor.selection());
    }
    doc.move(.left, false);
    try testing.expectEqual(@as(?usize, null), doc.cursor.anchor);

    doc.selectAll();
    try testing.expectEqual(Range{ .start = 0, .end = 13 }, doc.cursor.selection());
}

test "typing a word is one undo step" {
    var doc = try testDocument("");
    defer doc.deinit();
    for ("hello big world") |*char| try doc.insert(char[0..1]);

    try testing.expect(try doc.undo());
    try expectText(&doc.buffer, "hello big ");
    try testing.expect(try doc.undo());
    try expectText(&doc.buffer, "hello ");
    try testing.expect(try doc.redo());
    try expectText(&doc.buffer, "hello big ");
    try testing.expectEqual(@as(usize, 10), doc.cursor.pos);
    try testing.expect(try doc.undo());
    try testing.expect(try doc.undo());
    try expectText(&doc.buffer, "");
    try testing.expect(!try doc.undo());
    try testing.expect(try doc.redo());
    try testing.expect(try doc.redo());
    try testing.expect(try doc.redo());
    try testing.expect(!try doc.redo());
    try expectText(&doc.buffer, "hello big world");
}

test "a run of backspaces is one undo step" {
    var doc = try testDocument("hello");
    defer doc.deinit();
    doc.move(.file_end, false);
    for (0..3) |_| try doc.delete(.left);
    doc.move(.file_start, false);
    for (0..2) |_| try doc.delete(.right);
    try expectText(&doc.buffer, "");

    try testing.expect(try doc.undo());
    try expectText(&doc.buffer, "he");
    try testing.expect(try doc.undo());
    try expectText(&doc.buffer, "hello");
    try testing.expectEqual(@as(usize, 5), doc.cursor.pos);
}

test "undo brings back the cursor and the selection" {
    var doc = try testDocument("hello world");
    defer doc.deinit();
    doc.cursor.pos = 11;
    doc.move(.word_left, true);
    const before = doc.cursor;
    try doc.insert("x");
    try doc.insert("y");
    try testing.expect(try doc.undo());
    try expectText(&doc.buffer, "hello world");
    try testing.expectEqual(before, doc.cursor);
}

test "paste is one undo step and does not join typing" {
    var doc = try testDocument("");
    defer doc.deinit();
    try doc.insert("a");
    try doc.paste("b c d");
    try doc.insert("e");
    try testing.expect(try doc.undo());
    try expectText(&doc.buffer, "ab c d");
    try testing.expect(try doc.undo());
    try expectText(&doc.buffer, "a");
}

test "a group of replaces is one undo step" {
    var doc = try testDocument("a-b-c");
    defer doc.deinit();
    doc.cursor.pos = 2;
    doc.history.beginGroup();
    try doc.replace(.{ .start = 3, .end = 4 }, "+++");
    try doc.replace(.{ .start = 1, .end = 2 }, "+++");
    doc.history.endGroup();
    try expectText(&doc.buffer, "a+++b+++c");

    try testing.expect(try doc.undo());
    try expectText(&doc.buffer, "a-b-c");
    try testing.expectEqual(@as(usize, 2), doc.cursor.pos);
    try testing.expect(!try doc.undo());
    try testing.expect(try doc.redo());
    try expectText(&doc.buffer, "a+++b+++c");
    try testing.expect(!try doc.redo());
}

test "a new edit drops the redo steps" {
    var doc = try testDocument("");
    defer doc.deinit();
    try doc.paste("one");
    try doc.paste("two");
    try testing.expect(try doc.undo());
    try doc.paste("2");
    try testing.expect(!try doc.redo());
    try expectText(&doc.buffer, "one2");
}

test "a failed edit changes nothing" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var doc = Document.init(failing.allocator());
    defer doc.deinit();
    try doc.insert("ab");

    // First the undo entry fails to allocate, then the buffer fails to grow.
    const big: [4096]u8 = @splat('x');
    for (0..2) |nth| {
        failing.fail_index = failing.alloc_index + nth;
        try testing.expectError(error.OutOfMemory, doc.paste(&big));
        try expectText(&doc.buffer, "ab");
        try testing.expectEqual(@as(usize, 1), doc.history.entries.items.len);
        try testing.expectEqual(@as(usize, 2), doc.cursor.pos);
    }
    failing.fail_index = std.math.maxInt(usize);
    try doc.paste(&big);
    try testing.expectEqual(@as(usize, 4098), doc.buffer.len());
}
