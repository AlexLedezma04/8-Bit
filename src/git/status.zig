//! Reads `git status --porcelain=v1 -z`: the branch, and what changed in the
//! index and the work tree. Also the commands that stage, unstage and
//! discard a whole file.
const std = @import("std");

/// The arguments that print what `parse` reads.
pub const args = [_][]const u8{ "status", "--porcelain=v1", "-z", "--branch", "--ignored" };

pub fn stageArgs(path: []const u8) [3][]const u8 {
    return .{ "add", "--", path };
}

pub fn unstageArgs(path: []const u8) [4][]const u8 {
    return .{ "reset", "-q", "--", path };
}

/// Every change, untracked files too.
pub const stage_all = [_][]const u8{ "add", "-A" };
pub const unstage_all = [_][]const u8{ "reset", "-q" };

/// Throws away the work tree changes of a file. An untracked file is deleted.
pub fn discardArgs(entry: Entry) [4][]const u8 {
    if (entry.index == '?') return .{ "clean", "-fdq", "--", entry.path };
    return .{ "checkout", "-q", "--", entry.path };
}

pub const Kind = enum { modified, added, deleted, renamed, untracked, ignored, conflict };

/// The letter shown next to a file.
pub fn letter(kind: Kind) u8 {
    return switch (kind) {
        .modified => 'M',
        .added => 'A',
        .deleted => 'D',
        .renamed => 'R',
        .untracked => 'U',
        .ignored => 'I',
        .conflict => 'C',
    };
}

/// One column of `git status`.
fn kindOf(column: u8) Kind {
    return switch (column) {
        'A' => .added,
        'D' => .deleted,
        'R', 'C' => .renamed,
        '?' => .untracked,
        '!' => .ignored,
        'U' => .conflict,
        else => .modified,
    };
}

pub const Entry = struct {
    /// Relative to the root of the repository, with `/`. An untracked or
    /// ignored folder is one entry that ends with `/`.
    path: []const u8,
    /// The index column and the work tree column of `git status`.
    index: u8,
    work: u8,

    /// It has changes in the index ("Staged").
    pub fn isStaged(self: Entry) bool {
        return self.index != ' ' and self.index != '?' and self.index != '!';
    }

    /// It has changes in the work tree ("Changes"). Untracked files count.
    pub fn isChanged(self: Entry) bool {
        return self.work != ' ' and self.index != '!';
    }

    pub fn stagedKind(self: Entry) Kind {
        return kindOf(self.index);
    }

    pub fn changedKind(self: Entry) Kind {
        return kindOf(self.work);
    }

    /// What the file tree shows: the work tree change, else the staged one.
    pub fn kind(self: Entry) Kind {
        if (self.index == 'U' or self.work == 'U' or (self.index == self.work and (self.index == 'A' or self.index == 'D'))) return .conflict;
        return kindOf(if (self.work != ' ') self.work else self.index);
    }
};

pub const Status = struct {
    branch: []const u8 = "",
    /// Sorted by path.
    entries: []Entry = &.{},

    /// Reads the output of `args`. The entries point into `bytes`.
    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Status {
        var status: Status = .{};
        var list: std.ArrayList(Entry) = .empty;
        errdefer list.deinit(allocator);
        var records = std.mem.splitScalar(u8, bytes, 0);
        while (records.next()) |record| {
            if (std.mem.startsWith(u8, record, "## ")) {
                status.branch = branchName(record[3..]);
                continue;
            }
            if (record.len < 4) continue;
            try list.append(allocator, .{ .path = record[3..], .index = record[0], .work = record[1] });
            // A rename is followed by the old name.
            if (record[0] == 'R' or record[0] == 'C') _ = records.next();
        }
        std.mem.sort(Entry, list.items, {}, byPath);
        status.entries = try list.toOwnedSlice(allocator);
        return status;
    }

    pub fn deinit(self: Status, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
    }

    fn byPath(_: void, a: Entry, b: Entry) bool {
        return std.mem.lessThan(u8, a.path, b.path);
    }

    fn exact(self: Status, path: []const u8) ?Entry {
        const at = std.sort.lowerBound(Entry, self.entries, path, order);
        if (at < self.entries.len and std.mem.eql(u8, self.entries[at].path, path)) return self.entries[at];
        return null;
    }

    fn order(path: []const u8, entry: Entry) std.math.Order {
        return std.mem.order(u8, path, entry.path);
    }

    /// The entry of a file, or of the untracked or ignored folder it is in.
    pub fn find(self: Status, path: []const u8) ?Entry {
        if (self.exact(path)) |entry| return entry;
        var end: usize = 0;
        while (std.mem.indexOfScalarPos(u8, path, end, '/')) |slash| : (end = slash + 1) {
            if (self.exact(path[0 .. slash + 1])) |entry| return entry;
        }
        return null;
    }

    /// True when something inside `folder` changed. Ignored files do not count.
    pub fn changedInside(self: Status, folder: []const u8) bool {
        var at = std.sort.lowerBound(Entry, self.entries, folder, order);
        while (at < self.entries.len and std.mem.startsWith(u8, self.entries[at].path, folder)) : (at += 1) {
            const entry = self.entries[at];
            if (entry.path.len > folder.len and entry.path[folder.len] == '/' and entry.index != '!') return true;
        }
        return false;
    }
};

/// "main...origin/main [ahead 1]", "No commits yet on main" -> "main".
fn branchName(line: []const u8) []const u8 {
    var name = line;
    for ([_][]const u8{ "No commits yet on ", "Initial commit on " }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) name = name[prefix.len..];
    }
    if (std.mem.indexOf(u8, name, "...")) |end| name = name[0..end];
    if (std.mem.indexOf(u8, name, " [")) |end| name = name[0..end];
    return name;
}

const testing = std.testing;

test "parse reads the branch and every entry, sorted" {
    const out = "## main...origin/main [ahead 1]\x00 M src/b.zig\x00R  new.zig\x00old.zig\x00?? dir/\x00!! zig-out/\x00A  a.txt\x00MM both.txt\x00";
    const status = try Status.parse(testing.allocator, out);
    defer status.deinit(testing.allocator);
    try testing.expectEqualStrings("main", status.branch);
    try testing.expectEqual(@as(usize, 6), status.entries.len);
    try testing.expectEqualStrings("a.txt", status.entries[0].path);
    try testing.expectEqualStrings("new.zig", status.entries[3].path);

    const both = status.find("both.txt").?;
    try testing.expect(both.isStaged() and both.isChanged());
    try testing.expectEqual(Kind.modified, both.kind());
    const added = status.find("a.txt").?;
    try testing.expect(added.isStaged() and !added.isChanged());
    try testing.expectEqual(Kind.added, added.kind());
    try testing.expectEqual(Kind.renamed, status.find("new.zig").?.stagedKind());
    try testing.expectEqual(@as(?Entry, null), status.find("old.zig"));

    // Files inside an untracked or ignored folder.
    const untracked = status.find("dir/x/y.txt").?;
    try testing.expectEqual(Kind.untracked, untracked.kind());
    try testing.expect(!untracked.isStaged() and untracked.isChanged());
    try testing.expectEqual(Kind.ignored, status.find("zig-out/bin/8-bit").?.kind());
    try testing.expect(!status.find("zig-out/").?.isChanged());

    try testing.expect(status.changedInside("src"));
    try testing.expect(status.changedInside("dir"));
    try testing.expect(!status.changedInside("zig-out"));
    try testing.expect(!status.changedInside("sr"));
}

test "branch names" {
    try testing.expectEqualStrings("main", branchName("No commits yet on main"));
    try testing.expectEqualStrings("dev", branchName("dev"));
    try testing.expectEqualStrings("HEAD (no branch)", branchName("HEAD (no branch)"));
    try testing.expectEqualStrings("x", branchName("x [gone]"));
}

test "conflicts, deletes and the discard command" {
    const status = try Status.parse(testing.allocator, "UU c.txt\x00 D d.txt\x00?? n.txt\x00");
    defer status.deinit(testing.allocator);
    try testing.expectEqual(Kind.conflict, status.find("c.txt").?.kind());
    try testing.expectEqual(Kind.deleted, status.find("d.txt").?.kind());
    try testing.expectEqualStrings("checkout", discardArgs(status.find("d.txt").?)[0]);
    try testing.expectEqualStrings("clean", discardArgs(status.find("n.txt").?)[0]);
    try testing.expectEqual('U', letter(status.find("n.txt").?.changedKind()));
}
