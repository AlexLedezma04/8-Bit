//! Commit history, branches and blame: the git commands that print them and
//! the parsers that read their output. Parsed text points into the output.
const std = @import("std");
const utf8 = @import("../core/utf8.zig");

/// Commits read at a time.
pub const page = 200;

pub const Commit = struct { hash: []const u8, author: []const u8, date: []const u8, subject: []const u8 };

/// `git log` for `page` commits after the first `skip`, of `path` if set.
pub fn logArgs(arena: std.mem.Allocator, skip: usize, path: ?[]const u8) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(arena, &.{ "log", "--date=short", "--format=%h%x1f%an%x1f%ad%x1f%s%x1e" });
    try args.append(arena, try std.fmt.allocPrint(arena, "--skip={d}", .{skip}));
    try args.append(arena, std.fmt.comptimePrint("-n{d}", .{page}));
    if (path) |file| try args.appendSlice(arena, &.{ "--", file });
    return args.items;
}

/// Reads the output of `logArgs`.
pub fn parseLog(allocator: std.mem.Allocator, bytes: []const u8, out: *std.ArrayList(Commit)) !void {
    var records = std.mem.splitScalar(u8, bytes, 0x1e);
    while (records.next()) |raw| {
        const record = std.mem.trimStart(u8, raw, "\n");
        if (record.len == 0) continue;
        var fields = std.mem.splitScalar(u8, record, 0x1f);
        try out.append(allocator, .{
            .hash = fields.next().?,
            .author = fields.next() orelse "",
            .date = fields.next() orelse "",
            .subject = fields.next() orelse "",
        });
    }
}

/// The full message of the last commit, for amending it.
pub const last_message = [_][]const u8{ "log", "-1", "--format=%B" };

/// True when nothing but `#` lines and spaces is in a message, so
/// `--cleanup=strip` leaves it empty.
pub fn isBlankMessage(message: []const u8) bool {
    var lines = std.mem.splitScalar(u8, message, '\n');
    while (lines.next()) |line| {
        if (line.len > 0 and line[0] == '#') continue;
        if (std.mem.trim(u8, line, " \t\r").len > 0) return false;
    }
    return true;
}

pub fn commitArgs(arena: std.mem.Allocator, message: []const u8, amend: bool) ![]const []const u8 {
    // `--cleanup=strip` drops `#` lines, as git does with its own editor.
    const args: []const []const u8 = &.{ "commit", "-q", "--cleanup=strip", "-m", message, "--amend" };
    return arena.dupe([]const u8, args[0 .. args.len - @intFromBool(!amend)]);
}

/// The files a commit changed, with their status letter.
pub fn changedFilesArgs(hash: []const u8) [7][]const u8 {
    return .{ "diff-tree", "--root", "--no-commit-id", "-r", "--name-status", "-z", hash };
}

pub const Branch = struct { name: []const u8, current: bool };

pub const branches_args = [_][]const u8{ "branch", "--format=%(HEAD)%(refname:short)" };

pub fn switchArgs(name: []const u8) [2][]const u8 {
    return .{ "switch", name };
}

pub fn createArgs(name: []const u8) [3][]const u8 {
    return .{ "switch", "-c", name };
}

/// Reads the output of `branches_args`: `*main`, ` dev`.
pub fn parseBranches(allocator: std.mem.Allocator, bytes: []const u8, out: *std.ArrayList(Branch)) !void {
    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len < 2) continue;
        try out.append(allocator, .{ .name = line[1..], .current = line[0] == '*' });
    }
}

pub fn blameArgs(name: []const u8) [4][]const u8 {
    return .{ "blame", "--porcelain", "--", name };
}

/// Who last changed each line.
pub const Blame = struct {
    /// One per commit: `a1b2c3d 2026-11-16 Author`, padded to one width.
    labels: [][]const u8,
    /// The full hash of each label.
    hashes: [][]const u8,
    /// For each line, its label.
    lines: []u32,

    pub fn deinit(self: Blame, allocator: std.mem.Allocator) void {
        for (self.labels) |label| allocator.free(label);
        allocator.free(self.labels);
        allocator.free(self.hashes);
        allocator.free(self.lines);
    }

    /// Hash of a line that is not committed yet.
    pub fn isCommitted(hash: []const u8) bool {
        return std.mem.trimEnd(u8, hash, "0").len > 0;
    }
};

const author_cols = 12;

/// Reads `git blame --porcelain`. Hashes point into `bytes`.
pub fn parseBlame(allocator: std.mem.Allocator, bytes: []const u8) !Blame {
    var hashes: std.ArrayList([]const u8) = .empty;
    defer hashes.deinit(allocator);
    var labels: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (labels.items) |label| allocator.free(label);
        labels.deinit(allocator);
    }
    var lines: std.ArrayList(u32) = .empty;
    defer lines.deinit(allocator);
    var author: []const u8 = "";
    var current: u32 = 0;

    var rows = std.mem.splitScalar(u8, bytes, '\n');
    while (rows.next()) |row| {
        if (row.len > 0 and row[0] == '\t') {
            try lines.append(allocator, current);
        } else if (std.mem.startsWith(u8, row, "author ")) {
            author = row["author ".len..];
        } else if (std.mem.startsWith(u8, row, "author-time ")) {
            const seconds = std.fmt.parseInt(u64, row["author-time ".len..], 10) catch 0;
            const text = try labelOf(allocator, hashes.items[current], author, seconds);
            allocator.free(labels.items[current]);
            labels.items[current] = text;
        } else if (row.len >= 40 and std.ascii.isHex(row[0]) and std.mem.indexOfScalar(u8, row, ' ') == 40) {
            const hash = row[0..40];
            current = for (hashes.items, 0..) |known, i| {
                if (std.mem.eql(u8, known, hash)) break @intCast(i);
            } else blk: {
                try hashes.append(allocator, hash);
                try labels.append(allocator, try allocator.dupe(u8, ""));
                break :blk @intCast(hashes.items.len - 1);
            };
        }
    }
    const owned_lines = try lines.toOwnedSlice(allocator);
    errdefer allocator.free(owned_lines);
    const owned_hashes = try hashes.toOwnedSlice(allocator);
    return .{ .labels = try labels.toOwnedSlice(allocator), .hashes = owned_hashes, .lines = owned_lines };
}

const label_cols = 7 + 1 + 10 + 1 + author_cols;

/// `a1b2c3d 2026-11-16 Author`, padded to `label_cols` columns.
fn labelOf(allocator: std.mem.Allocator, hash: []const u8, author: []const u8, seconds: u64) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    if (Blame.isCommitted(hash)) {
        const year_day = (std.time.epoch.EpochSeconds{ .secs = seconds }).getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        try text.print(allocator, "{s} {d:0>4}-{d:0>2}-{d:0>2} {s}", .{
            hash[0..7], year_day.year, month_day.month.numeric(), month_day.day_index + 1, utf8.prefix(author, author_cols),
        });
    } else try text.appendSlice(allocator, "Not committed yet");
    const cols = std.unicode.utf8CountCodepoints(text.items) catch text.items.len;
    try text.appendNTimes(allocator, ' ', label_cols -| cols);
    return text.toOwnedSlice(allocator);
}

const testing = std.testing;

test "parse the log and the branches" {
    var commits: std.ArrayList(Commit) = .empty;
    defer commits.deinit(testing.allocator);
    try parseLog(testing.allocator, "a1b2c3d\x1fAda\x1f2026-11-16\x1fFirst\x1e\nb2c3d4e\x1fBob\x1f2026-11-15\x1fSecond: x\x1e\n", &commits);
    try testing.expectEqual(@as(usize, 2), commits.items.len);
    try testing.expectEqualStrings("Second: x", commits.items[1].subject);
    try testing.expectEqualStrings("Ada", commits.items[0].author);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const args = try logArgs(arena.allocator(), 400, "a.zig");
    try testing.expectEqualStrings("--skip=400", args[3]);
    try testing.expectEqualStrings("a.zig", args[args.len - 1]);
    try testing.expectEqual(@as(usize, 6), (try commitArgs(arena.allocator(), "msg", true)).len);
    try testing.expectEqual(@as(usize, 5), (try commitArgs(arena.allocator(), "msg", false)).len);
    try testing.expect(isBlankMessage(" \n# comment\n\t\n"));
    try testing.expect(!isBlankMessage("# comment\nfix: x"));

    var branches: std.ArrayList(Branch) = .empty;
    defer branches.deinit(testing.allocator);
    try parseBranches(testing.allocator, " dev\n*main\n", &branches);
    try testing.expectEqualStrings("main", branches.items[1].name);
    try testing.expect(branches.items[1].current and !branches.items[0].current);
}

test "parse blame: one label per commit, one entry per line" {
    const a: [40]u8 = @splat('a');
    const zero: [40]u8 = @splat('0');
    const out = a ++ " 1 1 2\nauthor Ada Lovelace-Byron\nauthor-time 1763251200\nsummary first\nfilename x.zig\n\tone\n" ++
        a ++ " 2 2\n\ttwo\n" ++
        zero ++ " 3 3 1\nauthor Not Committed Yet\nauthor-time 1763337600\nfilename x.zig\n\tthree\n";
    const blame = try parseBlame(testing.allocator, out);
    defer blame.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 1 }, blame.lines);
    try testing.expectEqualStrings("aaaaaaa 2025-11-16 Ada Lovelace", blame.labels[0]);
    try testing.expectEqual(blame.labels[0].len, blame.labels[1].len);
    try testing.expect(std.mem.startsWith(u8, blame.labels[1], "Not committed yet"));
    try testing.expect(!Blame.isCommitted(blame.hashes[1]));
}
