//! Comments or uncomments the lines a selection touches, as one undo step:
//! with a line comment marker on each line, or a block comment around them.
const std = @import("std");
const Document = @import("edit.zig").Document;
const Range = @import("buffer.zig").Range;

/// `end` is empty for a line comment, like `//`; else `start` and `end`
/// wrap the lines, like `/*` and `*/`.
pub fn toggle(doc: *Document, start: []const u8, end: []const u8) !void {
    const lines = touchedLines(doc);
    // The cursor stays on its text while the lines change.
    var cursor = doc.cursor;
    try doc.follow(&cursor);
    defer {
        doc.unfollow(&cursor);
        doc.cursor = cursor;
    }
    doc.history.beginGroup();
    defer doc.history.endGroup();
    if (end.len == 0) try toggleLines(doc, lines, start) else try toggleBlock(doc, lines, start, end);
}

/// First and last line, without a last line the selection only touches at its start.
fn touchedLines(doc: *const Document) [2]usize {
    const selection = doc.cursor.selection();
    const first = doc.buffer.lineOf(selection.start);
    var last = doc.buffer.lineOf(selection.end);
    if (last > first and selection.end == doc.buffer.lineStart(last)) last -= 1;
    return .{ first, last };
}

/// Spaces and tabs at the start of `line`.
fn indent(doc: *const Document, line: usize) usize {
    const start = doc.buffer.lineStart(line);
    const end = doc.buffer.lineEnd(line);
    var at = start;
    while (at < end and (doc.buffer.byteAt(at) == ' ' or doc.buffer.byteAt(at) == '\t')) at += 1;
    return at - start;
}

fn isBlank(doc: *const Document, line: usize) bool {
    return doc.buffer.lineStart(line) + indent(doc, line) == doc.buffer.lineEnd(line);
}

fn startsWithAt(doc: *const Document, pos: usize, text: []const u8) bool {
    if (pos + text.len > doc.buffer.len()) return false;
    for (text, pos..) |byte, at| if (doc.buffer.byteAt(at) != byte) return false;
    return true;
}

fn toggleLines(doc: *Document, lines: [2]usize, marker: []const u8) !void {
    var all_blank = true;
    var commented = true;
    var column: usize = std.math.maxInt(usize);
    for (lines[0]..lines[1] + 1) |line| {
        if (isBlank(doc, line)) continue;
        all_blank = false;
        column = @min(column, indent(doc, line));
        if (!startsWithAt(doc, doc.buffer.lineStart(line) + indent(doc, line), marker)) commented = false;
    }
    if (all_blank) {
        commented = false;
        column = 0;
    }
    // From the last line up, so the lines above do not move.
    var line = lines[1] + 1;
    while (line > lines[0]) {
        line -= 1;
        if (!all_blank and isBlank(doc, line)) continue;
        const start = doc.buffer.lineStart(line);
        if (commented) {
            const at = start + indent(doc, line);
            const space = @intFromBool(startsWithAt(doc, at + marker.len, " "));
            try doc.replace(.{ .start = at, .end = at + marker.len + space }, "");
        } else {
            const text = try std.mem.concat(doc.buffer.allocator, u8, &.{ marker, " " });
            defer doc.buffer.allocator.free(text);
            try doc.replace(.{ .start = start + column, .end = start + column }, text);
        }
    }
}

fn toggleBlock(doc: *Document, lines: [2]usize, start: []const u8, end: []const u8) !void {
    const from = doc.buffer.lineStart(lines[0]) + indent(doc, lines[0]);
    const to = doc.buffer.lineEnd(lines[1]);
    if (to >= from + start.len + end.len and startsWithAt(doc, from, start) and startsWithAt(doc, to - end.len, end)) {
        const before = @intFromBool(to - end.len > from + start.len and doc.buffer.byteAt(to - end.len - 1) == ' ');
        try doc.replace(.{ .start = to - end.len - before, .end = to }, "");
        const after = @intFromBool(startsWithAt(doc, from + start.len, " "));
        try doc.replace(.{ .start = from, .end = from + start.len + after }, "");
        return;
    }
    const allocator = doc.buffer.allocator;
    const closing = try std.mem.concat(allocator, u8, &.{ " ", end });
    defer allocator.free(closing);
    try doc.replace(.{ .start = to, .end = to }, closing);
    const opening = try std.mem.concat(allocator, u8, &.{ start, " " });
    defer allocator.free(opening);
    try doc.replace(.{ .start = from, .end = from }, opening);
}

const testing = std.testing;
const expectText = @import("buffer.zig").expectText;

fn testDocument(text: []const u8) !Document {
    var doc = Document.init(testing.allocator);
    errdefer doc.deinit();
    try doc.load(text);
    return doc;
}

test "line comments at the smallest indent, then off again; one undo step" {
    var doc = try testDocument("if x:\n    a\n\n  b\nc");
    defer doc.deinit();
    doc.cursor = .{ .anchor = 6, .pos = 17 };
    try toggle(&doc, "#", "");
    try expectText(&doc.buffer, "if x:\n  #   a\n\n  # b\nc");
    try toggle(&doc, "#", "");
    try expectText(&doc.buffer, "if x:\n    a\n\n  b\nc");
    try testing.expect(try doc.undo());
    try expectText(&doc.buffer, "if x:\n  #   a\n\n  # b\nc");
    try testing.expect(try doc.undo());
    try expectText(&doc.buffer, "if x:\n    a\n\n  b\nc");
}

test "mixed lines get commented; the cursor stays on its text" {
    var doc = try testDocument("// a\nb");
    defer doc.deinit();
    doc.cursor = .{ .anchor = 0, .pos = 6 };
    try toggle(&doc, "//", "");
    try expectText(&doc.buffer, "// // a\n// b");
    doc.cursor = .{ .pos = 12 };
    try toggle(&doc, "//", "");
    try expectText(&doc.buffer, "// // a\nb");
    try testing.expectEqual(@as(usize, 9), doc.cursor.pos);
}

test "a block comment around the lines, and off again" {
    var doc = try testDocument("  a {\n  }\nnext");
    defer doc.deinit();
    doc.cursor = .{ .anchor = 2, .pos = 10 };
    try toggle(&doc, "<!--", "-->");
    try expectText(&doc.buffer, "  <!-- a {\n  } -->\nnext");
    try toggle(&doc, "<!--", "-->");
    try expectText(&doc.buffer, "  a {\n  }\nnext");
    // A blank line gets a marker too.
    var blank = try testDocument("");
    defer blank.deinit();
    try toggle(&blank, "#", "");
    try expectText(&blank.buffer, "# ");
}
