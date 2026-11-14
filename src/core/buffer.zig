//! Text storage. Stub: decide between gap buffer and piece table.
const std = @import("std");

pub const Buffer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Buffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Buffer) void {
        self.bytes.deinit(self.allocator);
    }

    pub fn insert(self: *Buffer, pos: usize, text: []const u8) !void {
        try self.bytes.insertSlice(self.allocator, pos, text);
    }

    pub fn slice(self: *const Buffer) []const u8 {
        return self.bytes.items;
    }
};

test "insert" {
    var b = Buffer.init(std.testing.allocator);
    defer b.deinit();
    try b.insert(0, "hello");
    try b.insert(5, " world");
    try std.testing.expectEqualStrings("hello world", b.slice());
}
