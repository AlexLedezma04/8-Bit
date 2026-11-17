//! UTF-8 helpers. One character is one codepoint; a bad byte is one character.
const std = @import("std");

pub const replacement: u21 = 0xFFFD;

pub const Char = struct { cp: u21, len: u3 };

/// Decodes the character at the start of `text`, which must not be empty.
pub fn decode(text: []const u8) Char {
    const bad: Char = .{ .cp = replacement, .len = 1 };
    const len = std.unicode.utf8ByteSequenceLength(text[0]) catch return bad;
    if (len > text.len) return bad;
    const cp = std.unicode.utf8Decode(text[0..len]) catch return bad;
    return .{ .cp = cp, .len = len };
}

/// Boundary after the character at `pos`.
pub fn next(text: []const u8, pos: usize) usize {
    return if (pos < text.len) pos + decode(text[pos..]).len else text.len;
}

/// Boundary before the character that ends at `pos`.
pub fn prev(text: []const u8, pos: usize) usize {
    var back: usize = @min(4, pos);
    while (back > 1) : (back -= 1) {
        if (decode(text[pos - back .. pos]).len == back) break;
    }
    return pos - back;
}

/// The first `max_chars` characters of `text`, or all of it if it is shorter.
pub fn prefix(text: []const u8, max_chars: usize) []const u8 {
    var end: usize = 0;
    for (0..max_chars) |_| {
        if (end == text.len) break;
        end = next(text, end);
    }
    return text[0..end];
}

/// Characters in `text`; a bad byte is one character.
pub fn count(text: []const u8) usize {
    var total: usize = 0;
    var pos: usize = 0;
    while (pos < text.len) : (total += 1) pos = next(text, pos);
    return total;
}

/// Non-ASCII characters count as word characters.
pub fn isWord(cp: u21) bool {
    return cp == '_' or cp >= 0x80 or std.ascii.isAlphanumeric(@intCast(cp));
}

const testing = std.testing;

test "decode ASCII, 2-, 3- and 4-byte characters" {
    try testing.expectEqual(Char{ .cp = 'a', .len = 1 }, decode("a"));
    try testing.expectEqual(Char{ .cp = 0xE9, .len = 2 }, decode("é"));
    try testing.expectEqual(Char{ .cp = 0x20AC, .len = 3 }, decode("€"));
    try testing.expectEqual(Char{ .cp = 0x1F600, .len = 4 }, decode("😀"));
}

test "a bad byte is one replacement character" {
    const bad: Char = .{ .cp = replacement, .len = 1 };
    try testing.expectEqual(bad, decode("\xFF"));
    try testing.expectEqual(bad, decode("\xA9"));
    try testing.expectEqual(bad, decode("\xE2\x82"));
    try testing.expectEqual(bad, decode("\xC0\x80"));
}

test "next and prev walk character boundaries" {
    const text = "a\u{E9}\u{20AC}\u{1F600}\xFF\xA9z";
    const bounds = [_]usize{ 0, 1, 3, 6, 10, 11, 12, 13 };
    for (bounds[0 .. bounds.len - 1], bounds[1..]) |a, b| {
        try testing.expectEqual(b, next(text, a));
        try testing.expectEqual(a, prev(text, b));
    }
    try testing.expectEqual(text.len, next(text, text.len));
    try testing.expectEqual(@as(usize, 0), prev(text, 0));
}

test "prefix cuts between characters" {
    try testing.expectEqualStrings("h\u{E9}", prefix("h\u{E9}llo", 2));
    try testing.expectEqualStrings("", prefix("abc", 0));
    try testing.expectEqualStrings("abc", prefix("abc", 9));
}

test "count counts characters, a bad byte as one" {
    try testing.expectEqual(@as(usize, 5), count("h\u{E9}llo"));
    try testing.expectEqual(@as(usize, 2), count("a\xff"));
    try testing.expectEqual(@as(usize, 0), count(""));
}

test "isWord" {
    for ("azAZ09_") |c| try testing.expect(isWord(c));
    for (" .-\n\t(") |c| try testing.expect(!isWord(c));
    try testing.expect(isWord(0xE9));
}
