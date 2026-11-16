//! Highlighting: turns a line into styled spans with a grammar, and keeps
//! the state each line starts in (inside a block comment or a long string).
//! States are found only down to the lines that are asked for, and an edit
//! drops them from the changed line on. Also finds matching brackets.
const std = @import("std");
const grammar = @import("grammar.zig");
const Rules = grammar.Rules;
const Style = grammar.Style;
const Document = @import("../core/edit.zig").Document;

/// What a line starts inside of: 0 nothing, 1 a block comment, 2 + i the
/// multiline string `strings[i]`.
pub const State = u8;
const normal: State = 0;
const in_comment: State = 1;

/// Bytes of a line that are read; the rest of a longer line stays plain.
pub const max_line = 10_000;
/// Lines searched for a matching bracket.
const max_bracket_lines = 2_000;
pub const brackets = "()[]{}";

/// Byte offsets in the line.
pub const Span = struct { start: usize, end: usize, style: Style };

/// Styles one line and returns the state the next line starts in. Plain
/// text gets no span; spans are in order.
pub fn tokenize(allocator: std.mem.Allocator, rules: *const Rules, text: []const u8, start: State, out: *std.ArrayList(Span)) !State {
    out.clearRetainingCapacity();
    var line: Line = .{ .allocator = allocator, .rules = rules, .text = text, .out = out };
    return line.run(start);
}

const Line = struct {
    allocator: std.mem.Allocator,
    rules: *const Rules,
    text: []const u8,
    out: *std.ArrayList(Span),
    pos: usize = 0,

    fn run(self: *Line, start: State) !State {
        const g = &self.rules.grammar;
        const text = self.text;
        if (start == in_comment) {
            if (!try self.blockComment(0)) return in_comment;
        } else if (start != normal) {
            if (!try self.quote(start - 2, 0)) return start;
        } else for (g.line_starts) |mark| if (std.mem.startsWith(u8, text, mark.text)) {
            try self.add(0, text.len, mark.style);
            return normal;
        };
        while (self.pos < text.len) {
            const rest = text[self.pos..];
            const byte = rest[0];
            if (byte == ' ' or byte == '\t') {
                self.pos += 1;
            } else if (g.block_comment != null and std.mem.startsWith(u8, rest, g.block_comment.?.start)) {
                if (!try self.blockComment(g.block_comment.?.start.len)) return in_comment;
            } else if (startsWithAny(rest, g.line_comments)) {
                try self.add(self.pos, text.len, .comment);
                break;
            } else if (quoteAt(g.strings, rest)) |i| {
                if (!try self.quote(i, g.strings[i].start.len)) return if (g.strings[i].multiline) @intCast(i + 2) else normal;
            } else if (markAt(g.prefixes, rest)) |mark| {
                try self.add(self.pos, self.wordEnd(self.pos + mark.text.len), mark.style);
            } else if (g.numbers and std.ascii.isDigit(byte) and (self.pos == 0 or !self.rules.isWordChar(text[self.pos - 1]))) {
                try self.add(self.pos, self.numberEnd(), .number);
            } else if (self.rules.isWordChar(byte)) {
                const end = self.wordEnd(self.pos);
                try self.add(self.pos, end, self.rules.lookup(text[self.pos..end]) orelse self.wordStyle(end));
            } else {
                const style: Style = if (std.mem.findScalar(u8, g.operators, byte) != null)
                    .operator
                else if (std.mem.findScalar(u8, g.punctuation, byte) != null)
                    .punctuation
                else
                    .text;
                try self.add(self.pos, self.pos + 1, style);
            }
        }
        return normal;
    }

    /// Adds a span and moves past it. Next to a span of the same style, it
    /// grows that one.
    fn add(self: *Line, start: usize, end: usize, style: Style) !void {
        self.pos = end;
        if (style == .text or end == start) return;
        const items = self.out.items;
        if (items.len > 0 and items[items.len - 1].end == start and items[items.len - 1].style == style) {
            items[items.len - 1].end = end;
        } else {
            try self.out.append(self.allocator, .{ .start = start, .end = end, .style = style });
        }
    }

    /// A block comment from here, after `skip` bytes of its start. False
    /// when it goes on past the line.
    fn blockComment(self: *Line, skip: usize) !bool {
        const close = self.rules.grammar.block_comment.?.end;
        const end = std.mem.findPos(u8, self.text, self.pos + skip, close);
        try self.add(self.pos, if (end) |at| at + close.len else self.text.len, .comment);
        return end != null;
    }

    /// The string `strings[index]` from here, after `skip` bytes of its
    /// start. False when it is not closed on this line.
    fn quote(self: *Line, index: usize, skip: usize) !bool {
        const q = self.rules.grammar.strings[index];
        const close = q.closer();
        var at = self.pos + skip;
        while (at < self.text.len) {
            if (q.escape and self.text[at] == '\\') {
                at += 2;
            } else if (std.mem.startsWith(u8, self.text[at..], close)) {
                try self.add(self.pos, at + close.len, q.style);
                return true;
            } else {
                at += 1;
            }
        }
        try self.add(self.pos, self.text.len, q.style);
        return false;
    }

    /// A word that is no keyword: a function call, a key, or plain.
    fn wordStyle(self: *const Line, end: usize) Style {
        const g = &self.rules.grammar;
        if (g.functions and end < self.text.len and self.text[end] == '(') return .function;
        var next = end;
        while (next < self.text.len and (self.text[next] == ' ' or self.text[next] == '\t')) next += 1;
        if (next < self.text.len and std.mem.findScalar(u8, g.key_before, self.text[next]) != null) return .type;
        return .text;
    }

    fn wordEnd(self: *const Line, from: usize) usize {
        var end = from;
        while (end < self.text.len and self.rules.isWordChar(self.text[end])) end += 1;
        return end;
    }

    /// Digits, letters and `_`, and a `.` with a digit after it.
    fn numberEnd(self: *const Line) usize {
        const text = self.text;
        var end = self.pos;
        while (end < text.len) : (end += 1) {
            const byte = text[end];
            if (std.ascii.isAlphanumeric(byte) or byte == '_') continue;
            if (byte == '.' and end + 1 < text.len and std.ascii.isDigit(text[end + 1])) continue;
            break;
        }
        return end;
    }
};

fn startsWithAny(text: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |prefix| if (prefix.len > 0 and std.mem.startsWith(u8, text, prefix)) return true;
    return false;
}

fn quoteAt(quotes: []const grammar.Quote, text: []const u8) ?usize {
    for (quotes, 0..) |q, i| if (std.mem.startsWith(u8, text, q.start)) return i;
    return null;
}

fn markAt(marks: []const grammar.Mark, text: []const u8) ?grammar.Mark {
    for (marks) |mark| if (std.mem.startsWith(u8, text, mark.text)) return mark;
    return null;
}

/// The style at a byte of a line.
pub fn styleAt(spans: []const Span, offset: usize) Style {
    for (spans) |span| {
        if (offset < span.start) break;
        if (offset < span.end) return span.style;
    }
    return .text;
}

/// The highlighting of one document.
pub const Highlighter = struct {
    allocator: std.mem.Allocator,
    /// Null for plain text.
    rules: ?*const Rules = null,
    /// The state each line starts in, known for the first `states.len` lines.
    states: std.ArrayList(State) = .empty,
    /// The line last read by `spans`.
    text: std.ArrayList(u8) = .empty,
    scratch: std.ArrayList(Span) = .empty,

    pub fn deinit(self: *Highlighter) void {
        self.states.deinit(self.allocator);
        self.text.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
    }

    pub fn setRules(self: *Highlighter, rules: ?*const Rules) void {
        self.rules = rules;
        self.states.clearRetainingCapacity();
    }

    /// The spans of `line` into `out`; `text` then holds the line. Only the
    /// lines before it whose state is not known yet are read too.
    pub fn spans(self: *Highlighter, doc: *Document, line: usize, out: *std.ArrayList(Span)) void {
        out.clearRetainingCapacity();
        const state = if (self.rules) |rules| self.stateAt(doc, rules, line) catch normal else normal;
        self.readLine(doc, line);
        const rules = self.rules orelse return;
        _ = tokenize(self.allocator, rules, self.text.items, state, out) catch out.clearRetainingCapacity();
    }

    fn readLine(self: *Highlighter, doc: *const Document, line: usize) void {
        const start = doc.buffer.lineStart(line);
        const len = @min(doc.buffer.lineEnd(line) - start, max_line);
        self.text.resize(self.allocator, len) catch return self.text.clearRetainingCapacity();
        _ = doc.buffer.copy(start, self.text.items);
    }

    fn stateAt(self: *Highlighter, doc: *Document, rules: *const Rules, line: usize) !State {
        if (doc.changed_from) |changed| {
            if (self.states.items.len > changed + 1) self.states.shrinkRetainingCapacity(changed + 1);
            doc.changed_from = null;
        }
        if (self.states.items.len == 0) try self.states.append(self.allocator, normal);
        while (self.states.items.len <= line) {
            const last = self.states.items.len - 1;
            self.readLine(doc, last);
            const next = try tokenize(self.allocator, rules, self.text.items, self.states.items[last], &self.scratch);
            try self.states.append(self.allocator, next);
        }
        return self.states.items[line];
    }

    /// The bracket right after `pos`, else right before it, and its
    /// partner. Brackets in strings and comments do not count.
    pub fn matchBracket(self: *Highlighter, doc: *Document, pos: usize) ?[2]usize {
        const len = doc.buffer.len();
        for ([_]usize{ pos, pos -% 1 }) |at| {
            if (at >= len) continue;
            if (std.mem.findScalar(u8, brackets, doc.buffer.byteAt(at)) == null) continue;
            if (!self.isCode(doc, at)) continue;
            return .{ at, self.partnerOf(doc, at) orelse return null };
        }
        return null;
    }

    fn isCode(self: *Highlighter, doc: *Document, pos: usize) bool {
        const line = doc.buffer.lineOf(pos);
        self.spans(doc, line, &self.scratch);
        const style = styleAt(self.scratch.items, pos - doc.buffer.lineStart(line));
        return style != .comment and style != .string;
    }

    /// Walks from the bracket at `at` to the one that closes or opens it.
    fn partnerOf(self: *Highlighter, doc: *Document, at: usize) ?usize {
        const kind = std.mem.findScalar(u8, brackets, doc.buffer.byteAt(at)).?;
        const forward = kind % 2 == 0;
        const inward = brackets[kind];
        const outward = brackets[kind ^ 1];
        var depth: usize = 0;
        var line = doc.buffer.lineOf(at);
        for (0..max_bracket_lines) |_| {
            self.spans(doc, line, &self.scratch);
            const start = doc.buffer.lineStart(line);
            const text = self.text.items;
            var i: usize = if (line == doc.buffer.lineOf(at)) at - start else if (forward) 0 else text.len -% 1;
            while (i < text.len) : (i = if (forward) i + 1 else i -% 1) {
                const style = styleAt(self.scratch.items, i);
                if (style == .comment or style == .string) continue;
                if (text[i] == inward) depth += 1;
                if (text[i] == outward) {
                    depth -= 1;
                    if (depth == 0) return start + i;
                }
            }
            if (forward and line + 1 >= doc.buffer.lineCount()) return null;
            if (!forward and line == 0) return null;
            line = if (forward) line + 1 else line - 1;
        }
        return null;
    }
};

const testing = std.testing;

fn testRules(arena: std.mem.Allocator) !Rules {
    return Rules.init(arena, .{
        .name = "Test",
        .line_comments = &.{"//"},
        .block_comment = .{ .start = "/*", .end = "*/" },
        .strings = &.{ .{ .start = "\"\"\"", .multiline = true }, .{ .start = "\"" }, .{ .start = "'", .escape = false } },
        .keywords = &.{ "fn", "return" },
        .types = &.{"u8"},
        .operators = "=+-",
        .word_chars = "$",
        .prefixes = &.{.{ .text = "@", .style = .builtin }},
        .line_starts = &.{.{ .text = "#!", .style = .comment }},
        .key_before = ":",
    });
}

/// "text" of each span, joined: `fn:keyword main:function`.
fn expectSpans(rules: *const Rules, text: []const u8, start: State, expected: []const u8, end: State) !void {
    var out: std.ArrayList(Span) = .empty;
    defer out.deinit(testing.allocator);
    const state = try tokenize(testing.allocator, rules, text, start, &out);
    var shown: std.ArrayList(u8) = .empty;
    defer shown.deinit(testing.allocator);
    for (out.items, 0..) |span, i| {
        if (i > 0) try shown.append(testing.allocator, ' ');
        try shown.print(testing.allocator, "{s}:{t}", .{ text[span.start..span.end], span.style });
    }
    try testing.expectEqualStrings(expected, shown.items);
    try testing.expectEqual(end, state);
}

test "words: keywords, types, functions, prefixes, word characters" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const rules = try testRules(arena.allocator());
    try expectSpans(&rules, "fn main(x: u8) u8 {", 0, "fn:keyword main:function (:punctuation x:type u8:type ):punctuation u8:type {:punctuation", 0);
    try expectSpans(&rules, "return @import $fn", 0, "return:keyword @import:builtin", 0);
    try expectSpans(&rules, "name : x", 0, "name:type", 0);
}

test "numbers, operators and punctuation" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const rules = try testRules(arena.allocator());
    try expectSpans(&rules, "x = 0x1F + 1.5e3; y2 -= 3..4", 0, "=:operator 0x1F:number +:operator 1.5e3:number ;:punctuation -=:operator 3:number 4:number", 0);
}

test "line comments, and comment markers inside strings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const rules = try testRules(arena.allocator());
    try expectSpans(&rules, "x // fn note", 0, "// fn note:comment", 0);
    try expectSpans(&rules, "\"a // \\\" b\" fn", 0, "\"a // \\\" b\":string fn:keyword", 0);
    try expectSpans(&rules, "'a\\' fn", 0, "'a\\':string fn:keyword", 0);
    // A string that is not closed ends with its line.
    try expectSpans(&rules, "\"open", 0, "\"open:string", 0);
}

test "block comments and multiline strings carry over to the next line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const rules = try testRules(arena.allocator());
    try expectSpans(&rules, "fn /* a", 0, "fn:keyword /* a:comment", 1);
    try expectSpans(&rules, "b */ fn", 1, "b */:comment fn:keyword", 0);
    try expectSpans(&rules, "still", 1, "still:comment", 1);
    try expectSpans(&rules, "x = \"\"\"one", 0, "=:operator \"\"\"one:string", 2);
    try expectSpans(&rules, "two\"\"\" fn", 2, "two\"\"\":string fn:keyword", 0);
}

test "line starts style the whole line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const rules = try testRules(arena.allocator());
    try expectSpans(&rules, "#!/bin/fn", 0, "#!/bin/fn:comment", 0);
    try expectSpans(&rules, " #!/bin/fn", 0, "fn:keyword", 0);
}

fn testDocument(text: []const u8) !Document {
    var doc = Document.init(testing.allocator);
    errdefer doc.deinit();
    try doc.load(text);
    return doc;
}

test "a highlighter reads only down to the line asked for, and again after an edit" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const rules = try testRules(arena.allocator());
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "/* open\n");
    for (0..100_000) |_| try text.appendSlice(testing.allocator, "fn x\n");
    var doc = try testDocument(text.items);
    defer doc.deinit();
    var highlighter: Highlighter = .{ .allocator = testing.allocator, .rules = &rules };
    defer highlighter.deinit();
    var out: std.ArrayList(Span) = .empty;
    defer out.deinit(testing.allocator);

    highlighter.spans(&doc, 40, &out);
    try testing.expectEqual(@as(usize, 41), highlighter.states.items.len);
    try testing.expectEqual(Style.comment, out.items[0].style);

    // Closing the comment changes every line after it.
    doc.cursor.pos = doc.buffer.lineEnd(0);
    try doc.insert(" */");
    highlighter.spans(&doc, 40, &out);
    try testing.expectEqual(Style.keyword, out.items[0].style);

    // Typing far down reads from the edit to the visible lines only.
    highlighter.spans(&doc, 50_040, &out);
    doc.cursor.pos = doc.buffer.lineStart(50_000);
    try doc.insert("fn ");
    try testing.expectEqual(@as(?usize, 50_000), doc.changed_from);
    highlighter.spans(&doc, 50_040, &out);
    try testing.expectEqual(@as(usize, 50_041), highlighter.states.items.len);
}

test "matching brackets skip strings and comments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const rules = try testRules(arena.allocator());
    var doc = try testDocument("f(a, \")\", (b) // )\n) [x]");
    defer doc.deinit();
    var highlighter: Highlighter = .{ .allocator = testing.allocator, .rules = &rules };
    defer highlighter.deinit();

    try testing.expectEqual([2]usize{ 1, 19 }, highlighter.matchBracket(&doc, 1).?);
    // Before the cursor, when nothing is after it.
    try testing.expectEqual([2]usize{ 19, 1 }, highlighter.matchBracket(&doc, 20).?);
    try testing.expectEqual([2]usize{ 12, 10 }, highlighter.matchBracket(&doc, 12).?);
    try testing.expectEqual([2]usize{ 21, 23 }, highlighter.matchBracket(&doc, 21).?);
    // In a string, or not a bracket.
    try testing.expectEqual(@as(?[2]usize, null), highlighter.matchBracket(&doc, 6));
    try testing.expectEqual(@as(?[2]usize, null), highlighter.matchBracket(&doc, 3));
    // Without a grammar, every bracket counts.
    highlighter.setRules(null);
    try testing.expectEqual([2]usize{ 1, 6 }, highlighter.matchBracket(&doc, 1).?);
}
