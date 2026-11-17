//! The sidebar panel with the files of the open folder. Folders come first,
//! sorted by name, and are read only when opened. `.git` is hidden. Files
//! and folders can be made, renamed, deleted, copied, cut and pasted from
//! here, with keys or the right-click menu. Each one shows its git status:
//! a color, and a letter for files.
const std = @import("std");
const Editor = @import("../../editor/editor.zig").Editor;
const fs = @import("../../platform/fs.zig");
const layout = @import("../layout.zig");
const Rect = layout.Rect;
const Metrics = layout.Metrics;
const Canvas = @import("../canvas.zig").Canvas;
const panel = @import("../panel.zig");
const Look = panel.Look;
const Handled = panel.Handled;
const list_zig = @import("../widgets/list.zig");
const List = list_zig.List;
const Prompt = @import("../widgets/prompt.zig").Prompt;
const Menu = @import("../widgets/menu.zig").Menu;
const Request = @import("../../editor/editor.zig").Request;
const Theme = @import("../theme.zig").Theme;
const Event = @import("../../platform/event.zig").Event;
const status = @import("../../git/status.zig");

pub const FileTree = struct {
    editor: *Editor,
    prompt: *Prompt,
    menu: *Menu,
    entries: std.ArrayList(Entry) = .empty,
    list: List = .{},
    /// The `folder_version` and `disk_version` of the editor that `entries` show.
    version: ?u32 = null,
    disk_version: u32 = 0,
    /// The folder a new file goes in, or the path being renamed or deleted.
    target: ?[]u8 = null,
    /// What the prompt asks a name for.
    naming: Naming = .new_file,
    /// The entry the menu was opened on; null for the folder itself.
    context: ?usize = null,
    /// What Copy or Cut took, for Paste.
    clip: ?[]u8 = null,
    clip_cut: bool = false,

    const Naming = enum { new_file, new_folder, rename };

    /// The menu items, in order.
    const Action = enum { new_file, new_folder, copy, cut, paste, delete, close_folder };

    const Entry = struct { path: []u8, depth: usize, is_dir: bool, open: bool = false };

    pub fn deinit(self: *FileTree) void {
        self.clear();
        self.entries.deinit(self.editor.allocator);
        self.setTarget(null);
        self.setClip(null, false);
    }

    pub fn title(_: *FileTree) []const u8 {
        return "Files";
    }

    fn clear(self: *FileTree) void {
        for (self.entries.items) |entry| self.editor.allocator.free(entry.path);
        self.entries.clearRetainingCapacity();
    }

    fn setTarget(self: *FileTree, path: ?[]const u8) void {
        self.target = self.replace(self.target, path);
    }

    fn setClip(self: *FileTree, path: ?[]const u8, cut: bool) void {
        self.clip = self.replace(self.clip, path);
        self.clip_cut = cut;
    }

    fn replace(self: *FileTree, old: ?[]u8, new: ?[]const u8) ?[]u8 {
        if (old) |path| self.editor.allocator.free(path);
        return if (new) |path| self.editor.allocator.dupe(u8, path) catch null else null;
    }

    /// Reads the folder again when the editor opened another one.
    pub fn sync(self: *FileTree) void {
        if (self.version != self.editor.folder_version) {
            self.version = self.editor.folder_version;
            self.disk_version = self.editor.disk_version;
            self.list = .{};
            self.reload(&.{});
        } else if (self.disk_version != self.editor.disk_version) {
            self.disk_version = self.editor.disk_version;
            self.refresh();
        }
    }

    /// Reads the folder, opening the folders in `open` again.
    fn reload(self: *FileTree, open: []const []const u8) void {
        self.clear();
        const folder = self.editor.folder orelse return;
        self.insertChildren(folder, 0, 0) catch |err| return self.editor.notify("Could not read {s}: {t}", .{ folder, err });
        var i: usize = 0;
        while (i < self.entries.items.len) : (i += 1) {
            const entry = self.entries.items[i];
            if (!entry.is_dir) continue;
            for (open) |path| if (std.mem.eql(u8, path, entry.path)) {
                self.expand(i);
                break;
            };
        }
    }

    /// Reads the folder again, keeping open folders and the selection.
    pub fn refresh(self: *FileTree) void {
        const allocator = self.editor.allocator;
        var open: std.ArrayList([]const u8) = .empty;
        defer {
            for (open.items) |path| allocator.free(path);
            open.deinit(allocator);
        }
        for (self.entries.items) |entry| if (entry.open) {
            const copy = allocator.dupe(u8, entry.path) catch continue;
            open.append(allocator, copy) catch allocator.free(copy);
        };
        const selected = if (self.selectedEntry()) |entry| allocator.dupe(u8, entry.path) catch null else null;
        defer if (selected) |path| allocator.free(path);
        self.reload(open.items);
        if (selected) |path| self.select(path);
    }

    fn select(self: *FileTree, path: []const u8) void {
        for (self.entries.items, 0..) |entry, i| if (std.mem.eql(u8, entry.path, path)) {
            self.list.selected = i;
        };
    }

    fn insertChildren(self: *FileTree, folder: []const u8, depth: usize, at: usize) !void {
        const allocator = self.editor.allocator;
        const found = try fs.list(self.editor.io, allocator, folder);
        defer fs.freeList(allocator, found);
        std.mem.sort(fs.Entry, found, {}, foldersFirst);
        var index = at;
        for (found) |item| {
            if (isHidden(item.name)) continue;
            const path = try std.fs.path.join(allocator, &.{ folder, item.name });
            errdefer allocator.free(path);
            try self.entries.insert(allocator, index, .{ .path = path, .depth = depth, .is_dir = item.is_dir });
            index += 1;
        }
    }

    fn isHidden(name: []const u8) bool {
        for (fs.hidden) |skip| if (std.mem.eql(u8, name, skip)) return true;
        return false;
    }

    fn foldersFirst(_: void, a: fs.Entry, b: fs.Entry) bool {
        if (a.is_dir != b.is_dir) return a.is_dir;
        return std.ascii.lessThanIgnoreCase(a.name, b.name);
    }

    fn expand(self: *FileTree, index: usize) void {
        const entry = &self.entries.items[index];
        if (!entry.is_dir or entry.open) return;
        entry.open = true;
        const path = entry.path;
        self.insertChildren(path, entry.depth + 1, index + 1) catch |err| self.editor.notify("Could not read {s}: {t}", .{ std.fs.path.basename(path), err });
    }

    fn collapse(self: *FileTree, index: usize) void {
        const entry = &self.entries.items[index];
        if (!entry.open) return;
        entry.open = false;
        const end = self.subtreeEnd(index);
        for (self.entries.items[index + 1 .. end]) |child| self.editor.allocator.free(child.path);
        self.entries.replaceRangeAssumeCapacity(index + 1, end - index - 1, &.{});
        if (self.list.selected > index and self.list.selected < end) self.list.selected = index;
    }

    fn subtreeEnd(self: *const FileTree, index: usize) usize {
        const depth = self.entries.items[index].depth;
        var end = index + 1;
        while (end < self.entries.items.len and self.entries.items[end].depth > depth) end += 1;
        return end;
    }

    fn selectedEntry(self: *const FileTree) ?Entry {
        if (self.list.selected >= self.entries.items.len) return null;
        return self.entries.items[self.list.selected];
    }

    /// Opens a file, or opens or closes a folder.
    fn activate(self: *FileTree, index: usize) void {
        const entry = self.entries.items[index];
        if (!entry.is_dir) return self.editor.open(entry.path);
        if (entry.open) self.collapse(index) else self.expand(index);
    }

    /// The folder an entry is, or is in: a new file goes there.
    fn folderOf(self: *const FileTree, entry: ?Entry) ?[]const u8 {
        const found = entry orelse return self.editor.folder;
        return if (found.is_dir) found.path else std.fs.path.dirname(found.path) orelse self.editor.folder;
    }

    fn ask(self: *FileTree, naming: Naming, entry: ?Entry) void {
        const target = switch (naming) {
            .new_file, .new_folder => self.folderOf(entry),
            .rename => if (entry) |found| found.path else null,
        } orelse return;
        self.setTarget(target);
        self.naming = naming;
        const label = switch (naming) {
            .new_file => "New file:",
            .new_folder => "New folder:",
            .rename => "Rename to:",
        };
        const initial = if (naming == .rename) std.fs.path.basename(target) else "";
        self.prompt.open(switch (naming) {
            .new_file => .new_file,
            .new_folder => .new_folder,
            .rename => .rename,
        }, label, initial, &.{}) catch {};
    }

    /// The name typed in the prompt.
    pub fn submit(self: *FileTree, name: []const u8) void {
        const kind = self.naming;
        const target = self.target orelse return;
        const editor = self.editor;
        if (name.len == 0 or std.mem.indexOfAny(u8, name, "/\\") != null) {
            return editor.notify("Not a file name: {s}", .{name});
        }
        const base = if (kind == .rename) std.fs.path.dirname(target) orelse "." else target;
        const path = std.fs.path.join(editor.allocator, &.{ base, name }) catch return;
        defer editor.allocator.free(path);
        const result = switch (kind) {
            .new_file => fs.createFile(editor.io, path),
            .new_folder => fs.createDir(editor.io, path),
            .rename => fs.rename(editor.io, target, path),
        };
        result catch |err| return editor.notify("Could not {s} {s}: {t}", .{ verb(kind), name, err });
        if (kind == .rename) editor.renamed(target, path);
        self.refresh();
        self.select(path);
        if (kind == .new_file) editor.open(path);
    }

    fn verb(kind: Naming) []const u8 {
        return switch (kind) {
            .new_file => "create",
            .new_folder => "create",
            .rename => "rename",
        };
    }

    /// Pastes what Copy or Cut took into the folder of `entry`. A copy next
    /// to the original gets a free name.
    fn paste(self: *FileTree, entry: ?Entry) void {
        const editor = self.editor;
        const source = self.clip orelse return;
        const folder = self.folderOf(entry) orelse return;
        const name = std.fs.path.basename(source);
        const inside = std.mem.startsWith(u8, folder, source) and (folder.len == source.len or std.fs.path.isSep(folder[source.len]));
        if (inside) return editor.notify("Cannot paste {s} into itself", .{name});
        const target = if (self.clip_cut)
            std.fs.path.join(editor.allocator, &.{ folder, name }) catch return
        else
            fs.freePath(editor.io, editor.allocator, folder, name) catch return;
        defer editor.allocator.free(target);
        if (std.mem.eql(u8, source, target)) return;
        if (self.clip_cut) {
            fs.rename(editor.io, source, target) catch |err| return editor.notify("Could not move {s}: {t}", .{ name, err });
            editor.renamed(source, target);
            self.setClip(null, false);
        } else {
            fs.copy(editor.io, editor.allocator, source, target) catch |err| return editor.notify("Could not copy {s}: {t}", .{ name, err });
        }
        self.refresh();
        self.select(target);
    }

    /// What the right-click menu chose, for the entry it was opened on.
    pub fn choose(self: *FileTree, index: usize) ?Request {
        const entry = if (self.context) |at| if (at < self.entries.items.len) self.entries.items[at] else null else null;
        return self.run(@enumFromInt(index), entry);
    }

    fn run(self: *FileTree, action: Action, entry: ?Entry) ?Request {
        switch (action) {
            .new_file => self.ask(.new_file, entry),
            .new_folder => self.ask(.new_folder, entry),
            .copy, .cut => if (entry) |found| self.setClip(found.path, action == .cut),
            .paste => self.paste(entry),
            .close_folder => return self.editor.closeFolder(),
            .delete => {
                const found = entry orelse return null;
                self.setTarget(found.path);
                return .{ .ask = .{ .question = .delete, .name = std.fs.path.basename(found.path) } };
            },
        }
        return null;
    }

    /// Selects the row under the mouse, or nothing below the last row.
    fn openMenu(self: *FileTree, x: f32, y: f32, rect: Rect, metrics: Metrics) void {
        self.context = self.list.rowAt(y, rect, metrics, self.entries.items.len);
        if (self.context) |at| self.list.selected = at;
        const on_entry = self.context != null;
        self.menu.open(&.{
            .{ .label = "New File", .shortcut = "N" },
            .{ .label = "New Folder", .shortcut = "Shift+N" },
            .{ .label = "Copy", .shortcut = "Ctrl+C", .enabled = on_entry },
            .{ .label = "Cut", .shortcut = "Ctrl+X", .enabled = on_entry },
            .{ .label = "Paste", .shortcut = "Ctrl+V", .enabled = self.clip != null },
            .{ .label = "Delete", .shortcut = "Delete", .enabled = on_entry },
            .{ .label = "Close Folder", .shortcut = "Ctrl+Shift+W" },
        }, x, y, .of(FileTree, self));
    }

    /// The answer to "Delete?".
    pub fn confirmDelete(self: *FileTree, yes: bool) void {
        const target = self.target orelse return;
        if (yes) {
            fs.delete(self.editor.io, target) catch |err| return self.editor.notify("Could not delete {s}: {t}", .{ std.fs.path.basename(target), err });
            self.editor.notify("Deleted {s}", .{std.fs.path.basename(target)});
            self.refresh();
        }
        self.setTarget(null);
    }

    pub fn handle(self: *FileTree, event: Event, metrics: Metrics, rect: Rect) Handled {
        self.sync();
        const count = self.entries.items.len;
        const rows = List.rowsIn(rect, metrics);
        if (self.list.scrollbarEvent(event, rect, metrics, count)) return .yes;
        switch (event) {
            .key => |press| {
                if (press.mods.ctrl and !press.mods.shift and !press.mods.alt) switch (press.key) {
                    .char('c') => return .{ .request = self.run(.copy, self.selectedEntry()) },
                    .char('x') => return .{ .request = self.run(.cut, self.selectedEntry()) },
                    .char('v') => return .{ .request = self.run(.paste, self.selectedEntry()) },
                    else => return .no,
                };
                if (press.mods.ctrl or press.mods.alt) return .no;
                switch (press.key) {
                    .f2 => self.ask(.rename, self.selectedEntry()),
                    .char('n') => _ = self.run(if (press.mods.shift) .new_folder else .new_file, self.selectedEntry()),
                    .delete => return .{ .request = self.run(.delete, self.selectedEntry()) },
                    .right => if (self.selectedEntry() != null) self.expand(self.list.selected),
                    // Closes the folder, or goes to the folder it is in.
                    .left => if (self.selectedEntry()) |entry| {
                        if (entry.open) {
                            self.collapse(self.list.selected);
                        } else {
                            var parent = self.list.selected;
                            while (parent > 0 and self.entries.items[parent].depth >= entry.depth) parent -= 1;
                            self.list.selected = parent;
                        }
                    },
                    else => {
                        const action = self.list.key(press, count, rows) orelse return .no;
                        if (action == .activate and count > 0) {
                            const is_file = !self.entries.items[self.list.selected].is_dir;
                            self.activate(self.list.selected);
                            if (is_file) self.editor.focusArea(.editor);
                        }
                    },
                }
                self.list.reveal(rows);
            },
            .mouse_down => |mouse| switch (mouse.button) {
                .left => if (self.list.click(mouse.y, rect, metrics, count, mouse.clicks)) |_| self.activate(self.list.selected),
                .right => self.openMenu(mouse.x, mouse.y, rect, metrics),
                .middle => {},
            },
            .wheel => |wheel| self.list.scroll(@intFromFloat(-wheel.dy), count, rows),
            else => return .no,
        }
        return .yes;
    }

    /// The rows, for the list widget.
    const Rows = struct {
        tree: *const FileTree,
        theme: *const Theme,
        current: ?[]const u8,

        pub fn row(self: Rows, index: usize) list_zig.Row {
            const entry = self.tree.entries.items[index];
            const is_current = if (self.current) |path| std.mem.eql(u8, path, entry.path) else false;
            const git = &self.tree.editor.git;
            var color = self.theme.text;
            var mark: ?list_zig.Row.Mark = null;
            if (git.statusOf(entry.path, entry.is_dir)) |change| {
                const kind = change.kind();
                color = self.theme.gitColor(kind);
                if (!entry.is_dir and kind != .ignored) mark = .{ .char = status.letter(kind), .color = color };
            } else if (entry.is_dir and git.changedInside(entry.path)) color = self.theme.git_changed;
            return .{
                .text = std.fs.path.basename(entry.path),
                .color = if (is_current) self.theme.accent else color,
                .indent = entry.depth,
                .icon = if (!entry.is_dir) ' ' else if (entry.open) 0x25BC else 0x25B6,
                .mark = mark,
            };
        }
    };

    pub fn draw(self: *FileTree, canvas: Canvas, look: Look, rect: Rect, focused: bool) void {
        self.sync();
        const rows: Rows = .{ .tree = self, .theme = look.theme, .current = self.editor.file().path };
        self.list.draw(canvas, look, rect, self.entries.items.len, rows, focused);
    }
};
