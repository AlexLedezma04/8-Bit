//! Plain text search with match case and whole word options. Text comes in
//! two parts, like the halves of a gap buffer, so nothing is copied. Used by
//! find and replace.
const std = @import("std");
const Range = @import("buffer.zig").Range;
const Document = @import("edit.zig").Document;
const utf8 = @import("utf8.zig");

pub const Options = struct { match_case: bool = false, whole_word: bool = false };

/// The text to search: the part before the gap and the part after it.
pub const Text = [2][]const u8;

pub fn textOf(doc: *const Document) Text {
    return doc.buffer.halves();
}

pub const Query = struct {
    needle: []const u8,
    options: Options = .{},

    /// Start of the first match at or after `from`.
    pub fn next(self: Query, text: Text, from: usize) ?usize {
        const len = self.needle.len;
        if (len == 0) return null;
        if (self.scan(text, 0, from)) |pos| return pos;
        // Matches that cross the gap.
        const head = text[0].len;
        var pos = @max(from, head -| (len - 1));
        while (pos < head and pos + len <= head + text[1].len) : (pos += 1) {
            if (self.isAt(text, pos) and self.isWhole(text, pos)) return pos;
        }
        return self.scan(text, 1, from);
    }

    /// Every match, in order, without overlaps.
    pub fn all(self: Query, allocator: std.mem.Allocator, text: Text, out: *std.ArrayList(Range)) !void {
        out.clearRetainingCapacity();
        var from: usize = 0;
        while (self.next(text, from)) |start| {
            try out.append(allocator, .{ .start = start, .end = start + self.needle.len });
            from = start + self.needle.len;
        }
    }

    /// The first match inside one part.
    fn scan(self: Query, text: Text, part: u1, from: usize) ?usize {
        const base = if (part == 0) 0 else text[0].len;
        const bytes = text[part];
        var at = from -| base;
        while (at + self.needle.len <= bytes.len) {
            const found = (if (self.options.match_case)
                std.mem.findPos(u8, bytes, at, self.needle)
            else
                std.ascii.findIgnoreCasePos(bytes, at, self.needle)) orelse return null;
            if (self.isWhole(text, base + found)) return base + found;
            at = found + 1;
        }
        return null;
    }

    fn isAt(self: Query, text: Text, pos: usize) bool {
        for (self.needle, pos..) |want, i| {
            const have = byteAt(text, i);
            if (if (self.options.match_case) have != want else std.ascii.toLower(have) != std.ascii.toLower(want)) return false;
        }
        return true;
    }

    /// With whole word, no word character touches either end.
    fn isWhole(self: Query, text: Text, pos: usize) bool {
        if (!self.options.whole_word) return true;
        const end = pos + self.needle.len;
        if (pos > 0 and utf8.isWord(byteAt(text, pos - 1))) return false;
        return end >= text[0].len + text[1].len or !utf8.isWord(byteAt(text, end));
    }
};

fn byteAt(text: Text, pos: usize) u8 {
    return if (pos < text[0].len) text[0][pos] else text[1][pos - text[0].len];
}

/// Replaces every match as one undo step and returns how many there were.
pub fn replaceAll(doc: *Document, query: Query, replacement: []const u8) !usize {
    const allocator = doc.buffer.allocator;
    var matches: std.ArrayList(Range) = .empty;
    defer matches.deinit(allocator);
    try query.all(allocator, textOf(doc), &matches);
    doc.history.beginGroup();
    defer doc.history.endGroup();
    // From the end, so the ranges still to replace do not move.
    var i = matches.items.len;
    while (i > 0) {
        i -= 1;
        try doc.replace(matches.items[i], replacement);
    }
    return matches.items.len;
}

const testing = std.testing;
const expectText = @import("buffer.zig").expectText;

fn starts(query: Query, text: Text) ![]const usize {
    var found: std.ArrayList(Range) = .empty;
    defer found.deinit(testing.allocator);
    try query.all(testing.allocator, text, &found);
    const result = try testing.allocator.alloc(usize, found.items.len);
    for (found.items, result) |range, *start| start.* = range.start;
    return result;
}

fn expectStarts(query: Query, text: Text, expected: []const usize) !void {
    const found = try starts(query, text);
    defer testing.allocator.free(found);
    try testing.expectEqualSlices(usize, expected, found);
}

test "match case and ignore case" {
    try expectStarts(.{ .needle = "ab" }, .{ "Ab ab AB", "" }, &.{ 0, 3, 6 });
    try expectStarts(.{ .needle = "ab", .options = .{ .match_case = true } }, .{ "Ab ab AB", "" }, &.{3});
    try expectStarts(.{ .needle = "" }, .{ "abc", "" }, &.{});
    try expectStarts(.{ .needle = "aa" }, .{ "aaaa", "" }, &.{ 0, 2 });
}

test "whole word" {
    const query: Query = .{ .needle = "is", .options = .{ .whole_word = true } };
    try expectStarts(query, .{ "is this is_it (is) is", "" }, &.{ 0, 15, 19 });
    // Non-ASCII letters are word characters.
    try expectStarts(query, .{ "éis is", "" }, &.{5});
}

test "matches in both halves and across the gap" {
    // "one two one" split inside the second "one".
    try expectStarts(.{ .needle = "one" }, .{ "one two o", "ne" }, &.{ 0, 8 });
    try expectStarts(.{ .needle = "ONE", .options = .{ .whole_word = true } }, .{ "one two o", "ne" }, &.{ 0, 8 });
    try expectStarts(.{ .needle = "two" }, .{ "", "one two" }, &.{4});
    try expectStarts(.{ .needle = "ne" }, .{ "o", "ne" }, &.{1});
    try testing.expectEqual(@as(?usize, 8), (Query{ .needle = "one" }).next(.{ "one two o", "ne" }, 1));
    try testing.expectEqual(@as(?usize, null), (Query{ .needle = "one" }).next(.{ "one two o", "ne" }, 9));
}

test "a document is searched where it is, gap included" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    try doc.load("say hi, hi");
    doc.cursor.pos = 9;
    try doc.insert("!");
    const text = textOf(&doc);
    try testing.expect(text[1].len > 0);
    try expectStarts(.{ .needle = "h!i" }, text, &.{8});
}

test "replace all is one undo step" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    try doc.load("cat, Cat and cats");
    try testing.expectEqual(@as(usize, 2), try replaceAll(&doc, .{ .needle = "cat", .options = .{ .whole_word = true } }, "dog"));
    try expectText(&doc.buffer, "dog, dog and cats");
    try testing.expectEqual(@as(usize, 2), try replaceAll(&doc, .{ .needle = "dog" }, ""));
    try expectText(&doc.buffer, ",  and cats");
    try testing.expect(try doc.undo());
    try expectText(&doc.buffer, "dog, dog and cats");
    try testing.expect(try doc.undo());
    try expectText(&doc.buffer, "cat, Cat and cats");
}
