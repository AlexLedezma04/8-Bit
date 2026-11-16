//! The git panel of the sidebar, with three pages picked from its tab bar
//! or with Tab. Changes: the staged and the changed files; Enter opens a
//! diff, `s` stages, `u` unstages (on a section title: all of it), Delete
//! discards, `c` writes a commit. History: the commits, a page at a time
//! while you scroll; Enter opens one. Branches: Enter switches, `n` creates.
const std = @import("std");
const editor_zig = @import("../../editor/editor.zig");
const Editor = editor_zig.Editor;
const Page = @import("../../editor/git.zig").Git.Page;
const status = @import("../../git/status.zig");
const Entry = status.Entry;
const layout = @import("../layout.zig");
const Rect = layout.Rect;
const Metrics = layout.Metrics;
const Canvas = @import("../canvas.zig").Canvas;
const panel = @import("../panel.zig");
const Look = panel.Look;
const Handled = panel.Handled;
const list_zig = @import("../widgets/list.zig");
const List = list_zig.List;
const tabs = @import("../widgets/tabs.zig");
const Prompt = @import("../widgets/prompt.zig").Prompt;
const Theme = @import("../theme.zig").Theme;
const event = @import("../../platform/event.zig");
const Event = event.Event;

/// Load the next page of history this many rows before the end.
const history_ahead = 20;

const Section = enum { staged, changes };

/// A row of the changes page: a section title, or a file in it.
const Item = struct { section: Section, entry: ?Entry };

pub const GitPanel = struct {
    editor: *Editor,
    prompt: *Prompt,
    lists: [std.enums.values(Page).len]List = @splat(.{}),
    /// Indexes into the status entries of each section.
    staged: std.ArrayList(u32) = .empty,
    changed: std.ArrayList(u32) = .empty,
    /// The file that Discard asks about.
    discarding: ?Entry = null,
    discard_path: std.ArrayList(u8) = .empty,
    title_buffer: [64]u8 = undefined,

    pub fn deinit(self: *GitPanel) void {
        const allocator = self.editor.allocator;
        self.staged.deinit(allocator);
        self.changed.deinit(allocator);
        self.discard_path.deinit(allocator);
    }

    pub fn title(_: *GitPanel) []const u8 {
        return "Git";
    }

    fn page(self: *const GitPanel) Page {
        return self.editor.git.page;
    }

    fn list(self: *GitPanel) *List {
        return &self.lists[@backingInt(self.page())];
    }

    /// Shows a page and loads what it lists.
    fn open(self: *GitPanel, which: Page) void {
        const git = &self.editor.git;
        git.page = which;
        switch (which) {
            .changes => git.refresh(),
            .history => if (git.history.commits.items.len == 0 and !git.history.loading) git.loadHistory(null),
            .branches => git.loadBranches(),
        }
    }

    /// Splits the status into its two sections.
    fn sync(self: *GitPanel) void {
        const allocator = self.editor.allocator;
        self.staged.clearRetainingCapacity();
        self.changed.clearRetainingCapacity();
        for (self.editor.git.status.entries, 0..) |entry, i| {
            if (entry.isStaged()) self.staged.append(allocator, @intCast(i)) catch {};
            if (entry.isChanged()) self.changed.append(allocator, @intCast(i)) catch {};
        }
    }

    fn count(self: *const GitPanel) usize {
        const git = &self.editor.git;
        return switch (self.page()) {
            .changes => self.staged.items.len + self.changed.items.len + 2,
            .history => git.history.commits.items.len,
            .branches => git.branches.items.len,
        };
    }

    fn itemAt(self: *const GitPanel, index: usize) Item {
        const entries = self.editor.git.status.entries;
        const staged = self.staged.items.len;
        if (index == 0) return .{ .section = .staged, .entry = null };
        if (index <= staged) return .{ .section = .staged, .entry = entries[self.staged.items[index - 1]] };
        if (index == staged + 1) return .{ .section = .changes, .entry = null };
        return .{ .section = .changes, .entry = entries[self.changed.items[index - staged - 2]] };
    }

    /// The tab bar of the pages, and the list below it.
    fn split(rect: Rect, metrics: Metrics) [2]Rect {
        return rect.splitTop(metrics.bar());
    }

    fn pageItems(self: *GitPanel, items: *[3]tabs.Item) []const tabs.Item {
        const history = &self.editor.git.history;
        const history_title = if (history.path) |path|
            std.fmt.bufPrint(&self.title_buffer, "History of {s}", .{std.fs.path.basename(path)}) catch "History"
        else
            "History";
        items.* = .{
            .{ .title = "Changes", .closable = false },
            .{ .title = history_title, .closable = false },
            .{ .title = "Branches", .closable = false },
        };
        return items;
    }

    pub fn handle(self: *GitPanel, ev: Event, metrics: Metrics, rect: Rect) Handled {
        if (!self.editor.git.ready()) return .no;
        self.sync();
        const bar, const area = split(rect, metrics);
        const rows = List.rowsIn(area, metrics);
        const items = self.count();
        const list_ = self.list();
        switch (ev) {
            .key => |press| {
                if (press.key == .tab and !press.mods.ctrl and !press.mods.alt) {
                    const pages: isize = std.enums.values(Page).len;
                    const step: isize = if (press.mods.shift) -1 else 1;
                    self.open(@fromBackingInt(@intCast(@mod(@as(isize, @backingInt(self.page())) + step, pages))));
                    return .yes;
                }
                if (press.mods.ctrl or press.mods.alt) return .no;
                if (self.pageKey(press)) |handled| return handled;
                const action = list_.key(press, items, rows) orelse return .no;
                if (action == .activate) return self.activate(list_.selected);
            },
            .mouse_down => |mouse| {
                var buffer: [3]tabs.Item = undefined;
                if (tabs.hit(bar, metrics, self.pageItems(&buffer), @backingInt(self.page()), mouse.x, mouse.y)) |hit| {
                    self.open(@fromBackingInt(@intCast(hit.index)));
                    return .yes;
                }
                const action = list_.click(mouse.y, area, metrics, items, mouse.clicks) orelse return .yes;
                if (action == .activate) return self.activate(list_.selected);
            },
            .wheel => |wheel| list_.scroll(@intFromFloat(-wheel.dy * 3), items, rows),
            else => return .no,
        }
        if (self.page() == .history and list_.top + rows + history_ahead >= items) self.editor.git.moreHistory();
        return .yes;
    }

    /// The letter keys of each page.
    fn pageKey(self: *GitPanel, press: event.KeyPress) ?Handled {
        const git = &self.editor.git;
        const shift = press.mods.shift;
        switch (self.page()) {
            .changes => {
                const item = self.itemAt(@min(self.list().selected, self.count() - 1));
                switch (press.key) {
                    .char('s') => if (shift or (item.entry == null and item.section == .changes)) git.stageAll() else if (item.entry) |entry| {
                        if (item.section == .changes) git.stage(entry);
                    },
                    .char('u') => if (shift or (item.entry == null and item.section == .staged)) git.unstageAll() else if (item.entry) |entry| {
                        if (item.section == .staged) git.unstage(entry);
                    },
                    .char('c') => self.editor.openCommitMessage("", false),
                    .delete => {
                        const entry = item.entry orelse return .yes;
                        if (item.section != .changes) return .yes;
                        self.discard_path.clearRetainingCapacity();
                        self.discard_path.appendSlice(self.editor.allocator, entry.path) catch return .yes;
                        self.discarding = .{ .path = self.discard_path.items, .index = entry.index, .work = entry.work };
                        return .{ .request = .{ .ask = .{ .question = .discard, .name = std.fs.path.basename(std.mem.trimEnd(u8, entry.path, "/")) } } };
                    },
                    else => return null,
                }
            },
            .branches => switch (press.key) {
                .char('n') => self.prompt.open(.branch, "New branch:", "", &.{}) catch {},
                else => return null,
            },
            .history => return null,
        }
        return .yes;
    }

    /// Enter or a double click on a row.
    fn activate(self: *GitPanel, index: usize) Handled {
        const git = &self.editor.git;
        if (index >= self.count()) return .yes;
        switch (self.page()) {
            .changes => {
                const item = self.itemAt(index);
                const entry = item.entry orelse return .yes;
                git.showDiff(if (item.section == .staged) .{ .staged = entry.path } else .{ .changes = entry.path });
            },
            .history => git.showDiff(.{ .commit = git.history.commits.items[index].hash }),
            .branches => {
                const branch = git.branches.items[index];
                if (!branch.current) git.switchBranch(branch.name);
            },
        }
        return .yes;
    }

    /// The answer to "Discard changes?".
    pub fn confirmDiscard(self: *GitPanel, yes: bool) void {
        const entry = self.discarding orelse return;
        self.discarding = null;
        if (yes) self.editor.git.discard(entry);
    }

    const Rows = struct {
        panel: *const GitPanel,
        theme: *const Theme,
        buffer: [256]u8 = undefined,

        pub fn row(self: *Rows, index: usize) list_zig.Row {
            const git = &self.panel.editor.git;
            const theme = self.theme;
            switch (self.panel.page()) {
                .changes => {
                    const item = self.panel.itemAt(index);
                    const entry = item.entry orelse {
                        const name, const size = if (item.section == .staged) .{ "Staged", self.panel.staged.items.len } else .{ "Changes", self.panel.changed.items.len };
                        return .{ .text = std.fmt.bufPrint(&self.buffer, "{s} ({d})", .{ name, size }) catch name, .color = theme.line_number_current, .icon = 'v' };
                    };
                    const kind = if (item.section == .staged) entry.stagedKind() else entry.changedKind();
                    const color = theme.gitColor(kind);
                    return .{ .text = entry.path, .color = color, .indent = 1, .mark = .{ .char = status.letter(kind), .color = color } };
                },
                .history => {
                    const commit = git.history.commits.items[index];
                    const text = std.fmt.bufPrint(&self.buffer, "{s} {s} {s}", .{ commit.hash, commit.date, commit.subject }) catch commit.subject;
                    return .{ .text = text, .color = theme.text };
                },
                .branches => {
                    const branch = git.branches.items[index];
                    return .{ .text = branch.name, .color = if (branch.current) theme.accent else theme.text, .icon = if (branch.current) '*' else ' ' };
                },
            }
        }
    };

    pub fn draw(self: *GitPanel, canvas: Canvas, look: Look, rect: Rect, focused: bool) void {
        const git = &self.editor.git;
        if (!git.ready()) {
            const text = if (!git.available) "git is not installed" else "No git repository";
            canvas.drawText(rect.x + look.metrics.cell, rect.y + look.metrics.row / 2, text, look.theme.line_number);
            return;
        }
        self.sync();
        const bar, const area = split(rect, look.metrics);
        var buffer: [3]tabs.Item = undefined;
        tabs.draw(canvas, look, bar, self.pageItems(&buffer), @backingInt(self.page()), focused);
        var rows: Rows = .{ .panel = self, .theme = look.theme };
        self.list().draw(canvas, look, area, self.count(), &rows, focused);
        if (self.page() == .history and git.history.loading and self.count() == 0) {
            canvas.drawText(area.x + look.metrics.cell, area.y, "Loading...", look.theme.line_number);
        }
    }
};
