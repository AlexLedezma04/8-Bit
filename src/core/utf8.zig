//! UTF-8 helpers.
const std = @import("std");

/// Length in bytes of the codepoint starting with `first`, or null if invalid.
pub fn seqLen(first: u8) ?u3 {
    return std.unicode.utf8ByteSequenceLength(first) catch null;
}

test "seqLen" {
    try std.testing.expectEqual(@as(?u3, 1), seqLen('a'));
    try std.testing.expectEqual(@as(?u3, 3), seqLen(0xE2));
    try std.testing.expectEqual(@as(?u3, null), seqLen(0xFF));
}
