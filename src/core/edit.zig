//! One open text: buffer, cursor and undo history, and every way to change
//! the text or move the cursor. All text changes go through `apply`.
const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Range = @import("buffer.zig").Range;
const Cursor = @import("cursor.zig").Cursor;
const undo_zig = @import("undo.zig");
const History = undo_zig.History;
const utf8 = @import("utf8.zig");
const LineEnding = @import("newline.zig").LineEnding;

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

/// One character of a line and the screen columns it takes.
pub const Cell = struct { pos: usize, column: usize, width: usize, char: utf8.Char };

/// Walks the characters of one line. A tab reaches to the next tab stop;
/// every other character is one column wide.
pub const CellIterator = struct {
    doc: *const Document,
    pos: usize,
    end: usize,
    column: usize = 0,

    pub fn next(self: *CellIterator) ?Cell {
        if (self.pos >= self.end) return null;
        const tab_width = self.doc.tab_width;
        const char = self.doc.buffer.charAt(self.pos);
        const cell: Cell = .{
            .pos = self.pos,
            .column = self.column,
            .width = if (char.cp == '\t') tab_width - self.column % tab_width else 1,
            .char = char,
        };
        self.pos += char.len;
        self.column += cell.width;
        return cell;
    }
};

pub const Document = struct {
    buffer: Buffer,
    cursor: Cursor = .{},
    history: History,
    /// Used for typed line breaks, and pasted text is changed to it.
    line_ending: LineEnding = .lf,
    /// Columns between tab stops, at most `max_tab_width`.
    tab_width: usize = 4,
    /// The Tab key inserts spaces instead of a tab character.
    soft_tabs: bool = true,
    /// Cursors of other views of this text. `apply` keeps them on their text.
    followers: std.ArrayList(*Cursor) = .empty,
    /// The first line changed since the highlighter last looked.
    changed_from: ?usize = 0,
    /// Goes up on every change of the text.
    revision: u64 = 0,
    /// `apply` refuses to change the text.
    read_only: bool = false,

    pub const max_tab_width = 16;
    /// What a soft tab inserts, cut to its width.
    const spaces: [max_tab_width]u8 = @splat(' ');

    pub fn init(allocator: std.mem.Allocator) Document {
        return .{ .buffer = .init(allocator), .history = .init(allocator) };
    }

    pub fn deinit(self: *Document) void {
        self.buffer.deinit();
        self.history.deinit();
        self.followers.deinit(self.buffer.allocator);
    }

    pub fn follow(self: *Document, cursor: *Cursor) !void {
        try self.followers.append(self.buffer.allocator, cursor);
    }

    pub fn unfollow(self: *Document, cursor: *Cursor) void {
        const at = std.mem.indexOfScalar(*Cursor, self.followers.items, cursor) orelse return;
        _ = self.followers.swapRemove(at);
    }

    /// Replaces everything with a newly opened text and forgets the history.
    pub fn load(self: *Document, text: []const u8) !void {
        try self.buffer.load(text);
        self.changed_from = 0;
        self.revision +%= 1;
        self.cursor = .{};
        self.history.clear();
        self.line_ending = .detect(&self.buffer);
    }

    /// Replaces `range` with `text` and returns the range the new text takes.
    /// Not recorded for undo. Leaves the buffer unchanged on failure.
    pub fn apply(self: *Document, range: Range, text: []const u8) !Range {
        if (self.read_only) return error.ReadOnly;
        const line = self.buffer.lineOf(range.start);
        try self.buffer.insert(range.end, text);
        self.changed_from = @min(line, self.changed_from orelse line);
        self.revision +%= 1;
        self.buffer.delete(range.start, range.len());
        for (self.followers.items) |cursor| cursor.shift(range, text.len);
        return .{ .start = range.start, .end = range.start + text.len };
    }

    /// Typed text: replaces the selection and groups with nearby typing.
    pub fn insert(self: *Document, text: []const u8) !void {
        try self.edit(self.cursor.selection(), text, .insert);
    }

    /// Replaces the selection as one undo step. Line breaks in `text` are
    /// changed to the line ending of this document.
    pub fn paste(self: *Document, text: []const u8) !void {
        const allocator = self.buffer.allocator;
        const normalized = try self.line_ending.normalize(allocator, text);
        defer allocator.free(normalized);
        try self.replace(self.cursor.selection(), normalized);
    }

    /// A line break that keeps the indentation of the current line.
    pub fn insertNewline(self: *Document) !void {
        const from = self.cursor.selection().start;
        var text: [2 + 256]u8 = undefined;
        const ending = self.line_ending.text();
        @memcpy(text[0..ending.len], ending);
        const indentation = text[ending.len..];
        const line_start = self.buffer.lineStart(self.buffer.lineOf(from));
        const len = self.indentLen(line_start, @min(from - line_start, indentation.len));
        try self.insert(text[0 .. ending.len + self.buffer.copy(line_start, indentation[0..len]).len]);
    }

    /// The Tab key: indents the selected lines, or moves to the next tab stop.
    pub fn indent(self: *Document) !void {
        if (self.cursor.selection().len() > 0) return self.shiftLines(.in);
        const to_stop = self.tab_width - self.columnOf(self.cursor.pos) % self.tab_width;
        try self.insert(if (self.soft_tabs) spaces[0..to_stop] else "\t");
    }

    /// Shift+Tab: removes one level of indentation from the selected lines.
    pub fn outdent(self: *Document) !void {
        try self.shiftLines(.out);
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

    /// Selects the word at `pos`, or one character if there is no word.
    pub fn selectWord(self: *Document, pos: usize) void {
        const len = self.buffer.len();
        var start = @min(pos, len);
        var end = start;
        while (start > 0 and self.isWordAt(self.prev(start))) start = self.prev(start);
        while (end < len and self.isWordAt(end)) end = self.next(end);
        if (start == end) end = self.next(end);
        self.cursor = .{ .anchor = start, .pos = end };
    }

    pub fn selectLine(self: *Document, pos: usize) void {
        const range = self.lineRange(self.buffer.lineOf(@min(pos, self.buffer.len())));
        self.cursor = .{ .anchor = range.start, .pos = range.end };
    }

    /// A whole line with its line break.
    pub fn lineRange(self: *const Document, line: usize) Range {
        const last = line + 1 == self.buffer.lineCount();
        return .{
            .start = self.buffer.lineStart(line),
            .end = if (last) self.buffer.len() else self.buffer.lineStart(line + 1),
        };
    }

    pub fn cells(self: *const Document, line: usize) CellIterator {
        return .{ .doc = self, .pos = self.buffer.lineStart(line), .end = self.buffer.lineEnd(line) };
    }

    /// Screen column of `pos` in its line, with tabs expanded.
    pub fn columnOf(self: *const Document, pos: usize) usize {
        var line = self.cells(self.buffer.lineOf(pos));
        while (line.next()) |cell| {
            if (cell.pos >= pos) return cell.column;
        }
        return line.column;
    }

    /// Position of the character at `column` of `line`, or the line end.
    pub fn posAtColumn(self: *const Document, line: usize, column: usize) usize {
        var line_cells = self.cells(line);
        while (line_cells.next()) |cell| {
            if (cell.column + cell.width > column) return cell.pos;
        }
        return line_cells.end;
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
        return utf8.isWord(self.buffer.charAt(pos).cp);
    }

    /// Number of spaces and tabs at `pos`, counting at most `max`.
    fn indentLen(self: *const Document, pos: usize, max: usize) usize {
        var len: usize = 0;
        while (len < max and pos + len < self.buffer.len()) : (len += 1) {
            const byte = self.buffer.byteAt(pos + len);
            if (byte != ' ' and byte != '\t') break;
        }
        return len;
    }

    /// Indents or outdents every line the selection touches, as one undo
    /// step. A selection stays on the same lines; a lone cursor stays on its
    /// character.
    fn shiftLines(self: *Document, direction: enum { in, out }) !void {
        const selection = self.cursor.selection();
        const caret = self.cursor.pos;
        const first = self.buffer.lineOf(selection.start);
        var last = self.buffer.lineOf(selection.end);
        if (last > first and selection.end == self.buffer.lineStart(last)) last -= 1;

        const unit = if (self.soft_tabs) spaces[0..self.tab_width] else "\t";

        self.history.beginGroup();
        defer self.history.endGroup();
        var removed: usize = 0;
        var line = last + 1;
        while (line > first) {
            line -= 1;
            const start = self.buffer.lineStart(line);
            switch (direction) {
                .in => if (self.buffer.lineEnd(line) > start) try self.replace(.{ .start = start, .end = start }, unit),
                .out => {
                    const len = self.buffer.len();
                    removed = 0;
                    while (removed < self.tab_width and start + removed < len and self.buffer.byteAt(start + removed) == ' ') removed += 1;
                    if (removed == 0 and start < len and self.buffer.byteAt(start) == '\t') removed = 1;
                    try self.replace(.{ .start = start, .end = start + removed }, "");
                },
            }
        }
        const first_start = self.buffer.lineStart(first);
        self.cursor = if (selection.len() > 0)
            .{ .anchor = first_start, .pos = self.buffer.lineEnd(last) }
        else
            .{ .pos = @max(first_start, caret -| removed) };
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
        return self.cursor.goal_col orelse self.columnOf(self.cursor.pos);
    }

    /// Position at the goal column of `line`, or at its end if it is shorter.
    fn atGoalColumn(self: *const Document, line: usize) usize {
        return self.posAtColumn(@min(line, self.buffer.lineCount() - 1), self.goalColumn());
    }
};

const testing = std.testing;
const expectText = @import("buffer.zig").expectText;

/// A document with `text`, for tests.
pub fn testDocument(text: []const u8) !Document {
    var doc = Document.init(testing.allocator);
    errdefer doc.deinit();
    try doc.load(text);
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

test "apply moves the cursors of other views" {
    var doc = try testDocument("one two");
    defer doc.deinit();
    var other: Cursor = .{ .pos = 5 };
    try doc.follow(&other);
    try doc.insert("> ");
    try testing.expectEqual(@as(usize, 7), other.pos);
    _ = try doc.undo();
    try testing.expectEqual(@as(usize, 5), other.pos);
    doc.unfollow(&other);
    try doc.insert("x");
    try testing.expectEqual(@as(usize, 5), other.pos);
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

test "columns expand tabs to the next tab stop" {
    var doc = try testDocument("\ta\tb\n\u{E9}\tz");
    defer doc.deinit();
    for ([_]usize{ 0, 4, 5, 8, 9 }, 0..) |column, pos| try testing.expectEqual(column, doc.columnOf(pos));
    try testing.expectEqual(@as(usize, 4), doc.columnOf(8));

    for ([_]usize{ 0, 0, 0, 0, 1, 2, 2, 2, 3, 4, 4 }, 0..) |pos, column| {
        try testing.expectEqual(pos, doc.posAtColumn(0, column));
    }
    doc.tab_width = 2;
    try testing.expectEqual(@as(usize, 2), doc.columnOf(1));
}

test "up and down keep the screen column across tabs" {
    var doc = try testDocument("\tab\n123456\n\tcd");
    defer doc.deinit();
    doc.cursor.pos = 2;
    try expectMove(&doc, .down, 9);
    try expectMove(&doc, .down, 13);
}

test "select a word and a line" {
    var doc = try testDocument("one two\nthree\n");
    defer doc.deinit();
    doc.selectWord(5);
    try testing.expectEqual(Range{ .start = 4, .end = 7 }, doc.cursor.selection());
    doc.selectWord(7);
    try testing.expectEqual(Range{ .start = 4, .end = 7 }, doc.cursor.selection());
    doc.selectWord(3);
    try testing.expectEqual(Range{ .start = 0, .end = 3 }, doc.cursor.selection());
    doc.selectLine(5);
    try testing.expectEqual(Range{ .start = 0, .end = 8 }, doc.cursor.selection());
    doc.selectLine(10);
    try testing.expectEqual(Range{ .start = 8, .end = 14 }, doc.cursor.selection());
    doc.selectLine(14);
    try testing.expectEqual(Range{ .start = 14, .end = 14 }, doc.cursor.selection());
}

test "a new line keeps the indentation and the line ending" {
    var doc = try testDocument("  \tfoo\r\nbar");
    defer doc.deinit();
    doc.cursor.pos = 6;
    try doc.insertNewline();
    try expectText(&doc.buffer, "  \tfoo\r\n  \t\r\nbar");
    try testing.expectEqual(@as(usize, 11), doc.cursor.pos);

    // Only the indentation before the cursor is copied.
    doc.cursor.pos = 1;
    try doc.insertNewline();
    try expectText(&doc.buffer, " \r\n  \tfoo\r\n  \t\r\nbar");
}

test "paste changes line endings to match the document" {
    var doc = try testDocument("a\r\n");
    defer doc.deinit();
    doc.move(.file_end, false);
    try doc.paste("x\ny\r\nz");
    try expectText(&doc.buffer, "a\r\nx\r\ny\r\nz");
    try testing.expect(try doc.undo());
    try expectText(&doc.buffer, "a\r\n");
}

test "tab moves to the next tab stop" {
    var doc = try testDocument("ab");
    defer doc.deinit();
    doc.cursor.pos = 2;
    try doc.indent();
    try expectText(&doc.buffer, "ab  ");
    try doc.indent();
    try expectText(&doc.buffer, "ab      ");
    doc.soft_tabs = false;
    try doc.indent();
    try expectText(&doc.buffer, "ab      \t");
}

test "tab and shift+tab on a selection shift its lines as one undo step" {
    var doc = try testDocument("one\n\n  two\nthree\nfour");
    defer doc.deinit();
    doc.cursor = .{ .anchor = 1, .pos = 14 };
    try doc.indent();
    try expectText(&doc.buffer, "    one\n\n      two\n    three\nfour");
    try testing.expectEqual(Range{ .start = 0, .end = 28 }, doc.cursor.selection());

    try doc.outdent();
    try doc.outdent();
    try expectText(&doc.buffer, "one\n\ntwo\nthree\nfour");

    try testing.expect(try doc.undo());
    try testing.expect(try doc.undo());
    try expectText(&doc.buffer, "    one\n\n      two\n    three\nfour");
    try testing.expect(try doc.undo());
    try expectText(&doc.buffer, "one\n\n  two\nthree\nfour");
    try testing.expectEqual(Cursor{ .anchor = 1, .pos = 14 }, doc.cursor);
}

test "a selection that ends at a line start does not shift that line" {
    var doc = try testDocument("a\nb\nc");
    defer doc.deinit();
    doc.cursor = .{ .anchor = 0, .pos = 4 };
    try doc.indent();
    try expectText(&doc.buffer, "    a\n    b\nc");
}

test "shift+tab without a selection outdents the line and keeps the cursor on its character" {
    var doc = try testDocument("x\n      abc\n\tz");
    defer doc.deinit();
    doc.cursor.pos = 9;
    try doc.outdent();
    try expectText(&doc.buffer, "x\n  abc\n\tz");
    try testing.expectEqual(@as(usize, 5), doc.cursor.pos);
    try doc.outdent();
    try doc.outdent();
    try expectText(&doc.buffer, "x\nabc\n\tz");
    try testing.expectEqual(@as(usize, 3), doc.cursor.pos);

    doc.cursor.pos = 7;
    try doc.outdent();
    try expectText(&doc.buffer, "x\nabc\nz");
}

test "load resets the cursor and the history and detects the line ending" {
    var doc = try testDocument("old");
    defer doc.deinit();
    doc.move(.file_end, false);
    try doc.insert("er");
    try testing.expect(doc.history.isModified());
    try doc.load("new\r\ntext");
    try testing.expectEqual(Cursor{}, doc.cursor);
    try testing.expect(!doc.history.isModified());
    try testing.expect(!try doc.undo());
    try testing.expectEqual(LineEnding.crlf, doc.line_ending);
}

test "every change raises the revision; a read-only text cannot change" {
    var doc = try testDocument("abc");
    defer doc.deinit();
    const loaded = doc.revision;
    try doc.insert("x");
    try testing.expect(doc.revision != loaded);
    const typed = doc.revision;
    doc.read_only = true;
    try testing.expectError(error.ReadOnly, doc.insert("y"));
    try testing.expectError(error.ReadOnly, doc.undo());
    try expectText(&doc.buffer, "xabc");
    try testing.expectEqual(typed, doc.revision);
}
