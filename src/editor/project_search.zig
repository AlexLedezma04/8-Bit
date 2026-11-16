//! Find in project: a thread walks the open folder, matches each text file
//! with `core/search.zig`, and posts the hits of each file to the main loop.
const std = @import("std");
const search = @import("../core/search.zig");
const utf8 = @import("../core/utf8.zig");
const fs = @import("../platform/fs.zig");
const editor_zig = @import("editor.zig");
const Mailbox = editor_zig.Mailbox;

/// Bigger files are skipped.
const max_file_size = 4 << 20;
/// A file with a 0 byte this near its start is binary.
const binary_probe = 8000;
/// The search stops after this many hits.
pub const max_hits = 10_000;
/// Characters of a line shown in a result.
const max_text = 200;

/// One match. `path` belongs to the file's `Found`.
pub const Hit = struct {
    path: []const u8,
    /// Zero-based, in bytes.
    line: usize,
    column: usize,
    len: usize,
    /// `file:line: text`, for the results list.
    text: []u8,
};

/// The hits of one file, posted to the main loop.
pub const Found = struct { id: u32, path: []u8, hits: []Hit };

/// The thread is done. `stopped` when it was stopped or hit `max_hits`.
pub const Done = struct { id: u32, stopped: bool };

pub fn freeFound(allocator: std.mem.Allocator, found: Found) void {
    for (found.hits) |hit| allocator.free(hit.text);
    allocator.free(found.hits);
    allocator.free(found.path);
}

/// What the thread works on. It reads everything but `cancel` and `hits`.
const Job = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mailbox: *Mailbox,
    id: u32,
    folder: []const u8,
    query: search.Query,
    exclude: []const []const u8,
    arena: std.heap.ArenaAllocator,
    cancel: std.atomic.Value(bool) = .init(false),
    hits: usize = 0,
    thread: std.Thread = undefined,

    fn run(self: *Job) void {
        self.walk(self.folder);
        const stopped = self.cancel.load(.monotonic) or self.hits >= max_hits;
        self.mailbox.post(.{ .search_done = .{ .id = self.id, .stopped = stopped } }) catch {};
    }

    fn skipped(self: *const Job, name: []const u8) bool {
        for (fs.hidden) |skip| if (std.mem.eql(u8, name, skip)) return true;
        for (self.exclude) |skip| if (std.mem.eql(u8, name, skip)) return true;
        return false;
    }

    fn stopping(self: *const Job) bool {
        return self.cancel.load(.monotonic) or self.hits >= max_hits;
    }

    fn walk(self: *Job, folder: []const u8) void {
        const entries = fs.list(self.io, self.allocator, folder) catch return;
        defer fs.freeList(self.allocator, entries);
        std.mem.sort(fs.Entry, entries, {}, byName);
        for (entries) |entry| {
            if (self.stopping()) return;
            if (self.skipped(entry.name)) continue;
            const path = std.fs.path.join(self.allocator, &.{ folder, entry.name }) catch return;
            if (entry.is_dir) {
                defer self.allocator.free(path);
                self.walk(path);
            } else {
                self.searchFile(path);
            }
        }
    }

    fn byName(_: void, a: fs.Entry, b: fs.Entry) bool {
        return std.mem.lessThan(u8, a.name, b.name);
    }

    /// Takes `path`, and posts it with its hits, if it has any.
    fn searchFile(self: *Job, path: []u8) void {
        const hits = self.hitsIn(path) catch return self.allocator.free(path);
        const found: Found = .{ .id = self.id, .path = path, .hits = hits };
        if (hits.len == 0) return freeFound(self.allocator, found);
        self.mailbox.post(.{ .found = found }) catch freeFound(self.allocator, found);
    }

    fn hitsIn(self: *Job, path: []const u8) ![]Hit {
        const allocator = self.allocator;
        const bytes = try fs.readAtMost(self.io, allocator, path, max_file_size);
        defer allocator.free(bytes);
        var hits: std.ArrayList(Hit) = .empty;
        if (std.mem.findScalar(u8, bytes[0..@min(bytes.len, binary_probe)], 0) != null) return hits.toOwnedSlice(allocator);

        errdefer {
            for (hits.items) |hit| allocator.free(hit.text);
            hits.deinit(allocator);
        }
        const name = if (std.mem.startsWith(u8, path, self.folder)) path[@min(path.len, self.folder.len + 1)..] else path;
        const len = self.query.needle.len;
        var line: usize = 0;
        var counted: usize = 0;
        var from: usize = 0;
        while (self.query.next(.{ bytes, "" }, from)) |start| : (from = start + len) {
            if (self.stopping()) break;
            line += std.mem.countScalar(u8, bytes[counted..start], '\n');
            counted = start;
            const line_start = if (std.mem.findScalarLast(u8, bytes[0..start], '\n')) |at| at + 1 else 0;
            const line_end = std.mem.findScalarPos(u8, bytes, start, '\n') orelse bytes.len;
            const content = std.mem.trim(u8, bytes[line_start..line_end], " \t\r");
            const text = try std.fmt.allocPrint(allocator, "{s}:{d}: {s}", .{ name, line + 1, utf8.prefix(content, max_text) });
            errdefer allocator.free(text);
            try hits.append(allocator, .{ .path = path, .line = line, .column = start - line_start, .len = len, .text = text });
            self.hits += 1;
        }
        return hits.toOwnedSlice(allocator);
    }
};

/// The search the main thread sees: its hits so far and whether it runs.
pub const ProjectSearch = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    job: ?*Job = null,
    /// Goes up with every search, so late hits of an old one are dropped.
    id: u32 = 0,
    needle: std.ArrayList(u8) = .empty,
    paths: std.ArrayList([]u8) = .empty,
    hits: std.ArrayList(Hit) = .empty,
    running: bool = false,
    stopped: bool = false,

    pub fn deinit(self: *ProjectSearch) void {
        self.finish();
        self.clear();
        self.needle.deinit(self.allocator);
        self.paths.deinit(self.allocator);
        self.hits.deinit(self.allocator);
    }

    fn clear(self: *ProjectSearch) void {
        for (self.hits.items) |hit| self.allocator.free(hit.text);
        for (self.paths.items) |path| self.allocator.free(path);
        self.hits.clearRetainingCapacity();
        self.paths.clearRetainingCapacity();
    }

    /// Stops the thread, waits for it and frees its job.
    fn finish(self: *ProjectSearch) void {
        const job = self.job orelse return;
        job.cancel.store(true, .monotonic);
        job.thread.join();
        job.arena.deinit();
        self.allocator.destroy(job);
        self.job = null;
        self.running = false;
    }

    /// Searches `folder` on a new thread, after stopping the last search.
    pub fn start(self: *ProjectSearch, mailbox: *Mailbox, folder: []const u8, query: search.Query, exclude: []const []const u8) !void {
        self.finish();
        self.clear();
        self.id +%= 1;
        self.stopped = false;
        self.needle.clearRetainingCapacity();
        try self.needle.appendSlice(self.allocator, query.needle);

        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        job.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .mailbox = mailbox,
            .id = self.id,
            .folder = undefined,
            .query = query,
            .exclude = undefined,
            .arena = .init(self.allocator),
        };
        errdefer job.arena.deinit();
        // The thread gets its own copies: the settings can be reloaded meanwhile.
        const arena = job.arena.allocator();
        job.folder = try arena.dupe(u8, folder);
        job.query.needle = try arena.dupe(u8, query.needle);
        const names = try arena.alloc([]const u8, exclude.len);
        for (names, exclude) |*copy, name| copy.* = try arena.dupe(u8, name);
        job.exclude = names;
        job.thread = try std.Thread.spawn(.{}, Job.run, .{job});
        self.job = job;
        self.running = true;
    }

    /// Asks the thread to stop. `Done` still comes.
    pub fn stop(self: *ProjectSearch) void {
        if (self.job) |job| job.cancel.store(true, .monotonic);
    }

    /// Takes the hits of a file. Frees those of an old search.
    pub fn receive(self: *ProjectSearch, found: Found) void {
        if (found.id != self.id or self.paths.ensureUnusedCapacity(self.allocator, 1) == error.OutOfMemory or
            self.hits.ensureUnusedCapacity(self.allocator, found.hits.len) == error.OutOfMemory)
        {
            return freeFound(self.allocator, found);
        }
        self.paths.appendAssumeCapacity(found.path);
        self.hits.appendSliceAssumeCapacity(found.hits);
        self.allocator.free(found.hits);
    }

    pub fn done(self: *ProjectSearch, finished: Done) void {
        if (finished.id != self.id) return;
        // Stopped here is stopped, even if the thread was already done.
        self.stopped = finished.stopped or self.job.?.cancel.load(.monotonic);
        self.finish();
    }

    /// One line about the search, for the top of the results.
    pub fn summary(self: *const ProjectSearch, buffer: []u8) []const u8 {
        if (self.id == 0) return "Ctrl+Shift+F searches the open folder";
        const state = if (self.running) "Searching " else if (self.stopped) "Stopped: " else "";
        const hits = self.hits.items.len;
        const files = self.paths.items.len;
        return std.fmt.bufPrint(buffer, "{s}\"{s}\": {d} result{s} in {d} file{s}", .{
            state, utf8.prefix(self.needle.items, 60), hits, plural(hits), files, plural(files),
        }) catch buffer;
    }

    fn plural(count: usize) []const u8 {
        return if (count == 1) "" else "s";
    }
};

const testing = std.testing;

fn noWake() void {}

/// Takes what the thread posts until it is done.
pub fn waitForTest(project: *ProjectSearch, mailbox: *Mailbox) void {
    while (project.running) {
        const posted = mailbox.take() orelse {
            std.Thread.yield() catch {};
            continue;
        };
        switch (posted) {
            .found => |found| project.receive(found),
            .search_done => |finished| project.done(finished),
            else => unreachable,
        }
    }
}

test "searches the folder on a thread, skips what it should" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    const folder = try std.fmt.bufPrint(&buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const files = [_][2][]const u8{
        .{ "a.txt", "x\n  one Two\none\n" }, .{ "sub/b.txt", "TWO" },  .{ "bin.dat", "two\x00" },
        .{ "out/c.txt", "two" },             .{ ".git/d.txt", "two" },
    };
    for (files) |file| {
        var path: [192]u8 = undefined;
        try fs.write(testing.io, try std.fmt.bufPrint(&path, "{s}/{s}", .{ folder, file[0] }), &.{file[1]});
    }

    var mailbox: Mailbox = .{ .allocator = testing.allocator, .io = testing.io, .wake = noWake };
    defer mailbox.deinit();
    var project: ProjectSearch = .{ .allocator = testing.allocator, .io = testing.io };
    defer project.deinit();
    try project.start(&mailbox, folder, .{ .needle = "two" }, &.{"out"});
    waitForTest(&project, &mailbox);
    try testing.expectEqual(@as(usize, 2), project.hits.items.len);
    try testing.expectEqualStrings("a.txt:2: one Two", project.hits.items[0].text);
    try testing.expectEqual(@as(usize, 1), project.hits.items[0].line);
    try testing.expectEqual(@as(usize, 6), project.hits.items[0].column);
    try testing.expectEqualStrings("sub/b.txt:1: TWO", project.hits.items[1].text);
    var line: [128]u8 = undefined;
    try testing.expectEqualStrings("\"two\": 2 results in 2 files", project.summary(&line));

    // A new search drops the hits of the old one.
    try project.start(&mailbox, folder, .{ .needle = "one", .options = .{ .whole_word = true } }, &.{});
    waitForTest(&project, &mailbox);
    try testing.expectEqual(@as(usize, 2), project.hits.items.len);
    try testing.expectEqual(@as(usize, 1), project.paths.items.len);
}
