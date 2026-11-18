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

/// Terminal columns a character takes, as wcwidth says: 0 for combining
/// marks and other zero-width ones, 2 for wide (East Asian, emoji), else 1.
pub fn width(cp: u21) u2 {
    if (cp < 0x300) return 1;
    if (inRanges(cp, &zero_width)) return 0;
    return if (inRanges(cp, &wide)) 2 else 1;
}

const Range = struct { u21, u21 };

fn inRanges(cp: u21, ranges: []const Range) bool {
    var low: usize = 0;
    var high = ranges.len;
    while (low < high) {
        const mid = (low + high) / 2;
        if (cp < ranges[mid][0]) high = mid else if (cp > ranges[mid][1]) low = mid + 1 else return true;
    }
    return false;
}

const zero_width = [_]Range{
    .{ 0x300, 0x36F },   .{ 0x483, 0x489 },   .{ 0x591, 0x5BD },   .{ 0x610, 0x61A },
    .{ 0x64B, 0x65F },   .{ 0x200B, 0x200F }, .{ 0x2060, 0x2064 }, .{ 0x20D0, 0x20FF },
    .{ 0xFE00, 0xFE0F }, .{ 0xFE20, 0xFE2F }, .{ 0xFEFF, 0xFEFF }, .{ 0xE0000, 0xE0FFF },
};

const wide = [_]Range{
    .{ 0x1100, 0x115F },   .{ 0x231A, 0x231B },   .{ 0x2329, 0x232A },   .{ 0x23E9, 0x23EC },
    .{ 0x23F0, 0x23F0 },   .{ 0x23F3, 0x23F3 },   .{ 0x25FD, 0x25FE },   .{ 0x2614, 0x2615 },
    .{ 0x2648, 0x2653 },   .{ 0x267F, 0x267F },   .{ 0x2693, 0x2693 },   .{ 0x26A1, 0x26A1 },
    .{ 0x26AA, 0x26AB },   .{ 0x26BD, 0x26BE },   .{ 0x26C4, 0x26C5 },   .{ 0x26CE, 0x26CE },
    .{ 0x26D4, 0x26D4 },   .{ 0x26EA, 0x26EA },   .{ 0x26F2, 0x26F3 },   .{ 0x26F5, 0x26F5 },
    .{ 0x26FA, 0x26FA },   .{ 0x26FD, 0x26FD },   .{ 0x2705, 0x2705 },   .{ 0x270A, 0x270B },
    .{ 0x2728, 0x2728 },   .{ 0x274C, 0x274C },   .{ 0x274E, 0x274E },   .{ 0x2753, 0x2755 },
    .{ 0x2757, 0x2757 },   .{ 0x2795, 0x2797 },   .{ 0x27B0, 0x27B0 },   .{ 0x27BF, 0x27BF },
    .{ 0x2B1B, 0x2B1C },   .{ 0x2B50, 0x2B50 },   .{ 0x2B55, 0x2B55 },   .{ 0x2E80, 0x303E },
    .{ 0x3041, 0x33FF },   .{ 0x3400, 0x4DBF },   .{ 0x4E00, 0x9FFF },   .{ 0xA000, 0xA4CF },
    .{ 0xA960, 0xA97F },   .{ 0xAC00, 0xD7A3 },   .{ 0xF900, 0xFAFF },   .{ 0xFE10, 0xFE19 },
    .{ 0xFE30, 0xFE6F },   .{ 0xFF00, 0xFF60 },   .{ 0xFFE0, 0xFFE6 },   .{ 0x1B000, 0x1B2FF },
    .{ 0x1F004, 0x1F004 }, .{ 0x1F0CF, 0x1F0CF }, .{ 0x1F18E, 0x1F18E }, .{ 0x1F191, 0x1F19A },
    .{ 0x1F200, 0x1F251 }, .{ 0x1F300, 0x1F64F }, .{ 0x1F680, 0x1F6FF }, .{ 0x1F7E0, 0x1F7EB },
    .{ 0x1F90C, 0x1F9FF }, .{ 0x1FA70, 0x1FAFF }, .{ 0x20000, 0x3FFFD },
};

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

test "width: wide, zero-width and the rest" {
    for ([_]u21{ 'a', 0xE9, 0x2500, 0x276F, 0x25CF }) |cp| try testing.expectEqual(@as(u2, 1), width(cp));
    for ([_]u21{ 0x65E5, 0xAC00, 0xFF21, 0x1F600, 0x2705, 0x20000 }) |cp| try testing.expectEqual(@as(u2, 2), width(cp));
    for ([_]u21{ 0x301, 0x200D, 0xFE0F }) |cp| try testing.expectEqual(@as(u2, 0), width(cp));
}
