//! Reads and writes whole files. Paths are relative to the working directory
//! or absolute. No SDL here.
const std = @import("std");
const Io = std.Io;

pub fn read(io: Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
}

/// Writes `parts` one after another to a temporary file next to `path`, then
/// renames it over `path`, so a crash never leaves half a file. An existing
/// file keeps its permissions.
pub fn write(io: Io, path: []const u8, parts: []const []const u8) !void {
    const dir = Io.Dir.cwd();
    const permissions: Io.File.Permissions = if (dir.statFile(io, path, .{})) |stat| stat.permissions else |_| .default_file;
    var atomic = try dir.createFileAtomic(io, path, .{ .replace = true, .permissions = permissions });
    defer atomic.deinit(io);
    for (parts) |part| try atomic.file.writeStreamingAll(io, part);
    try atomic.replace(io);
}

const testing = std.testing;

fn tmpPath(tmp: *const testing.TmpDir, buffer: []u8, name: []const u8) ![]u8 {
    return std.fmt.bufPrint(buffer, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

test "write then read gives the same bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    const path = try tmpPath(&tmp, &buffer, "file.txt");

    try write(testing.io, path, &.{ "one\r\n", "", "two" });
    const text = try read(testing.io, testing.allocator, path);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("one\r\ntwo", text);
}

test "write replaces the old file and leaves no temporary file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    const path = try tmpPath(&tmp, &buffer, "file.txt");

    try write(testing.io, path, &.{"a much longer first version"});
    try write(testing.io, path, &.{"short"});
    const text = try read(testing.io, testing.allocator, path);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("short", text);

    var names: usize = 0;
    var entries = tmp.dir.iterate();
    while (try entries.next(testing.io)) |_| names += 1;
    try testing.expectEqual(@as(usize, 1), names);
}

test "reading a missing file fails" {
    try testing.expectError(error.FileNotFound, read(testing.io, testing.allocator, ".zig-cache/tmp/no-such-file"));
}
