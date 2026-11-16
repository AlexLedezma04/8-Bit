//! The sidebar panel with the files of the open folder. Folders come first,
//! sorted by name, and are read only when opened. `.git` is hidden. Files
//! and folders can be made, renamed and deleted from here.
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
const prompt_zig = @import("../widgets/prompt.zig");
const Prompt = prompt_zig.Prompt;
const Theme = @import("../theme.zig").Theme;
const Event = @import("../../platform/event.zig").Event;

const hidden = [_][]const u8{".git"};

pub const FileTree = struct {
    editor: *Editor,
    prompt: *Prompt,
    entries: std.ArrayList(Entry) = .empty,
    list: List = .{},
    /// The `folder_version` of the editor that `entries` show.
    version: ?u32 = null,
    /// The folder a new file goes in, or the path being renamed or deleted.
    target: ?[]u8 = null,

    const Entry = struct { path: []u8, depth: usize, is_dir: bool, open: bool = false };

    pub fn deinit(self: *FileTree) void {
        self.clear();
        self.entries.deinit(self.editor.allocator);
        self.setTarget(null);
    }

    pub fn title(_: *FileTree) []const u8 {
        return "Files";
    }

    fn clear(self: *FileTree) void {
        for (self.entries.items) |entry| self.editor.allocator.free(entry.path);
        self.entries.clearRetainingCapacity();
    }

    fn setTarget(self: *FileTree, path: ?[]const u8) void {
        if (self.target) |old| self.editor.allocator.free(old);
        self.target = if (path) |new| self.editor.allocator.dupe(u8, new) catch null else null;
    }

    /// Reads the folder again when the editor opened another one.
    pub fn sync(self: *FileTree) void {
        if (self.version == self.editor.folder_version) return;
        self.version = self.editor.folder_version;
        self.list = .{};
        self.reload(&.{});
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
        for (hidden) |skip| if (std.mem.eql(u8, name, skip)) return true;
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

    /// The folder of the selection: a new file goes there.
    fn selectedFolder(self: *const FileTree) ?[]const u8 {
        const entry = self.selectedEntry() orelse return self.editor.folder;
        return if (entry.is_dir) entry.path else std.fs.path.dirname(entry.path) orelse self.editor.folder;
    }

    fn ask(self: *FileTree, kind: prompt_zig.Kind) void {
        const target = switch (kind) {
            .new_file, .new_folder => self.selectedFolder(),
            .rename => if (self.selectedEntry()) |entry| entry.path else null,
        } orelse return;
        self.setTarget(target);
        const label = switch (kind) {
            .new_file => "New file:",
            .new_folder => "New folder:",
            .rename => "Rename to:",
        };
        const initial = if (kind == .rename) std.fs.path.basename(target) else "";
        self.prompt.open(kind, label, initial) catch {};
    }

    /// The name typed in the prompt.
    pub fn submit(self: *FileTree, kind: prompt_zig.Kind, name: []const u8) void {
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

    fn verb(kind: prompt_zig.Kind) []const u8 {
        return switch (kind) {
            .new_file => "create",
            .new_folder => "create",
            .rename => "rename",
        };
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
        switch (event) {
            .key => |press| {
                if (press.mods.ctrl or press.mods.alt) return .no;
                switch (press.key) {
                    .f2 => self.ask(.rename),
                    .char('n') => self.ask(if (press.mods.shift) .new_folder else .new_file),
                    .delete => {
                        const entry = self.selectedEntry() orelse return .yes;
                        self.setTarget(entry.path);
                        return .{ .request = .{ .ask = .{ .question = .delete, .name = std.fs.path.basename(self.target.?) } } };
                    },
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
            .mouse_down => |mouse| {
                if (self.list.click(mouse.y, rect, metrics, count, mouse.clicks)) |_| self.activate(self.list.selected);
            },
            .wheel => |wheel| self.list.scroll(@intFromFloat(-wheel.dy * 3), count, rows),
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
            return .{
                .text = std.fs.path.basename(entry.path),
                .color = if (is_current) self.theme.accent else self.theme.text,
                .indent = entry.depth,
                .icon = if (!entry.is_dir) ' ' else if (entry.open) 'v' else '>',
            };
        }
    };

    pub fn draw(self: *FileTree, canvas: Canvas, look: Look, rect: Rect, focused: bool) void {
        self.sync();
        if (self.editor.folder == null) {
            canvas.drawText(rect.x + look.metrics.cell, rect.y + look.metrics.row / 2, "No folder open", look.theme.line_number);
            canvas.drawText(rect.x + look.metrics.cell, rect.y + look.metrics.row * 1.5, "Ctrl+Shift+O", look.theme.line_number);
            return;
        }
        const rows: Rows = .{ .tree = self, .theme = look.theme, .current = self.editor.file().path };
        self.list.draw(canvas, look, rect, self.entries.items.len, rows, focused);
    }
};
