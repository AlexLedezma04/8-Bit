const std = @import("std");
const app = @import("8-bit");

test "editor holds a buffer and a cursor from core" {
    var ed: app.editor.editor.Editor = .{ .buffer = .init(std.testing.allocator) };
    defer ed.buffer.deinit();

    try ed.buffer.insert(0, "hello");
    try std.testing.expectEqualStrings("hello", ed.buffer.slice());
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.pos);
}
