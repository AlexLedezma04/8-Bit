//! What git knows about one open file: its text at HEAD, the lines changed
//! since then (gutter markers), which can be reverted, and who last changed
//! each line (blame).
//! The line diff runs a short time after the text changes, never per key,
//! and not at all for very big files.
const std = @import("std");
const Document = @import("../core/edit.zig").Document;
const Buffer = @import("../core/buffer.zig").Buffer;
const Decoration = @import("decoration.zig").Decoration;
const diff = @import("../git/diff.zig");
const Blame = @import("../git/log.zig").Blame;

/// Wait this long after a change before the diff runs.
pub const delay_ms = 300;
/// Files with more lines get no markers.
pub const max_lines = 50_000;

/// Something fetched from git, once.
pub fn Fetched(comptime T: type) type {
    return union(enum) {
        /// Not asked for yet.
        unknown,
        asked,
        /// Git has none: the file is new or outside a repository.
        missing,
        ready: T,
    };
}

pub const Tracking = struct {
    /// The text at HEAD.
    head: Fetched([]u8) = .unknown,
    /// The revision of the text the markers were made for.
    revision: ?u64 = null,
    /// The revision `due_ms` was set for: each change sets it again.
    seen: ?u64 = null,
    /// When the markers must be made again.
    due_ms: ?u64 = null,
    /// Gutter markers, sorted by position, and the hunks they mark.
    markers: std.ArrayList(Decoration) = .empty,
    hunks: std.ArrayList(diff.Hunk) = .empty,
    blame: Fetched(Lines) = .unknown,

    /// Blame as gutter texts, and the output they point into.
    pub const Lines = struct {
        blame: Blame,
        output: []u8,
        marks: []Decoration,

        /// The commit that last changed `line`, if it is committed.
        pub fn hashOf(self: Lines, line: usize) ?[]const u8 {
            if (line >= self.blame.lines.len) return null;
            const hash = self.blame.hashes[self.blame.lines[line]];
            return if (Blame.isCommitted(hash)) hash else null;
        }
    };

    pub fn deinit(self: *Tracking, allocator: std.mem.Allocator) void {
        self.forgetHead(allocator);
        self.forgetBlame(allocator);
        self.markers.deinit(allocator);
        self.hunks.deinit(allocator);
    }

    /// HEAD moved: the head text is fetched again.
    pub fn forgetHead(self: *Tracking, allocator: std.mem.Allocator) void {
        if (self.head == .ready) allocator.free(self.head.ready);
        self.head = .unknown;
        self.revision = null;
        self.seen = null;
    }

    /// Forgets everything git said, when the repository is gone.
    pub fn forgetAll(self: *Tracking, allocator: std.mem.Allocator) void {
        self.forgetHead(allocator);
        self.forgetBlame(allocator);
        self.clearChanges();
    }

    fn clearChanges(self: *Tracking) void {
        self.markers.clearRetainingCapacity();
        self.hunks.clearRetainingCapacity();
    }

    pub fn forgetBlame(self: *Tracking, allocator: std.mem.Allocator) void {
        if (self.blame == .ready) {
            const lines = self.blame.ready;
            lines.blame.deinit(allocator);
            allocator.free(lines.output);
            allocator.free(lines.marks);
        }
        self.blame = .unknown;
    }

    /// Takes `text`, or notes there is none.
    pub fn setHead(self: *Tracking, allocator: std.mem.Allocator, text: ?[]u8) void {
        self.forgetHead(allocator);
        self.head = if (text) |owned| .{ .ready = owned } else .missing;
    }

    /// Takes the output of `git blame --porcelain` for `doc`.
    pub fn setBlame(self: *Tracking, allocator: std.mem.Allocator, doc: *const Document, output: []u8) !void {
        self.forgetBlame(allocator);
        errdefer allocator.free(output);
        const blame = try @import("../git/log.zig").parseBlame(allocator, output);
        errdefer blame.deinit(allocator);
        const marks = try allocator.alloc(Decoration, @min(blame.lines.len, doc.buffer.lineCount()));
        for (marks, 0..) |*mark, line| {
            const start = doc.buffer.lineStart(line);
            mark.* = .{ .range = .{ .start = start, .end = start }, .kind = .{ .gutter_text = blame.labels[blame.lines[line]] } };
        }
        self.blame = .{ .ready = .{ .blame = blame, .output = output, .marks = marks } };
    }

    /// Makes the markers again once the text has not changed for a while.
    /// True when they changed.
    pub fn tick(self: *Tracking, allocator: std.mem.Allocator, doc: *const Document, now_ms: u64) bool {
        if (self.head != .ready or self.revision == doc.revision) return false;
        if (self.seen != doc.revision) {
            // The first markers of a file come at once.
            self.due_ms = if (self.revision == null) now_ms else now_ms + delay_ms;
            self.seen = doc.revision;
        }
        if (now_ms < self.due_ms.?) return false;
        self.due_ms = null;
        self.revision = doc.revision;
        self.clearChanges();
        if (doc.buffer.lineCount() > max_lines) return true;
        self.makeMarkers(allocator, doc) catch self.clearChanges();
        return true;
    }

    /// Milliseconds until `tick` has work, if it will.
    pub fn timeLeft(self: *const Tracking, now_ms: u64) ?u64 {
        const due = self.due_ms orelse return null;
        return due -| now_ms;
    }

    fn makeMarkers(self: *Tracking, allocator: std.mem.Allocator, doc: *const Document) !void {
        const text = try allocator.alloc(u8, doc.buffer.len());
        defer allocator.free(text);
        _ = doc.buffer.copy(0, text);
        const old = try diff.splitLines(allocator, self.head.ready);
        defer allocator.free(old);
        const new = try diff.splitLines(allocator, text);
        defer allocator.free(new);
        const hunks = try diff.diff(allocator, old, new);
        defer allocator.free(hunks);
        try self.hunks.appendSlice(allocator, hunks);
        const buffer = &doc.buffer;
        for (hunks) |hunk| {
            const style: @import("decoration.zig").Style = if (hunk.new_len == 0) .removed else if (hunk.old_len == 0) .added else .changed;
            const first, const last = markedLines(hunk, buffer.lineCount());
            try self.markers.append(allocator, .{
                .range = .{ .start = buffer.lineStart(first), .end = buffer.lineStart(last) },
                .kind = .{ .gutter_marker = style },
            });
        }
    }

    /// The change marked on `line`, while the markers are of the text.
    pub fn hunkAt(self: *const Tracking, doc: *const Document, line: usize) ?diff.Hunk {
        if (self.revision != doc.revision) return null;
        for (self.hunks.items) |hunk| {
            const first, const last = markedLines(hunk, doc.buffer.lineCount());
            if (line >= first and line <= last) return hunk;
        }
        return null;
    }

    /// Puts the text at HEAD back over the change marked on `line`, as one
    /// undo step. False when no change is marked there.
    pub fn revert(self: *const Tracking, doc: *Document, line: usize) !bool {
        const hunk = self.hunkAt(doc, line) orelse return false;
        const buffer = &doc.buffer;
        const start = startOf(buffer, hunk.new_start);
        // After a last line without a line break, the old lines need one first.
        const len = buffer.len();
        const join = if (start == len and len > 0 and buffer.byteAt(len - 1) != '\n') "\n" else "";
        const text = try std.mem.concat(buffer.allocator, u8, &.{ join, diff.lineSpan(self.head.ready, hunk.old_start, hunk.old_len) });
        defer buffer.allocator.free(text);
        try doc.replace(.{ .start = start, .end = startOf(buffer, hunk.new_start + hunk.new_len) }, text);
        return true;
    }
};

/// The first and last line a hunk's marker covers. A removal is marked on
/// the line after it.
fn markedLines(hunk: diff.Hunk, line_count: usize) [2]usize {
    const first = @min(hunk.new_start, line_count - 1);
    return .{ first, @max(first, @min(hunk.new_start + hunk.new_len -| 1, line_count - 1)) };
}

/// Where `line` starts, or the end past the last line.
fn startOf(buffer: *const Buffer, line: usize) usize {
    return if (line < buffer.lineCount()) buffer.lineStart(line) else buffer.len();
}

const testing = std.testing;

test "markers come at once, then a while after the text changes" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    try doc.load("one\ntwo\nthree\nfour\n");
    var tracking: Tracking = .{};
    defer tracking.deinit(testing.allocator);
    try testing.expect(!tracking.tick(testing.allocator, &doc, 0));

    tracking.setHead(testing.allocator, try testing.allocator.dupe(u8, "one\n2\nthree\nfour\nfive\n"));
    try testing.expect(tracking.tick(testing.allocator, &doc, 1000));
    try testing.expectEqual(@as(usize, 2), tracking.markers.items.len);
    try testing.expectEqual(Decoration.Kind{ .gutter_marker = .changed }, tracking.markers.items[0].kind);
    try testing.expectEqual(@as(usize, 4), tracking.markers.items[0].range.start);
    // "five" is gone: marked on the last line.
    try testing.expectEqual(Decoration.Kind{ .gutter_marker = .removed }, tracking.markers.items[1].kind);

    doc.cursor.pos = 0;
    try doc.insert("new\n");
    try testing.expect(!tracking.tick(testing.allocator, &doc, 2000));
    try testing.expectEqual(@as(?u64, delay_ms), tracking.timeLeft(2000));
    // Another change waits again.
    doc.cursor = .{ .pos = doc.buffer.len() };
    try doc.insert("x");
    try testing.expect(!tracking.tick(testing.allocator, &doc, 2100));
    try testing.expect(!tracking.tick(testing.allocator, &doc, 2100 + delay_ms - 1));
    try testing.expect(tracking.tick(testing.allocator, &doc, 2100 + delay_ms));
    try testing.expectEqual(Decoration.Kind{ .gutter_marker = .added }, tracking.markers.items[0].kind);
    try testing.expectEqual(@as(?u64, null), tracking.timeLeft(9999));
    try testing.expect(!tracking.tick(testing.allocator, &doc, 9999));

    // HEAD moved: no markers until the new head text comes.
    tracking.forgetHead(testing.allocator);
    try testing.expect(!tracking.tick(testing.allocator, &doc, 10_000));
    tracking.setHead(testing.allocator, null);
    try testing.expectEqual(Fetched([]u8).missing, tracking.head);
}

test "revert puts the text at HEAD back over one change" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    try doc.load("one\nTWO\nthree\nnew\nfour");
    var tracking: Tracking = .{};
    defer tracking.deinit(testing.allocator);
    tracking.setHead(testing.allocator, try testing.allocator.dupe(u8, "one\ntwo\nthree\nfour\nfive\n"));
    _ = tracking.tick(testing.allocator, &doc, 0);
    try testing.expectEqual(@as(?diff.Hunk, null), tracking.hunkAt(&doc, 0));

    try testing.expect(try tracking.revert(&doc, 1));
    try @import("../core/buffer.zig").expectText(&doc.buffer, "one\ntwo\nthree\nnew\nfour");
    // The markers are of the old text until they are made again.
    try testing.expect(!try tracking.revert(&doc, 3));
    _ = tracking.tick(testing.allocator, &doc, 1000);
    _ = tracking.tick(testing.allocator, &doc, 1000 + delay_ms);
    try testing.expect(try tracking.revert(&doc, 3));
    _ = tracking.tick(testing.allocator, &doc, 2000);
    _ = tracking.tick(testing.allocator, &doc, 2000 + delay_ms);
    // "five" is gone after a last line without a line break.
    try testing.expect(try tracking.revert(&doc, 3));
    try @import("../core/buffer.zig").expectText(&doc.buffer, "one\ntwo\nthree\nfour\nfive\n");
    _ = try doc.undo();
    try @import("../core/buffer.zig").expectText(&doc.buffer, "one\ntwo\nthree\nfour");
}

test "very big files get no markers" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendNTimes(testing.allocator, '\n', max_lines + 1);
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    try doc.load(text.items);
    var tracking: Tracking = .{};
    defer tracking.deinit(testing.allocator);
    tracking.setHead(testing.allocator, try testing.allocator.dupe(u8, ""));
    try testing.expect(tracking.tick(testing.allocator, &doc, 0));
    try testing.expectEqual(@as(usize, 0), tracking.markers.items.len);
}

test "blame gives a gutter text per line and the hash of each line" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    try doc.load("one\ntwo\n");
    const hash: [40]u8 = @splat('b');
    const zero: [40]u8 = @splat('0');
    const out = hash ++ " 1 1 1\nauthor Ada\nauthor-time 0\n\tone\n" ++ zero ++ " 2 2 1\nauthor Not Committed Yet\nauthor-time 0\n\ttwo\n";
    var tracking: Tracking = .{};
    defer tracking.deinit(testing.allocator);
    try tracking.setBlame(testing.allocator, &doc, try testing.allocator.dupe(u8, out));
    const lines = tracking.blame.ready;
    try testing.expectEqual(@as(usize, 2), lines.marks.len);
    try testing.expectEqual(@as(usize, 4), lines.marks[1].range.start);
    try testing.expect(std.mem.startsWith(u8, lines.marks[0].kind.gutter_text, "bbbbbbb 1970-01-01 Ada"));
    try testing.expectEqualStrings(&hash, lines.hashOf(0).?);
    try testing.expectEqual(@as(?[]const u8, null), lines.hashOf(1));
    try testing.expectEqual(@as(?[]const u8, null), lines.hashOf(5));
}
