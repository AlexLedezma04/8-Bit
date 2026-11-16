//! Finds the repository of a folder and runs the git CLI. Every git feature
//! goes through `run`. No SDL: `editor/git.zig` calls it on a thread.
const std = @import("std");
const fs = @import("../platform/fs.zig");

/// What git printed, and whether it succeeded. Free with `deinit`.
pub const Output = struct {
    ok: bool,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: Output, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }

    /// The first line git wrote to stderr, else to stdout: what to show.
    pub fn message(self: Output) []const u8 {
        for ([_][]const u8{ self.stderr, self.stdout }) |text| {
            var lines = std.mem.tokenizeAny(u8, text, "\r\n");
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t");
                if (trimmed.len > 0) return trimmed;
            }
        }
        return "";
    }
};

/// More output than this is an error.
const max_output = 64 << 20;

/// Runs `program args` in the folder `cwd`, where `program` is git by name
/// or path. `error.GitNotFound` when there is no such program. Paths in
/// `args` are relative to `cwd`.
pub fn run(allocator: std.mem.Allocator, io: std.Io, program: []const u8, cwd: []const u8, args: []const []const u8) !Output {
    if (!fs.isDir(io, cwd)) return error.FileNotFound;
    const argv = try allocator.alloc([]const u8, args.len + 4);
    defer allocator.free(argv);
    // Names with non-ASCII letters are printed as they are, not quoted.
    // Reading the status does not lock the index, so it never gets in the
    // way of git run by the user at the same time.
    argv[0..4].* = .{ program, "--no-optional-locks", "-c", "core.quotepath=off" };
    @memcpy(argv[4..], args);
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    }) catch |err| return if (err == error.FileNotFound) error.GitNotFound else err;
    return .{ .ok = result.term.success(), .stdout = result.stdout, .stderr = result.stderr };
}

/// The absolute path of the folder at or above `path` that holds `.git`,
/// or null outside a repository.
pub fn findRoot(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    const real = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
    defer allocator.free(real);
    var dir: ?[]const u8 = real;
    while (dir) |current| : (dir = std.fs.path.dirname(current)) {
        const dot_git = try std.fs.path.join(allocator, &.{ current, ".git" });
        defer allocator.free(dot_git);
        if (fs.modTime(io, dot_git) != null) return try allocator.dupe(u8, current);
    }
    return null;
}

const testing = std.testing;

test "message is the first line of stderr, else of stdout" {
    var out: Output = .{ .ok = false, .stdout = @constCast("out\n"), .stderr = @constCast("\n  error: no\nmore\n") };
    try testing.expectEqualStrings("error: no", out.message());
    out.stderr = @constCast("");
    try testing.expectEqualStrings("out", out.message());
}

test "findRoot walks up to .git, run gives the output of git" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    const folder = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(testing.io, "sub/deeper");

    const init = try run(testing.allocator, testing.io, "git", folder, &.{ "init", "-q" });
    defer init.deinit(testing.allocator);
    try testing.expect(init.ok);

    var deeper: [160]u8 = undefined;
    const root = (try findRoot(testing.allocator, testing.io, try std.fmt.bufPrint(&deeper, "{s}/sub/deeper", .{folder}))).?;
    defer testing.allocator.free(root);
    try testing.expect(std.fs.path.isAbsolute(root));
    try testing.expect(std.mem.endsWith(u8, root, &tmp.sub_path));

    const bad = try run(testing.allocator, testing.io, "git", root, &.{ "show", "HEAD:none" });
    defer bad.deinit(testing.allocator);
    try testing.expect(!bad.ok);
    try testing.expect(bad.message().len > 0);
    try testing.expectError(error.FileNotFound, run(testing.allocator, testing.io, "git", "no/such/folder", &.{"status"}));
    try testing.expectError(error.GitNotFound, run(testing.allocator, testing.io, "no-such-git-8bit", root, &.{"status"}));
}
