//! One open file: its document and highlighting, where it is on disk, and
//! when it was last read or written there. A file can also be a read-only
//! view, like a diff, or a commit message.
const std = @import("std");
const Document = @import("../core/edit.zig").Document;
const fs = @import("../platform/fs.zig");
const Highlighter = @import("../syntax/syntax.zig").Highlighter;
const Decoration = @import("decoration.zig").Decoration;
const Tracking = @import("tracking.zig").Tracking;

pub const Role = union(enum) {
    /// Text the user edits and saves.
    text,
    /// A read-only diff.
    diff,
    /// The message of the next commit; true to amend the last one.
    commit: bool,
};

pub const File = struct {
    /// Stays the same while the file is open; background work finds it by this.
    id: u32 = 0,
    role: Role = .text,
    /// The hidden blank file of a pane that has nothing else open.
    placeholder: bool = false,
    /// Opened but not saved yet: the next file opened takes its tab.
    preview: bool = false,
    /// The name of a view or a commit message.
    title: ?[]u8 = null,
    doc: Document,
    /// Null until the file is saved for the first time.
    path: ?[]u8 = null,
    /// Modification time on disk when it was last read or written.
    disk_time: ?i96 = null,
    highlighter: Highlighter,
    /// The language picked by hand, by name; null to detect it.
    language: ?[]u8 = null,
    /// Sorted decorations the file keeps, like the lines of a diff.
    marks: std.ArrayList(Decoration) = .empty,
    tracking: Tracking = .{},

    pub const untitled = "untitled";

    /// A new, empty file that has no path yet.
    pub fn create(allocator: std.mem.Allocator) !*File {
        const file = try allocator.create(File);
        file.* = .{ .doc = .init(allocator), .highlighter = .{ .allocator = allocator } };
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
        if (self.language) |chosen| allocator.free(chosen);
        if (self.title) |title| allocator.free(title);
        self.marks.deinit(allocator);
        self.tracking.deinit(allocator);
        self.highlighter.deinit();
        self.doc.deinit();
        allocator.destroy(self);
    }

    pub fn gpa(self: *const File) std.mem.Allocator {
        return self.doc.buffer.allocator;
    }

    pub fn name(self: *const File) []const u8 {
        if (self.title) |title| return title;
        return if (self.path) |path| std.fs.path.basename(path) else untitled;
    }

    /// Unsaved changes. Views and commit messages are never saved.
    pub fn isModified(self: *const File) bool {
        return self.role == .text and self.doc.history.isModified();
    }

    /// The marks of changed lines: the lines of a diff view, else the git markers.
    pub fn changes(self: *const File) []const Decoration {
        return if (self.role == .diff) self.marks.items else self.tracking.markers.items;
    }

    /// Unsaved, empty and without a path: can be replaced by an opened file.
    pub fn isBlank(self: *const File) bool {
        return self.role == .text and self.path == null and self.doc.buffer.len() == 0 and !self.doc.history.isModified();
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

test "a commit message has a title and is never modified" {
    const file = try File.create(testing.allocator);
    defer file.destroy();
    file.role = .{ .commit = false };
    file.title = try testing.allocator.dupe(u8, "Commit message");
    try file.doc.insert("fix");
    try testing.expect(!file.isModified());
    try testing.expectEqualStrings("Commit message", file.name());
}
