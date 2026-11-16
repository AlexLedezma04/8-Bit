//! Reads and writes whole files, lists, creates, renames and deletes files
//! and folders, finds the config folder.
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

pub const Entry = struct { name: []u8, is_dir: bool };

/// The files and folders in `path`, in no order. A missing folder has none.
/// Free with `freeList`.
pub fn list(io: Io, allocator: std.mem.Allocator, path: []const u8) ![]Entry {
    var found: std.ArrayList(Entry) = .empty;
    errdefer freeList(allocator, found.items);
    errdefer found.deinit(allocator);
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return found.toOwnedSlice(allocator),
        else => return err,
    };
    defer dir.close(io);
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        try found.ensureUnusedCapacity(allocator, 1);
        found.appendAssumeCapacity(.{ .name = try allocator.dupe(u8, entry.name), .is_dir = entry.kind == .directory });
    }
    return found.toOwnedSlice(allocator);
}

pub fn freeList(allocator: std.mem.Allocator, entries: []const Entry) void {
    for (entries) |entry| allocator.free(entry.name);
    allocator.free(entries);
}

/// Modification time, or null when the file cannot be read.
pub fn modTime(io: Io, path: []const u8) ?i96 {
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return stat.mtime.nanoseconds;
}

pub fn isDir(io: Io, path: []const u8) bool {
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .directory;
}

/// A new empty file. Fails if something is already there.
pub fn createFile(io: Io, path: []const u8) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    file.close(io);
}

pub fn createDir(io: Io, path: []const u8) !void {
    try Io.Dir.cwd().createDir(io, path, .default_dir);
}

pub fn rename(io: Io, old: []const u8, new: []const u8) !void {
    if (modTime(io, new) != null) return error.PathAlreadyExists;
    try Io.Dir.rename(.cwd(), old, .cwd(), new, io);
}

/// Deletes a file, or a folder with everything in it.
pub fn delete(io: Io, path: []const u8) !void {
    try Io.Dir.cwd().deleteTree(io, path);
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

test "create, list, rename and delete files and folders" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var a: [128]u8 = undefined;
    var b: [128]u8 = undefined;
    try createDir(testing.io, try tmpPath(&tmp, &a, "sub"));
    try createFile(testing.io, try tmpPath(&tmp, &a, "sub/a.txt"));
    try testing.expectError(error.PathAlreadyExists, createFile(testing.io, try tmpPath(&tmp, &a, "sub/a.txt")));
    try testing.expect(isDir(testing.io, try tmpPath(&tmp, &a, "sub")));
    try testing.expect(!isDir(testing.io, try tmpPath(&tmp, &a, "sub/a.txt")));

    const entries = try list(testing.io, testing.allocator, try tmpPath(&tmp, &a, ""));
    defer freeList(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("sub", entries[0].name);
    try testing.expect(entries[0].is_dir);
    try testing.expectEqual(@as(usize, 0), (try list(testing.io, testing.allocator, try tmpPath(&tmp, &a, "none"))).len);

    try rename(testing.io, try tmpPath(&tmp, &a, "sub/a.txt"), try tmpPath(&tmp, &b, "sub/b.txt"));
    try testing.expect(modTime(testing.io, try tmpPath(&tmp, &a, "sub/b.txt")) != null);
    try createFile(testing.io, try tmpPath(&tmp, &a, "sub/c.txt"));
    try testing.expectError(error.PathAlreadyExists, rename(testing.io, try tmpPath(&tmp, &a, "sub/c.txt"), try tmpPath(&tmp, &b, "sub/b.txt")));
    try delete(testing.io, try tmpPath(&tmp, &a, "sub"));
    try testing.expectEqual(@as(?i96, null), modTime(testing.io, try tmpPath(&tmp, &a, "sub")));
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
