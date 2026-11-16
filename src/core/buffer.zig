//! Text of one file as a gap buffer, plus an index of line starts.
const std = @import("std");
const assert = std.debug.assert;
const utf8 = @import("utf8.zig");

/// Half-open range of buffer positions.
pub const Range = struct {
    start: usize,
    end: usize,

    pub fn between(a: usize, b: usize) Range {
        return .{ .start = @min(a, b), .end = @max(a, b) };
    }

    pub fn len(self: Range) usize {
        return self.end - self.start;
    }
};

pub const Buffer = struct {
    allocator: std.mem.Allocator,
    data: []u8 = &.{},
    gap_start: usize = 0,
    gap_end: usize = 0,
    /// Start of every line but the first, which always starts at 0.
    line_starts: std.ArrayList(usize) = .empty,

    pub fn init(allocator: std.mem.Allocator) Buffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.data);
        self.line_starts.deinit(self.allocator);
    }

    pub fn load(self: *Buffer, bytes: []const u8) !void {
        self.delete(0, self.len());
        try self.insert(0, bytes);
    }

    pub fn len(self: *const Buffer) usize {
        return self.data.len - self.gapLen();
    }

    /// Leaves the buffer unchanged on failure.
    pub fn insert(self: *Buffer, pos: usize, text: []const u8) !void {
        assert(pos <= self.len());
        if (text.len == 0) return;
        const newlines = std.mem.countScalar(u8, text, '\n');
        try self.line_starts.ensureUnusedCapacity(self.allocator, newlines);
        try self.reserveGap(text.len);

        self.moveGap(pos);
        @memcpy(self.data[self.gap_start..][0..text.len], text);
        self.gap_start += text.len;

        const first = self.lineOf(pos);
        for (self.line_starts.items[first..]) |*start| start.* += text.len;
        const added = self.line_starts.addManyAtAssumeCapacity(first, newlines);
        var n: usize = 0;
        for (text, 1..) |byte, after| {
            if (byte != '\n') continue;
            added[n] = pos + after;
            n += 1;
        }
    }

    pub fn delete(self: *Buffer, pos: usize, count: usize) void {
        assert(pos + count <= self.len());
        if (count == 0) return;
        self.moveGap(pos);
        self.gap_end += count;

        const first = self.lineOf(pos);
        const last = self.lineOf(pos + count);
        self.line_starts.replaceRangeAssumeCapacity(first, last - first, &.{});
        for (self.line_starts.items[first..]) |*start| start.* -= count;
    }

    pub fn byteAt(self: *const Buffer, pos: usize) u8 {
        return self.data[self.raw(pos)];
    }

    /// The character that starts at `pos`, which must be before the end.
    pub fn charAt(self: *const Buffer, pos: usize) utf8.Char {
        var window: [4]u8 = undefined;
        return utf8.decode(self.copy(pos, &window));
    }

    /// The whole text as the part before the gap and the part after it.
    pub fn halves(self: *const Buffer) [2][]const u8 {
        return .{ self.data[0..self.gap_start], self.data[self.gap_end..] };
    }

    /// Copies text starting at `pos` into `dest` and returns the filled part,
    /// which is shorter than `dest` only at the end of the buffer.
    pub fn copy(self: *const Buffer, pos: usize, dest: []u8) []u8 {
        const out = dest[0..@min(dest.len, self.len() - pos)];
        const head = @min(out.len, self.gap_start -| pos);
        @memcpy(out[0..head], self.data[pos..][0..head]);
        const tail = out[head..];
        if (tail.len > 0) @memcpy(tail, self.data[self.raw(pos + head)..][0..tail.len]);
        return out;
    }

    pub fn lineCount(self: *const Buffer) usize {
        return self.line_starts.items.len + 1;
    }

    pub fn lineStart(self: *const Buffer, line: usize) usize {
        return if (line == 0) 0 else self.line_starts.items[line - 1];
    }

    /// End of the line, before its LF or CRLF.
    pub fn lineEnd(self: *const Buffer, line: usize) usize {
        if (line + 1 == self.lineCount()) return self.len();
        const end = self.lineStart(line + 1) - 1;
        const crlf = end > self.lineStart(line) and self.byteAt(end - 1) == '\r';
        return if (crlf) end - 1 else end;
    }

    /// Binary search: the number of stored line starts at or before `pos`.
    pub fn lineOf(self: *const Buffer, pos: usize) usize {
        const starts = self.line_starts.items;
        var low: usize = 0;
        var high: usize = starts.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (starts[mid] <= pos) low = mid + 1 else high = mid;
        }
        return low;
    }

    fn gapLen(self: *const Buffer) usize {
        return self.gap_end - self.gap_start;
    }

    fn raw(self: *const Buffer, pos: usize) usize {
        return if (pos < self.gap_start) pos else pos + self.gapLen();
    }

    fn reserveGap(self: *Buffer, need: usize) !void {
        if (self.gapLen() >= need) return;
        const tail = self.data[self.gap_end..];
        const grown = try self.allocator.alloc(u8, @max(self.data.len * 2, self.len() + need));
        @memcpy(grown[0..self.gap_start], self.data[0..self.gap_start]);
        @memcpy(grown[grown.len - tail.len ..], tail);
        self.gap_end = grown.len - tail.len;
        self.allocator.free(self.data);
        self.data = grown;
    }

    fn moveGap(self: *Buffer, pos: usize) void {
        if (pos == self.gap_start) return;
        const gap = self.gapLen();
        if (pos < self.gap_start) {
            std.mem.copyBackwards(u8, self.data[pos + gap .. self.gap_end], self.data[pos..self.gap_start]);
        } else {
            std.mem.copyForwards(u8, self.data[self.gap_start..pos], self.data[self.gap_end .. pos + gap]);
        }
        self.gap_start = pos;
        self.gap_end = pos + gap;
    }
};

const testing = std.testing;

pub fn expectText(buffer: *const Buffer, expected: []const u8) !void {
    const text = try testing.allocator.alloc(u8, buffer.len());
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, buffer.copy(0, text));
}

/// The incremental line index must match a fresh scan of the text.
fn expectLinesMatchText(buffer: *const Buffer) !void {
    var line: usize = 0;
    for (0..buffer.len()) |pos| {
        try testing.expectEqual(line, buffer.lineOf(pos));
        if (buffer.byteAt(pos) != '\n') continue;
        line += 1;
        try testing.expectEqual(pos + 1, buffer.lineStart(line));
    }
    try testing.expectEqual(line + 1, buffer.lineCount());
}

test "insert at the start, middle and end, and into an empty buffer" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try expectText(&b, "");
    try b.insert(0, "bd");
    try b.insert(0, "a");
    try b.insert(2, "c");
    try b.insert(4, "e");
    try expectText(&b, "abcde");
    try testing.expectEqual(@as(usize, 5), b.len());
}

test "delete at the start, middle and end, and in an empty buffer" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    b.delete(0, 0);
    try b.load("abcdefg");
    b.delete(0, 2);
    b.delete(1, 2);
    b.delete(2, 1);
    try expectText(&b, "cf");
    b.delete(0, 2);
    try expectText(&b, "");
}

test "the gap only moves when the edit position changes" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("hello world");
    try b.insert(5, ",");
    try testing.expectEqual(@as(usize, 6), b.gap_start);
    try b.insert(6, "!");
    try testing.expectEqual(@as(usize, 7), b.gap_start);
    b.delete(7, 1);
    try testing.expectEqual(@as(usize, 7), b.gap_start);
    try expectText(&b, "hello,!world");
}

test "copy a range across the gap, and byteAt" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("0123456789");
    try b.insert(5, "-");
    var out: [4]u8 = undefined;
    try testing.expectEqualStrings("34-5", b.copy(3, &out));
    try testing.expectEqualStrings("0123", b.copy(0, &out));
    try testing.expectEqualStrings("89", b.copy(9, &out));
    try testing.expectEqualStrings("", b.copy(11, &out));
    try testing.expectEqual(@as(u8, '-'), b.byteAt(5));
    try testing.expectEqual(@as(u8, '9'), b.byteAt(10));
}

test "charAt and halves see through the gap" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("a\u{E9}z");
    try b.insert(1, "-");
    try testing.expectEqual(utf8.Char{ .cp = 0xE9, .len = 2 }, b.charAt(2));
    const halves = b.halves();
    try testing.expectEqualStrings("a-", halves[0]);
    try testing.expectEqualStrings("\u{E9}z", halves[1]);
}

test "load replaces the text" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("one\ntwo");
    try b.load("three");
    try expectText(&b, "three");
    try testing.expectEqual(@as(usize, 1), b.lineCount());
}

test "line index follows inserts and deletes" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try testing.expectEqual(@as(usize, 1), b.lineCount());
    try testing.expectEqual(@as(usize, 0), b.lineOf(0));

    try b.load("one\ntwo\nthree");
    try testing.expectEqual(@as(usize, 3), b.lineCount());
    try testing.expectEqual(@as(usize, 4), b.lineStart(1));
    try testing.expectEqual(@as(usize, 8), b.lineStart(2));
    try testing.expectEqual(@as(usize, 0), b.lineOf(3));
    try testing.expectEqual(@as(usize, 1), b.lineOf(4));
    try testing.expectEqual(@as(usize, 2), b.lineOf(13));

    try b.insert(4, "1\n2\n");
    try expectLinesMatchText(&b);
    try testing.expectEqual(@as(usize, 5), b.lineCount());

    b.delete(2, 5);
    try expectText(&b, "on\ntwo\nthree");
    try expectLinesMatchText(&b);

    b.delete(2, 1);
    try b.insert(0, "\n");
    try b.insert(b.len(), "\n");
    try expectLinesMatchText(&b);
}

test "an edit only updates the lines after it" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("a\nb\nc\nd");
    try b.insert(3, "xx");
    try testing.expectEqualSlices(usize, &.{ 2, 6, 8 }, b.line_starts.items);
    b.delete(3, 2);
    try testing.expectEqualSlices(usize, &.{ 2, 4, 6 }, b.line_starts.items);
}

test "line ends with LF and CRLF" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    try b.load("ab\r\ncd\n\r\nef");
    try testing.expectEqual(@as(usize, 4), b.lineCount());
    try testing.expectEqual(@as(usize, 2), b.lineEnd(0));
    try testing.expectEqual(@as(usize, 4), b.lineStart(1));
    try testing.expectEqual(@as(usize, 6), b.lineEnd(1));
    try testing.expectEqual(@as(usize, 7), b.lineEnd(2));
    try testing.expectEqual(@as(usize, 11), b.lineEnd(3));
}

test "random edits match a plain array" {
    var b = Buffer.init(testing.allocator);
    defer b.deinit();
    var model: std.ArrayList(u8) = .empty;
    defer model.deinit(testing.allocator);

    var prng = std.Random.DefaultPrng.init(8);
    const random = prng.random();
    for (0..2000) |_| {
        const pos = random.uintAtMost(usize, model.items.len);
        if (random.boolean()) {
            const text = "ab\ncd\r\n"[0..random.uintAtMost(usize, 7)];
            try b.insert(pos, text);
            try model.insertSlice(testing.allocator, pos, text);
        } else {
            const count = random.uintAtMost(usize, @min(5, model.items.len - pos));
            b.delete(pos, count);
            model.replaceRangeAssumeCapacity(pos, count, &.{});
        }
    }
    try expectText(&b, model.items);
    try expectLinesMatchText(&b);
}
