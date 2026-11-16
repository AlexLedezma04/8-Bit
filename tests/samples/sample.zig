const std = @import("std");

/// Adds two numbers.
pub fn add(a: u32, b: u32) u32 {
    return a + b; // sum
}

const text =
    \\multiline string
;

test "add" {
    try std.testing.expectEqual(@as(u32, 3), add(1, 2));
    const c = 'x';
    _ = c;
    _ = text;
}
