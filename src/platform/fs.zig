//! Reads and writes whole files, lists folders, finds the config folder.
//! Paths are relative to the working directory or absolute. No SDL here.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// The bytes end with a 0 that is not part of the file.
pub fn read(io: Io, allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return Io.Dir.cwd().readFileAllocOptions(io, path, allocator, .unlimited, .of(u8), 0);
}

/// Writes `parts` one after another to a temporary file next to `path`, then
/// renames it over `path`, so a crash never leaves half a file. An existing
/// file keeps its permissions. Missing folders are created.
pub fn write(io: Io, path: []const u8, parts: []const []const u8) !void {
    const dir = Io.Dir.cwd();
    const permissions: Io.File.Permissions = if (dir.statFile(io, path, .{})) |stat| stat.permissions else |_| .default_file;
    var atomic = try dir.createFileAtomic(io, path, .{ .replace = true, .permissions = permissions, .make_path = true });
    defer atomic.deinit(io);
    for (parts) |part| try atomic.file.writeStreamingAll(io, part);
    try atomic.replace(io);
}

/// Names of the files in `path` that end with `suffix`, without it. A missing
/// folder has none.
pub fn list(io: Io, allocator: std.mem.Allocator, path: []const u8, suffix: []const u8) ![][]u8 {
    var names: std.ArrayList([]u8) = .empty;
    errdefer names.deinit(allocator);
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return names.toOwnedSlice(allocator),
        else => return err,
    };
    defer dir.close(io);
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, suffix)) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name[0 .. entry.name.len - suffix.len]));
    }
    return names.toOwnedSlice(allocator);
}

/// The folder for user settings: `%APPDATA%\8-bit` on Windows,
/// `$XDG_CONFIG_HOME/8-bit` or `~/.config/8-bit` elsewhere.
pub fn configDir(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ?[]u8 {
    const base, const sub: []const u8 = if (builtin.os.tag == .windows)
        .{ env.get("APPDATA") orelse return null, "" }
    else if (env.get("XDG_CONFIG_HOME")) |xdg|
        .{ xdg, "" }
    else
        .{ env.get("HOME") orelse return null, ".config" };
    return std.fs.path.join(allocator, &.{ base, sub, "8-bit" }) catch null;
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

test "list finds the files with a suffix" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    try write(testing.io, try tmpPath(&tmp, &buffer, "sub/a.zon"), &.{""});
    try write(testing.io, try tmpPath(&tmp, &buffer, "sub/b.txt"), &.{""});

    const names = try list(testing.io, testing.allocator, try tmpPath(&tmp, &buffer, "sub"), ".zon");
    defer {
        for (names) |name| testing.allocator.free(name);
        testing.allocator.free(names);
    }
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("a", names[0]);
    try testing.expectEqual(@as(usize, 0), (try list(testing.io, testing.allocator, try tmpPath(&tmp, &buffer, "none"), ".zon")).len);
}

test "the config folder comes from the environment" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try testing.expectEqual(@as(?[]u8, null), configDir(testing.allocator, &env));

    try env.put("HOME", "/home/me");
    const home = configDir(testing.allocator, &env).?;
    defer testing.allocator.free(home);
    try testing.expectEqualStrings("/home/me/.config/8-bit", home);

    try env.put("XDG_CONFIG_HOME", "/xdg");
    const xdg = configDir(testing.allocator, &env).?;
    defer testing.allocator.free(xdg);
    try testing.expectEqualStrings("/xdg/8-bit", xdg);
}

test "reading a missing file fails" {
    try testing.expectError(error.FileNotFound, read(testing.io, testing.allocator, ".zig-cache/tmp/no-such-file"));
}
