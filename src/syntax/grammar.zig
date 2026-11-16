//! A language as data: the shape of a grammar file in assets/grammars, and
//! the compact rule set made from it, with a sorted word list for fast
//! keyword lookup. See docs/GRAMMARS.md.
const std = @import("std");

/// What a piece of text is. The theme gives each one a color.
pub const Style = enum(u8) { text, comment, keyword, type, constant, builtin, string, number, function, operator, punctuation };

/// A grammar file, as written. Every field but `name` can be left out.
pub const Grammar = struct {
    name: []const u8,
    /// Without the dot: `.{ "c", "h" }`.
    extensions: []const []const u8 = &.{},
    /// Whole file names, like `Makefile`. Case is ignored.
    file_names: []const []const u8 = &.{},
    /// Programs named after `#!` on the first line, like `python`.
    shebangs: []const []const u8 = &.{},
    /// When grammars share an extension, text near the start of a file that
    /// picks this one, like `@interface` for Objective-C `.m` files. The one
    /// without hints is picked when no hint is found.
    hints: []const []const u8 = &.{},
    line_comments: []const []const u8 = &.{},
    block_comment: ?Pair = null,
    /// Tried in order, so put `"""` before `"`.
    strings: []const Quote = &.{},
    keywords: []const []const u8 = &.{},
    types: []const []const u8 = &.{},
    constants: []const []const u8 = &.{},
    builtins: []const []const u8 = &.{},
    /// Words match in any case, like SQL `select`.
    ignore_case: bool = false,
    /// Digits start a number: `42`, `0xff`, `1.5e3`, `10px`.
    numbers: bool = true,
    /// A word right before `(` is a function call.
    functions: bool = true,
    /// A word followed by one of these characters is a key, like `name:`
    /// in YAML. Keys get the type color.
    key_before: []const u8 = "",
    /// Characters that are operators, like `+-*/=<>!&|`.
    operators: []const u8 = "",
    punctuation: []const u8 = "()[]{},;",
    /// Characters that can be part of a word besides letters, digits and `_`.
    word_chars: []const u8 = "",
    /// A word that starts with this text, like `@import` or `$HOME`.
    prefixes: []const Mark = &.{},
    /// A line that starts with this text, like `+` in a diff.
    line_starts: []const Mark = &.{},
};

pub const Pair = struct { start: []const u8, end: []const u8 };

pub const Quote = struct {
    start: []const u8,
    /// Empty means the same as `start`.
    end: []const u8 = "",
    /// A backslash makes the next character part of the string.
    escape: bool = true,
    /// Can go on over line breaks.
    multiline: bool = false,
    style: Style = .string,

    pub fn closer(self: Quote) []const u8 {
        return if (self.end.len > 0) self.end else self.start;
    }
};

pub const Mark = struct { text: []const u8, style: Style };

const Word = struct { text: []const u8, style: Style };

/// A grammar ready for the highlighter.
pub const Rules = struct {
    grammar: Grammar,
    /// Every keyword group, sorted. Lower case with `ignore_case`.
    words: []const Word,

    pub fn init(arena: std.mem.Allocator, grammar: Grammar) !Rules {
        const groups = [_]struct { []const []const u8, Style }{
            .{ grammar.keywords, .keyword },
            .{ grammar.types, .type },
            .{ grammar.constants, .constant },
            .{ grammar.builtins, .builtin },
        };
        var words: std.ArrayList(Word) = .empty;
        for (groups) |group| for (group[0]) |text| {
            const stored = if (grammar.ignore_case) try std.ascii.allocLowerString(arena, text) else text;
            try words.append(arena, .{ .text = stored, .style = group[1] });
        };
        std.mem.sort(Word, words.items, {}, wordLess);
        return .{ .grammar = grammar, .words = words.items };
    }

    fn wordLess(_: void, a: Word, b: Word) bool {
        return std.mem.lessThan(u8, a.text, b.text);
    }

    fn wordOrder(key: []const u8, word: Word) std.math.Order {
        return std.mem.order(u8, key, word.text);
    }

    /// The style of a keyword, or null for any other word.
    pub fn lookup(self: *const Rules, word: []const u8) ?Style {
        var lower: [64]u8 = undefined;
        const key = if (!self.grammar.ignore_case) word else if (word.len > lower.len) return null else std.ascii.lowerString(&lower, word);
        const at = std.sort.binarySearch(Word, self.words, key, wordOrder) orelse return null;
        return self.words[at].style;
    }

    pub fn isWordChar(self: *const Rules, byte: u8) bool {
        return std.ascii.isAlphanumeric(byte) or byte == '_' or byte >= 0x80 or
            std.mem.findScalar(u8, self.grammar.word_chars, byte) != null;
    }

    /// The first line comment marker, else the block comment, for toggling.
    pub fn commentMarkers(self: *const Rules) ?Pair {
        const grammar = &self.grammar;
        if (grammar.line_comments.len > 0) return .{ .start = grammar.line_comments[0], .end = "" };
        return grammar.block_comment;
    }
};

const testing = std.testing;

test "keyword lookup by group, and in any case when asked" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const rules = try Rules.init(arena.allocator(), .{
        .name = "Test",
        .keywords = &.{ "if", "else" },
        .types = &.{"int"},
        .constants = &.{"true"},
        .builtins = &.{"print"},
    });
    try testing.expectEqual(@as(?Style, .keyword), rules.lookup("else"));
    try testing.expectEqual(@as(?Style, .type), rules.lookup("int"));
    try testing.expectEqual(@as(?Style, .constant), rules.lookup("true"));
    try testing.expectEqual(@as(?Style, .builtin), rules.lookup("print"));
    try testing.expectEqual(@as(?Style, null), rules.lookup("ELSE"));
    try testing.expectEqual(@as(?Style, null), rules.lookup("x"));

    const sql = try Rules.init(arena.allocator(), .{ .name = "SQL", .keywords = &.{"SELECT"}, .ignore_case = true });
    try testing.expectEqual(@as(?Style, .keyword), sql.lookup("select"));
    try testing.expectEqual(@as(?Style, .keyword), sql.lookup("SeLeCt"));
    try testing.expectEqual(@as(?Pair, null), sql.commentMarkers());
}

test "comment markers: the line comment first" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c = try Rules.init(arena.allocator(), .{ .name = "C", .line_comments = &.{"//"}, .block_comment = .{ .start = "/*", .end = "*/" } });
    try testing.expectEqualStrings("//", c.commentMarkers().?.start);
    const css = try Rules.init(arena.allocator(), .{ .name = "CSS", .block_comment = .{ .start = "/*", .end = "*/" } });
    try testing.expectEqualStrings("*/", css.commentMarkers().?.end);
}
