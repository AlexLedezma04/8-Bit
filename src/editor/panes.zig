//! The editor area: a tree of splits whose leaves are panes of tabs. A tab
//! is one view of an open file, with its own cursor, scroll and marks.
const std = @import("std");
const Cursor = @import("../core/cursor.zig").Cursor;
const View = @import("view.zig").View;
const Decoration = @import("decoration.zig").Decoration;
const File = @import("file.zig").File;
const Hunk = @import("../git/diff.zig").Hunk;

pub const Tab = struct {
    file: *File,
    /// Kept up to date while another tab is active. The active tab uses the
    /// document's own cursor.
    cursor: Cursor = .{},
    view: View = .{},
    /// Sorted by position. The editor view draws them.
    decorations: std.ArrayList(Decoration) = .empty,
    /// A change shown inline, until the text changes.
    peek: ?struct { line: usize, revision: u64 } = null,

    pub fn create(allocator: std.mem.Allocator, file: *File) !*Tab {
        const tab = try allocator.create(Tab);
        errdefer allocator.destroy(tab);
        tab.* = .{ .file = file };
        try file.doc.follow(&tab.cursor);
        return tab;
    }

    /// The change shown inline, if any.
    pub fn peeked(self: *const Tab) ?Hunk {
        const peek = self.peek orelse return null;
        if (peek.revision != self.file.doc.revision) return null;
        return self.file.tracking.hunkAt(&self.file.doc, peek.line);
    }

    pub fn destroy(self: *Tab, allocator: std.mem.Allocator) void {
        self.file.doc.unfollow(&self.cursor);
        self.decorations.deinit(allocator);
        allocator.destroy(self);
    }
};

pub const Pane = struct {
    tabs: std.ArrayList(*Tab) = .empty,
    active: usize = 0,

    pub fn tab(self: *const Pane) *Tab {
        return self.tabs.items[self.active];
    }

    pub fn find(self: *const Pane, file: *const File) ?usize {
        for (self.tabs.items, 0..) |item, i| if (item.file == file) return i;
        return null;
    }
};

/// Where a split puts its second pane.
pub const Axis = enum { right, down };

pub const Split = struct {
    axis: Axis,
    /// Share of the first child, 0 to 1.
    ratio: f32 = 0.5,
    first: *Node,
    second: *Node,
};

pub const Node = struct {
    parent: ?*Node = null,
    kind: union(enum) { pane: Pane, split: Split },

    pub fn create(allocator: std.mem.Allocator) !*Node {
        const node = try allocator.create(Node);
        node.* = .{ .kind = .{ .pane = .{} } };
        return node;
    }

    /// Frees the tree. Tabs must be destroyed first.
    pub fn destroy(self: *Node, allocator: std.mem.Allocator) void {
        switch (self.kind) {
            .pane => |*leaf| leaf.tabs.deinit(allocator),
            .split => |halves| {
                halves.first.destroy(allocator);
                halves.second.destroy(allocator);
            },
        }
        allocator.destroy(self);
    }

    pub fn pane(self: *Node) *Pane {
        return &self.kind.pane;
    }

    /// Turns this pane into a split of itself and a new empty pane, which it
    /// returns. Pointers to this node now point to the split.
    pub fn split(self: *Node, allocator: std.mem.Allocator, axis: Axis) !*Node {
        const first = try create(allocator);
        errdefer allocator.destroy(first);
        const second = try create(allocator);
        first.* = .{ .parent = self, .kind = self.kind };
        second.parent = self;
        self.kind = .{ .split = .{ .axis = axis, .first = first, .second = second } };
        return second;
    }

    /// Removes this empty pane. Its sibling takes the place of the parent,
    /// which is returned. The root pane cannot be removed.
    pub fn remove(self: *Node, allocator: std.mem.Allocator) *Node {
        const parent = self.parent.?;
        const halves = parent.kind.split;
        const sibling = if (halves.first == self) halves.second else halves.first;
        parent.kind = sibling.kind;
        if (parent.kind == .split) {
            parent.kind.split.first.parent = parent;
            parent.kind.split.second.parent = parent;
        }
        allocator.destroy(sibling);
        self.destroy(allocator);
        return parent;
    }

    /// The panes under this node, in order: left to right, top to bottom.
    pub fn leaves(self: *Node, allocator: std.mem.Allocator, list: *std.ArrayList(*Node)) !void {
        switch (self.kind) {
            .pane => try list.append(allocator, self),
            .split => |halves| {
                try halves.first.leaves(allocator, list);
                try halves.second.leaves(allocator, list);
            },
        }
    }

    pub fn firstLeaf(self: *Node) *Node {
        var node = self;
        while (node.kind == .split) node = node.kind.split.first;
        return node;
    }
};

const testing = std.testing;

fn leafCount(root: *Node) !usize {
    var list: std.ArrayList(*Node) = .empty;
    defer list.deinit(testing.allocator);
    try root.leaves(testing.allocator, &list);
    return list.items.len;
}

test "split and remove keep a valid tree" {
    const root = try Node.create(testing.allocator);
    defer root.destroy(testing.allocator);

    const right = try root.split(testing.allocator, .right);
    const below = try right.split(testing.allocator, .down);
    try testing.expectEqual(@as(usize, 3), try leafCount(root));
    try testing.expectEqual(Axis.right, root.kind.split.axis);
    try testing.expectEqual(root.kind.split.second, below.parent.?);

    // The top-right pane goes; the bottom one takes the right half.
    const left = root.kind.split.first;
    const top_right = root.kind.split.second.kind.split.first;
    const kept = top_right.remove(testing.allocator);
    try testing.expectEqual(root.kind.split.second, kept);
    try testing.expect(kept.kind == .pane);
    try testing.expectEqual(@as(usize, 2), try leafCount(root));

    _ = kept.remove(testing.allocator);
    try testing.expect(root.kind == .pane);
    _ = left;
    try testing.expectEqual(root, root.firstLeaf());
}

test "a tab follows edits made through another tab" {
    const file = try File.create(testing.allocator);
    defer file.destroy();
    try file.doc.load("abc");
    const tab = try Tab.create(testing.allocator, file);
    defer tab.destroy(testing.allocator);
    tab.cursor.pos = 2;
    try file.doc.insert("xy");
    try testing.expectEqual(@as(usize, 4), tab.cursor.pos);

    var pane: Pane = .{};
    defer pane.tabs.deinit(testing.allocator);
    try pane.tabs.append(testing.allocator, tab);
    try testing.expectEqual(@as(?usize, 0), pane.find(file));
    try testing.expectEqual(tab, pane.tab());
}
