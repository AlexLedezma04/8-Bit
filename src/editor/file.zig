//! One open file: its document, where it is on disk, and when it was last
//! read or written there.
const std = @import("std");
const Document = @import("../core/edit.zig").Document;
const fs = @import("../platform/fs.zig");

pub const File = struct {
    doc: Document,
    /// Null until the file is saved for the first time.
    path: ?[]u8 = null,
    /// Modification time on disk when it was last read or written.
    disk_time: ?i96 = null,

    pub const untitled = "untitled";

    /// A new, empty file that has no path yet.
    pub fn create(allocator: std.mem.Allocator) !*File {
        const file = try allocator.create(File);
        file.* = .{ .doc = .init(allocator) };
        return file;
    }

    /// Opens `path`. A file that does not exist yet opens empty and will be
    /// saved there.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !*File {
        const file = try create(allocator);
        errdefer file.destroy();
        file.path = try allocator.dupe(u8, path);
        file.reload(io) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return file;
    }

    pub fn destroy(self: *File) void {
        const allocator = self.gpa();
        if (self.path) |path| allocator.free(path);
        self.doc.deinit();
        allocator.destroy(self);
    }

    pub fn gpa(self: *const File) std.mem.Allocator {
        return self.doc.buffer.allocator;
    }

    pub fn name(self: *const File) []const u8 {
        return if (self.path) |path| std.fs.path.basename(path) else untitled;
    }

    pub fn isModified(self: *const File) bool {
        return self.doc.history.isModified();
    }

    /// Unsaved, empty and without a path: can be replaced by an opened file.
    pub fn isBlank(self: *const File) bool {
        return self.path == null and self.doc.buffer.len() == 0 and !self.isModified();
    }

    pub fn setPath(self: *File, path: []const u8) !void {
        const copy = try self.gpa().dupe(u8, path);
        if (self.path) |old| self.gpa().free(old);
        self.path = copy;
    }

    pub fn save(self: *File, io: std.Io) !void {
        const path = self.path.?;
        try fs.write(io, path, &self.doc.buffer.halves());
        self.doc.history.markSaved();
        self.disk_time = fs.modTime(io, path);
    }

    /// Reads the file again. Cursors stay where they were, or at the end.
    pub fn reload(self: *File, io: std.Io) !void {
        const path = self.path.?;
        const text = try fs.read(io, self.gpa(), path);
        defer self.gpa().free(text);
        const cursor = self.doc.cursor;
        try self.doc.load(text);
        const len = self.doc.buffer.len();
        self.doc.cursor = .{ .pos = @min(cursor.pos, len) };
        for (self.doc.followers.items) |other| other.* = .{ .pos = @min(other.pos, len) };
        self.disk_time = fs.modTime(io, path);
    }

    /// True when the file on disk changed since it was last read or written.
    pub fn changedOnDisk(self: *const File, io: std.Io) bool {
        const path = self.path orelse return false;
        const time = fs.modTime(io, path) orelse return false;
        return self.disk_time != time;
    }
};

const testing = std.testing;

test "open, edit, save, and notice a change on disk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}/a.txt", .{tmp.sub_path});

    const file = try File.open(testing.allocator, testing.io, path);
    defer file.destroy();
    try testing.expect(!file.isBlank());
    try testing.expectEqualStrings("a.txt", file.name());
    try file.doc.insert("hello");
    try testing.expect(file.isModified());
    try file.save(testing.io);
    try testing.expect(!file.isModified());
    try testing.expect(!file.changedOnDisk(testing.io));

    file.doc.cursor = .{ .pos = 4 };
    try fs.write(testing.io, path, &.{"hi"});
    file.disk_time = 0;
    try testing.expect(file.changedOnDisk(testing.io));
    try file.reload(testing.io);
    try testing.expectEqual(@as(usize, 2), file.doc.cursor.pos);
    try testing.expect(!file.changedOnDisk(testing.io));
}

test "a new file is blank and untitled" {
    const file = try File.create(testing.allocator);
    defer file.destroy();
    try testing.expect(file.isBlank());
    try testing.expectEqualStrings("untitled", file.name());
}
