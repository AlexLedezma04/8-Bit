//! A line diff in memory (Myers), and a unified diff made from it. The
//! gutter markers and the diff viewer both use it.
const std = @import("std");

/// `old_len` old lines at `old_start` became `new_len` new lines at
/// `new_start`. Zero-based lines.
pub const Hunk = struct { old_start: usize, old_len: usize, new_start: usize, new_len: usize };

/// More edits than this and the middle is one changed hunk, so a diff never
/// takes long or needs much memory.
const max_edits = 1000;

/// The lines of `text` without their line breaks (`\n` or `\r\n`). A text
/// ending in a line break has no empty last line.
pub fn splitLines(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (lines.index == null and line.len == 0) break;
        try list.append(allocator, std.mem.trimEnd(u8, line, "\r"));
    }
    return list.toOwnedSlice(allocator);
}

/// The bytes of `count` lines of `text` from line `first`, with their line breaks.
pub fn lineSpan(text: []const u8, first: usize, count: usize) []const u8 {
    const rest = text[lineOffset(text, first)..];
    return rest[0..lineOffset(rest, count)];
}

fn lineOffset(text: []const u8, line: usize) usize {
    var offset: usize = 0;
    for (0..line) |_| offset = 1 + (std.mem.indexOfScalarPos(u8, text, offset, '\n') orelse return text.len);
    return offset;
}

/// The hunks that turn `old` into `new`, in order.
pub fn diff(allocator: std.mem.Allocator, old: []const []const u8, new: []const []const u8) ![]Hunk {
    var prefix: usize = 0;
    while (prefix < old.len and prefix < new.len and std.mem.eql(u8, old[prefix], new[prefix])) prefix += 1;
    var suffix: usize = 0;
    while (suffix < old.len - prefix and suffix < new.len - prefix and
        std.mem.eql(u8, old[old.len - 1 - suffix], new[new.len - 1 - suffix])) suffix += 1;
    const a = old[prefix .. old.len - suffix];
    const b = new[prefix .. new.len - suffix];

    var hunks: std.ArrayList(Hunk) = .empty;
    errdefer hunks.deinit(allocator);
    if (a.len == 0 and b.len == 0) return hunks.toOwnedSlice(allocator);
    if (a.len == 0 or b.len == 0 or !try myers(allocator, a, b, prefix, &hunks)) {
        hunks.clearRetainingCapacity();
        try hunks.append(allocator, .{ .old_start = prefix, .old_len = a.len, .new_start = prefix, .new_len = b.len });
    }
    return hunks.toOwnedSlice(allocator);
}

/// Myers' shortest edit script. For each number of edits `d` it keeps how
/// far each diagonal got, then walks back from the end. False past `max_edits`.
fn myers(allocator: std.mem.Allocator, a: []const []const u8, b: []const []const u8, offset: usize, hunks: *std.ArrayList(Hunk)) !bool {
    const n: isize = @intCast(a.len);
    const m: isize = @intCast(b.len);
    const limit: usize = @min(a.len + b.len, max_edits);
    // `trace[d]` holds x for the diagonals -d, -d+2 .. d, after d edits.
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var trace: std.ArrayList([]isize) = .empty;
    var last: []isize = &.{};
    const end = search: for (0..limit + 1) |du| {
        const d: isize = @intCast(du);
        const row = try arena.allocator().alloc(isize, du + 1);
        var k = -d;
        while (k <= d) : (k += 2) {
            const down = k == -d or (k != d and at(last, d - 1, k - 1) < at(last, d - 1, k + 1));
            var x = if (d == 0) 0 else if (down) at(last, d - 1, k + 1) else at(last, d - 1, k - 1) + 1;
            var y = x - k;
            while (x < n and y < m and std.mem.eql(u8, a[@intCast(x)], b[@intCast(y)])) {
                x += 1;
                y += 1;
            }
            row[@intCast(@divExact(k + d, 2))] = x;
            if (x >= n and y >= m) break :search du;
        }
        try trace.append(arena.allocator(), row);
        last = row;
    } else return false;

    // Walk back, one edit per step, and note each one.
    const Edit = struct { x: usize, y: usize, insert: bool };
    var edits: std.ArrayList(Edit) = .empty;
    var x = n;
    var y = m;
    var d: isize = @intCast(end);
    while (d > 0) : (d -= 1) {
        const prev = trace.items[@intCast(d - 1)];
        const k = x - y;
        const down = k == -d or (k != d and at(prev, d - 1, k - 1) < at(prev, d - 1, k + 1));
        const prev_k = if (down) k + 1 else k - 1;
        const prev_x = at(prev, d - 1, prev_k);
        const prev_y = prev_x - prev_k;
        try edits.append(arena.allocator(), .{ .x = @intCast(prev_x), .y = @intCast(prev_y), .insert = down });
        x = prev_x;
        y = prev_y;
    }
    std.mem.reverse(Edit, edits.items);

    // Edits that touch each other make one hunk.
    for (edits.items) |edit| {
        if (hunks.items.len > 0) {
            const hunk = &hunks.items[hunks.items.len - 1];
            if (hunk.old_start + hunk.old_len == edit.x + offset and hunk.new_start + hunk.new_len == edit.y + offset) {
                if (edit.insert) hunk.new_len += 1 else hunk.old_len += 1;
                continue;
            }
        }
        try hunks.append(allocator, .{ .old_start = edit.x + offset, .old_len = @intFromBool(!edit.insert), .new_start = edit.y + offset, .new_len = @intFromBool(edit.insert) });
    }
    return true;
}

/// x on diagonal `k` after `d` edits.
fn at(row: []const isize, d: isize, k: isize) isize {
    return row[@intCast(@divExact(k + d, 2))];
}

/// What a line of a unified diff is.
pub const Line = enum { same, added, removed, header };

/// A unified diff without `+`/`-` signs: `text` has the lines, `kinds` says
/// what each one is. Hunks closer than twice `context` lines are joined.
pub const Unified = struct {
    text: std.ArrayList(u8) = .empty,
    kinds: std.ArrayList(Line) = .empty,

    pub const context = 3;

    pub fn deinit(self: *Unified, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.kinds.deinit(allocator);
    }

    /// A line of its own, like a file name.
    pub fn header(self: *Unified, allocator: std.mem.Allocator, comptime format: []const u8, args: anytype) !void {
        try self.text.print(allocator, format ++ "\n", args);
        try self.kinds.append(allocator, .header);
    }

    fn line(self: *Unified, allocator: std.mem.Allocator, text: []const u8, kind: Line) !void {
        try self.text.appendSlice(allocator, text);
        try self.text.append(allocator, '\n');
        try self.kinds.append(allocator, kind);
    }

    /// The changes from `old` to `new`, with a `@@` line before each group.
    pub fn add(self: *Unified, allocator: std.mem.Allocator, old: []const []const u8, new: []const []const u8, hunks: []const Hunk) !void {
        var first: usize = 0;
        while (first < hunks.len) {
            var last = first;
            while (last + 1 < hunks.len and hunks[last + 1].old_start - (hunks[last].old_start + hunks[last].old_len) <= 2 * context) last += 1;
            const start = hunks[first].old_start -| context;
            const new_start = hunks[first].new_start - (hunks[first].old_start - start);
            const end_hunk = hunks[last];
            const end = @min(old.len, end_hunk.old_start + end_hunk.old_len + context);
            const new_end = end_hunk.new_start + end_hunk.new_len + (end - (end_hunk.old_start + end_hunk.old_len));
            try self.header(allocator, "@@ -{d},{d} +{d},{d} @@", .{ start + 1, end - start, new_start + 1, new_end - new_start });
            var o = start;
            for (hunks[first .. last + 1]) |hunk| {
                for (old[o..hunk.old_start]) |text| try self.line(allocator, text, .same);
                for (old[hunk.old_start..][0..hunk.old_len]) |text| try self.line(allocator, text, .removed);
                for (new[hunk.new_start..][0..hunk.new_len]) |text| try self.line(allocator, text, .added);
                o = hunk.old_start + hunk.old_len;
            }
            for (old[o..end]) |text| try self.line(allocator, text, .same);
            first = last + 1;
        }
    }
};

const testing = std.testing;

fn testDiff(old: []const u8, new: []const u8) ![]Hunk {
    const a = try splitLines(testing.allocator, old);
    defer testing.allocator.free(a);
    const b = try splitLines(testing.allocator, new);
    defer testing.allocator.free(b);
    return diff(testing.allocator, a, b);
}

test "splitLines drops line breaks and the empty last line" {
    const lines = try splitLines(testing.allocator, "a\r\nb\n\nc\n");
    defer testing.allocator.free(lines);
    try testing.expectEqual(@as(usize, 4), lines.len);
    try testing.expectEqualStrings("b", lines[1]);
    try testing.expectEqualStrings("", lines[2]);
    try testing.expectEqual(@as(usize, 0), (try splitLines(testing.allocator, "")).len);
}

test "lineSpan keeps line breaks and stops at the end" {
    try testing.expectEqualStrings("b\r\nc\n", lineSpan("a\nb\r\nc\nd", 1, 2));
    try testing.expectEqualStrings("d", lineSpan("a\nb\r\nc\nd", 3, 5));
    try testing.expectEqualStrings("", lineSpan("a\n", 1, 1));
}

test "added, removed and changed lines" {
    const same = try testDiff("a\nb\n", "a\nb\n");
    defer testing.allocator.free(same);
    try testing.expectEqual(@as(usize, 0), same.len);

    const hunks = try testDiff("a\nb\nc\nd\ne\nf\n", "a\nX\nc\nd\nnew\ne\n");
    defer testing.allocator.free(hunks);
    try testing.expectEqualSlices(Hunk, &.{
        .{ .old_start = 1, .old_len = 1, .new_start = 1, .new_len = 1 },
        .{ .old_start = 4, .old_len = 0, .new_start = 4, .new_len = 1 },
        .{ .old_start = 5, .old_len = 1, .new_start = 6, .new_len = 0 },
    }, hunks);

    const empty = try testDiff("", "x\ny\n");
    defer testing.allocator.free(empty);
    try testing.expectEqualSlices(Hunk, &.{.{ .old_start = 0, .old_len = 0, .new_start = 0, .new_len = 2 }}, empty);
}

test "a diff of many edits is one hunk" {
    var old: std.ArrayList(u8) = .empty;
    defer old.deinit(testing.allocator);
    var new: std.ArrayList(u8) = .empty;
    defer new.deinit(testing.allocator);
    for (0..3000) |i| {
        try old.print(testing.allocator, "line {d}\n", .{i});
        try new.print(testing.allocator, "other {d}\nline {d}\n", .{ i, i });
    }
    try old.appendSlice(testing.allocator, "end\n");
    try new.appendSlice(testing.allocator, "end\n");
    const hunks = try testDiff(old.items, new.items);
    defer testing.allocator.free(hunks);
    try testing.expectEqualSlices(Hunk, &.{.{ .old_start = 0, .old_len = 2999, .new_start = 0, .new_len = 5999 }}, hunks);
}

test "unified diff: context, joined hunks and headers" {
    const old = try splitLines(testing.allocator, "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n");
    defer testing.allocator.free(old);
    const new = try splitLines(testing.allocator, "1\nTWO\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n16\n");
    defer testing.allocator.free(new);
    const hunks = try diff(testing.allocator, old, new);
    defer testing.allocator.free(hunks);

    var unified: Unified = .{};
    defer unified.deinit(testing.allocator);
    try unified.add(testing.allocator, old, new, hunks);
    try testing.expectEqualStrings(
        \\@@ -1,5 +1,5 @@
        \\1
        \\2
        \\TWO
        \\3
        \\4
        \\5
        \\@@ -12,5 +12,4 @@
        \\12
        \\13
        \\14
        \\15
        \\16
        \\
    , unified.text.items);
    try testing.expectEqualSlices(Line, &.{ .header, .same, .removed, .added, .same, .same, .same, .header, .same, .same, .same, .removed, .same }, unified.kinds.items);
}
