//! Top-level editor state: the open files, the panes and tabs that show
//! them, focus, messages and config. No SDL here: what only the platform can
//! do is returned as a `Request` for `main.zig` to carry out.
const std = @import("std");
const Document = @import("../core/edit.zig").Document;
const Cursor = @import("../core/cursor.zig").Cursor;
const Range = @import("../core/buffer.zig").Range;
const View = @import("view.zig").View;
const Decoration = @import("decoration.zig").Decoration;
const File = @import("file.zig").File;
const panes = @import("panes.zig");
const Tab = panes.Tab;
const Node = panes.Node;
const fs = @import("../platform/fs.zig");
const config = @import("config.zig");
const keymap = @import("keymap.zig");
const Find = @import("find.zig").Find;
const project_search = @import("project_search.zig");
const ProjectSearch = project_search.ProjectSearch;
const Rules = @import("../syntax/grammar.zig").Rules;
const language = @import("../syntax/language.zig");
const comment = @import("../core/comment.zig");
const git_zig = @import("git.zig");
const Git = git_zig.Git;
const terminals_zig = @import("terminals.zig");
const Terminals = terminals_zig.Terminals;

pub const Pick = enum { open_file, save_file, open_folder };

pub const Question = enum {
    /// Save / Don't save / Cancel.
    save,
    /// Reload / Keep mine.
    reload,
    /// Delete / Cancel.
    delete,
    /// Discard / Cancel.
    discard,
};

/// What the prompt asks for.
pub const PromptKind = enum { new_file, new_folder, rename, find, replace, goto_line, find_in_project, language, branch };

/// The language of a file without a grammar.
pub const plain_text = "Plain Text";

/// `yes` is the first button of a question, `no` the second.
pub const Answer = enum { yes, no, cancel };

pub const Request = union(enum) {
    quit,
    /// Put this text on the clipboard. Valid until the next command.
    copy: [:0]const u8,
    /// Call `paste` with the clipboard text.
    paste,
    /// Show a native dialog. Its result comes back through `receive`.
    pick: Pick,
    /// Show a message box about `name`, then call `answer`.
    ask: struct { question: Question, name: []const u8 },
    /// Open the prompt. The workbench does this itself.
    prompt: PromptKind,
};

/// Result of background work, sent to the main loop through a mailbox.
/// The main thread passes it to `receive`, which frees it.
pub const Posted = union(enum) {
    /// A dialog was confirmed. `path` is allocated with the editor's allocator.
    picked: struct { pick: Pick, path: []u8 },
    cancelled,
    /// No native dialog could be shown.
    dialog_failed,
    found: project_search.Found,
    search_done: project_search.Done,
    git: *git_zig.Job,
    terminal: terminals_zig.Output,
};

pub const Mailbox = @import("../platform/mailbox.zig").Mailbox(Posted);

/// What the status bar shows.
pub const Status = struct {
    name: []const u8,
    modified: bool,
    /// One-based.
    line: usize,
    column: usize,
    line_ending: []const u8,
    language: []const u8,
    /// Empty outside a repository.
    branch: []const u8,
    message: ?[]const u8,
};

/// The parts of the window that can have focus.
pub const Area = enum { sidebar, editor, bottom };

/// The panels of the sidebar and of the bottom dock.
pub const SidePanel = enum { files, git };
pub const BottomPanel = enum { messages, search, terminal };

/// A panel at an edge of the window.
pub const Dock = struct {
    shown: bool = false,
    /// Width of the sidebar in cells, height of the bottom panel in rows.
    size: u16,
};

pub const Editor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    files: std.ArrayList(*File) = .empty,
    /// The pane tree, and the pane with focus.
    root: *Node,
    pane: *Node,
    focus: Area = .editor,
    sidebar: Dock = .{ .size = 30 },
    bottom: Dock = .{ .size = 10 },
    side_panel: SidePanel = .files,
    bottom_panel: BottomPanel = .messages,
    folder: ?[]u8 = null,
    /// Goes up whenever `folder` changes.
    folder_version: u32 = 0,
    /// Screen pixels per font pixel.
    zoom: u8 = 1,
    default_zoom: u8 = 1,
    /// The zoom that matches the screen, used when the setting is 0.
    screen_zoom: u8 = 1,
    loader: config.Loader,
    settings: config.Settings = undefined,
    bindings: []const keymap.Binding = &keymap.default,
    /// Every grammar, built-in and the user's.
    languages: []const Rules = &.{},
    /// "Plain Text" and the name of each grammar, for picking one.
    language_names: []const []const u8 = &.{},
    /// Holds the settings and bindings until the next `reloadConfig`.
    config_arena: std.heap.ArenaAllocator,
    /// Goes up on every `reloadConfig`, so the UI knows to load the theme again.
    config_version: u32 = 0,
    /// Current time. The main loop sets it before it passes on input.
    now_ms: u64 = 0,
    message: [160]u8 = undefined,
    message_len: usize = 0,
    message_until_ms: u64 = 0,
    /// Every message, oldest first, for the messages panel.
    log: std.ArrayList([]u8) = .empty,
    /// Waits for an answer, or for a file name, before it can go on.
    pending: ?Pending = null,
    clipboard: std.ArrayList(u8) = .empty,
    find: Find,
    project: ProjectSearch,
    git: Git,
    terminals: Terminals,
    /// The environment the shells of terminals get.
    environ: ?*const std.process.Environ.Map = null,
    /// Where background work posts results. Needed for find in project, git
    /// and terminals.
    mailbox: ?*Mailbox = null,
    /// The id the next file gets.
    next_id: u32 = 1,

    pub const min_zoom = 1;
    pub const max_zoom = 4;
    const message_ms = 4000;
    const max_log = 200;

    const Pending = union(enum) {
        /// Quitting; the files before this index are done.
        quit: usize,
        /// Closing the active tab.
        close,
        reload: *File,
    };

    /// One pane with an empty file and the built-in settings. Set
    /// `loader.dir` and call `reloadConfig` to use the user's files.
    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Editor {
        const root = try Node.create(allocator);
        var editor: Editor = .{
            .allocator = allocator,
            .io = io,
            .root = root,
            .pane = root,
            .loader = .{ .io = io, .gpa = allocator },
            .config_arena = .init(allocator),
            .find = .{ .allocator = allocator },
            .project = .{ .allocator = allocator, .io = io },
            .git = .{ .allocator = allocator, .io = io },
            .terminals = .{ .allocator = allocator },
        };
        errdefer editor.deinit();
        editor.reloadConfig();
        try editor.addTab(try editor.newFile());
        return editor;
    }

    pub fn deinit(self: *Editor) void {
        self.project.deinit();
        self.git.deinit();
        self.terminals.deinit();
        // Results that came too late.
        if (self.mailbox) |mailbox| while (mailbox.take()) |posted| self.drop(posted);
        self.find.deinit();
        self.destroyTabs(self.root);
        self.root.destroy(self.allocator);
        for (self.files.items) |item| item.destroy();
        self.files.deinit(self.allocator);
        if (self.folder) |folder| self.allocator.free(folder);
        for (self.log.items) |line| self.allocator.free(line);
        self.log.deinit(self.allocator);
        self.clipboard.deinit(self.allocator);
        self.config_arena.deinit();
    }

    fn destroyTabs(self: *Editor, node: *Node) void {
        switch (node.kind) {
            .pane => |pane| for (pane.tabs.items) |item| item.destroy(self.allocator),
            .split => |halves| {
                self.destroyTabs(halves.first);
                self.destroyTabs(halves.second);
            },
        }
    }

    // The active tab

    pub fn tab(self: *const Editor) *Tab {
        return self.pane.pane().tab();
    }

    pub fn file(self: *const Editor) *File {
        return self.tab().file;
    }

    pub fn doc(self: *const Editor) *Document {
        return &self.file().doc;
    }

    pub fn view(self: *const Editor) *View {
        return &self.tab().view;
    }

    /// The cursor of any tab. The active tab uses its document's cursor.
    pub fn cursorOf(self: *const Editor, item: *const Tab) Cursor {
        return if (item == self.tab()) item.file.doc.cursor else item.cursor;
    }

    /// Keeps the cursor of the active tab before another one becomes active.
    fn leave(self: *Editor) void {
        const active = self.tab();
        active.cursor = active.file.doc.cursor;
    }

    /// Makes a tab active. Call `leave` first while the old one still exists.
    fn enter(self: *Editor, node: *Node, index: usize) void {
        self.pane = node;
        node.pane().active = index;
        const active = self.tab();
        active.file.doc.cursor = active.cursor;
        self.afterEdit();
    }

    pub fn switchTo(self: *Editor, node: *Node, index: usize) void {
        self.leave();
        self.enter(node, index);
    }

    // Messages

    /// Shows a short message in the status bar for a few seconds and keeps it
    /// in the log. Every feature reports errors and info through here.
    pub fn notify(self: *Editor, comptime format: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.message, format, args) catch &self.message;
        self.message_len = text.len;
        self.message_until_ms = self.now_ms + message_ms;
        const line = self.allocator.dupe(u8, text) catch return;
        self.log.append(self.allocator, line) catch return self.allocator.free(line);
        if (self.log.items.len > max_log) self.allocator.free(self.log.orderedRemove(0));
    }

    pub fn currentMessage(self: *const Editor) ?[]const u8 {
        const active = self.message_len > 0 and self.now_ms < self.message_until_ms;
        return if (active) self.message[0..self.message_len] else null;
    }

    /// Milliseconds until the message must disappear, if one is showing.
    pub fn messageTimeLeft(self: *const Editor) ?u64 {
        return if (self.currentMessage() != null) self.message_until_ms - self.now_ms else null;
    }

    // Input that is not a command

    pub fn typeText(self: *Editor, text: []const u8) void {
        self.doc().insert(text) catch |err| self.notify("Could not insert: {t}", .{err});
        self.afterEdit();
    }

    /// Clipboard text arrives after a `paste` request.
    pub fn paste(self: *Editor, text: []const u8) void {
        self.doc().paste(text) catch |err| self.notify("Could not paste: {t}", .{err});
        self.afterEdit();
    }

    /// A click on a cell of the active text area. Two clicks select a word,
    /// three a line.
    pub fn mouseDown(self: *Editor, cell_x: isize, cell_y: isize, clicks: u8, extend: bool) void {
        const doc_ = self.doc();
        const pos = self.view().posAt(doc_, cell_x, cell_y);
        switch (clicks) {
            0, 1 => doc_.cursor.moveTo(pos, extend),
            2 => doc_.selectWord(pos),
            else => doc_.selectLine(pos),
        }
        self.refreshVisible(self.root);
    }

    /// The mouse moved with the button down. Past an edge, the view scrolls.
    pub fn mouseDrag(self: *Editor, cell_x: isize, cell_y: isize) void {
        const view_ = self.view();
        const rows: isize = @intCast(view_.rows);
        const cols: isize = @intCast(view_.cols);
        view_.scrollBy(self.doc(), edgeStep(cell_y, rows), edgeStep(cell_x, cols));
        self.doc().cursor.moveTo(view_.posAt(self.doc(), cell_x, cell_y), true);
        self.refreshVisible(self.root);
    }

    fn edgeStep(cell: isize, size: isize) isize {
        return if (cell < 0) -1 else if (cell >= size) 1 else 0;
    }

    pub fn scroll(self: *Editor, rows: isize, cols: isize) void {
        self.view().scrollBy(self.doc(), rows, cols);
    }

    /// Call after anything that moved the cursor or changed the text.
    pub fn afterEdit(self: *Editor) void {
        if (self.find.shown) self.find.refresh(self.doc());
        self.view().scrollToCursor(self.doc());
        self.refreshVisible(self.root);
    }

    /// The decorations of the tab shown in every pane.
    fn refreshVisible(self: *Editor, node: *Node) void {
        switch (node.kind) {
            .pane => |pane| self.refreshDecorations(pane.tab()),
            .split => |halves| {
                self.refreshVisible(halves.first);
                self.refreshVisible(halves.second);
            },
        }
    }

    /// The cursor line, the selection, the find matches and the marks of
    /// the file, sorted by start.
    fn refreshDecorations(self: *Editor, item: *Tab) void {
        item.decorations.clearRetainingCapacity();
        const doc_ = &item.file.doc;
        const cursor = self.cursorOf(item);
        const start = doc_.buffer.lineStart(doc_.buffer.lineOf(@min(cursor.pos, doc_.buffer.len())));
        const list = &item.decorations;
        const matches = if (self.find.shown and item.file == self.file()) self.find.matches.items else &.{};
        list.ensureUnusedCapacity(self.allocator, matches.len + 4) catch return;
        if (item.file.highlighter.matchBracket(doc_, cursor.pos)) |pair| for (pair) |at| {
            list.appendAssumeCapacity(.{ .range = .{ .start = at, .end = at + 1 }, .kind = .{ .text_background = .bracket } });
        };
        list.appendAssumeCapacity(.{ .range = .{ .start = start, .end = start }, .kind = .{ .line_background = .current_line } });
        if (cursor.selection().len() > 0) list.appendAssumeCapacity(.{ .range = cursor.selection(), .kind = .{ .text_background = .selection } });
        for (matches) |range| list.appendAssumeCapacity(.{ .range = range, .kind = .{ .text_background = .match } });
        const tracking = &item.file.tracking;
        list.appendSlice(self.allocator, item.file.marks.items) catch {};
        list.appendSlice(self.allocator, tracking.markers.items) catch {};
        // Blame of saved text only: edits move the lines.
        if (self.git.blame and tracking.blame == .ready and !item.file.doc.history.isModified()) list.appendSlice(self.allocator, tracking.blame.ready.marks) catch {};
        std.mem.sort(Decoration, list.items, {}, byStart);
    }

    fn byStart(_: void, a: Decoration, b: Decoration) bool {
        return a.range.start < b.range.start;
    }

    // Clipboard

    /// The selection, or the whole line when nothing is selected.
    fn clipboardRange(self: *const Editor) Range {
        const doc_ = self.doc();
        const selection = doc_.cursor.selection();
        if (selection.len() > 0) return selection;
        return doc_.lineRange(doc_.buffer.lineOf(doc_.cursor.pos));
    }

    pub fn copy(self: *Editor) !Request {
        const range = self.clipboardRange();
        self.clipboard.clearRetainingCapacity();
        const text = try self.clipboard.addManyAsSlice(self.allocator, range.len() + 1);
        _ = self.doc().buffer.copy(range.start, text[0..range.len()]);
        text[range.len()] = 0;
        return .{ .copy = text[0..range.len() :0] };
    }

    pub fn cut(self: *Editor) !Request {
        const request = try self.copy();
        try self.doc().replace(self.clipboardRange(), "");
        return request;
    }

    // Files and tabs

    pub fn isModified(self: *const Editor) bool {
        return self.file().isModified();
    }

    pub fn name(self: *const Editor) []const u8 {
        return self.file().name();
    }

    fn newFile(self: *Editor) !*File {
        const created = try File.create(self.allocator);
        errdefer created.destroy();
        try self.adopt(created);
        return created;
    }

    /// Makes `target` one of the open files.
    fn adopt(self: *Editor, target: *File) !void {
        try self.files.append(self.allocator, target);
        target.id = self.next_id;
        self.next_id +%= 1;
        self.applySettings(target);
    }

    pub fn fileById(self: *const Editor, id: u32) ?*File {
        for (self.files.items) |item| if (item.id == id) return item;
        return null;
    }

    fn dropFile(self: *Editor, gone: *File) void {
        const at = std.mem.indexOfScalar(*File, self.files.items, gone).?;
        _ = self.files.orderedRemove(at);
        gone.destroy();
    }

    pub fn findFile(self: *const Editor, path: []const u8) ?*File {
        for (self.files.items) |item| {
            if (item.path) |own| if (std.mem.eql(u8, own, path)) return item;
        }
        return null;
    }

    /// Number of tabs that show `target`.
    fn tabCount(node: *Node, target: *const File) usize {
        return switch (node.kind) {
            .pane => |pane| blk: {
                var count: usize = 0;
                for (pane.tabs.items) |item| count += @intFromBool(item.file == target);
                break :blk count;
            },
            .split => |halves| tabCount(halves.first, target) + tabCount(halves.second, target),
        };
    }

    /// Adds a tab for `target` after the active tab and makes it active.
    fn addTab(self: *Editor, target: *File) !void {
        const created = try Tab.create(self.allocator, target);
        errdefer created.destroy(self.allocator);
        created.view.setWrap(self.settings.wrap);
        const pane = self.pane.pane();
        const index = if (pane.tabs.items.len == 0) 0 else pane.active + 1;
        try pane.tabs.insert(self.allocator, index, created);
        if (pane.tabs.items.len > 1) self.leave();
        self.enter(self.pane, index);
    }

    /// Shows `target` if a tab has it: in the active pane if it can.
    pub fn show(self: *Editor, target: *const File) bool {
        if (self.pane.pane().find(target)) |index| {
            self.switchTo(self.pane, index);
            return true;
        }
        var list: std.ArrayList(*Node) = .empty;
        defer list.deinit(self.allocator);
        self.root.leaves(self.allocator, &list) catch return false;
        for (list.items) |node| if (node.pane().find(target)) |index| {
            self.switchTo(node, index);
            return true;
        };
        return false;
    }

    /// Opens `path` in a new tab, or shows it if it is open.
    pub fn open(self: *Editor, path: []const u8) void {
        if (self.findFile(path)) |found| if (self.show(found)) return;
        const opened = File.open(self.allocator, self.io, path) catch |err| {
            self.notify("Could not open {s}: {t}", .{ std.fs.path.basename(path), err });
            return;
        };
        self.adopt(opened) catch {
            opened.destroy();
            return;
        };
        self.place(opened) catch |err| {
            self.dropFile(opened);
            self.notify("Could not open {s}: {t}", .{ std.fs.path.basename(path), err });
        };
    }

    /// Adds a tab for a new open file. A blank untitled tab is replaced.
    fn place(self: *Editor, target: *File) !void {
        const blank = self.file().isBlank() and tabCount(self.root, self.file()) == 1;
        try self.addTab(target);
        if (blank) self.removeTab(self.pane.pane().active - 1);
    }

    /// Opens a read-only tab with `text`, colored like the file `like`.
    pub fn openView(self: *Editor, title_: []const u8, text: []const u8, like: ?[]const u8) ?*File {
        const created = self.newFile() catch return null;
        created.role = .diff;
        created.title = self.allocator.dupe(u8, title_) catch null;
        created.doc.load(text) catch {};
        created.doc.read_only = true;
        if (like) |path| if (language.detect(self.languages, path, "")) |rules| {
            created.language = self.allocator.dupe(u8, rules.grammar.name) catch null;
        };
        self.applyLanguage(created);
        self.place(created) catch {
            self.dropFile(created);
            return null;
        };
        self.focus = .editor;
        return created;
    }

    fn commitMessage(self: *const Editor) ?*File {
        for (self.files.items) |item| if (item.role == .commit) return item;
        return null;
    }

    /// Shows the message of the next commit. Amending starts from `text`.
    pub fn openCommitMessage(self: *Editor, text: []const u8, amend: bool) void {
        const message = self.commitMessage() orelse blk: {
            const created = self.newFile() catch return;
            created.language = self.allocator.dupe(u8, "Git Commit") catch null;
            self.applyLanguage(created);
            self.place(created) catch return self.dropFile(created);
            break :blk created;
        };
        message.role = .{ .commit = amend };
        const title_ = self.allocator.dupe(u8, if (amend) "Amend commit" else "Commit message") catch return;
        if (message.title) |old| self.allocator.free(old);
        message.title = title_;
        if (amend) {
            message.doc.load(text) catch {};
            message.doc.cursor = .{ .pos = message.doc.buffer.len() };
        }
        _ = self.show(message);
        self.focus = .editor;
        self.notify("Ctrl+Enter commits", .{});
    }

    /// Commits the open commit message, or opens one to write.
    pub fn commit(self: *Editor) !void {
        const active = self.file();
        if (active.role != .commit) return self.openCommitMessage("", false);
        const text = try self.allocator.alloc(u8, active.doc.buffer.len());
        defer self.allocator.free(text);
        _ = active.doc.buffer.copy(0, text);
        self.git.commit(text, active.role.commit);
    }

    /// Closes every tab of the commit message after a commit.
    pub fn closeCommitMessage(self: *Editor) void {
        while (self.commitMessage()) |message| {
            if (!self.show(message)) return self.dropFile(message);
            self.closeActive();
        }
    }

    /// Removes a tab of the active pane that is not the active one.
    fn removeTab(self: *Editor, index: usize) void {
        const pane = self.pane.pane();
        const gone = pane.tabs.orderedRemove(index);
        if (pane.active > index) pane.active -= 1;
        const shown = gone.file;
        gone.destroy(self.allocator);
        if (tabCount(self.root, shown) == 0) self.dropFile(shown);
    }

    /// Closes a tab of the active pane, after asking about unsaved changes.
    pub fn closeTab(self: *Editor, index: usize) ?Request {
        self.dropPending();
        if (index != self.pane.pane().active) self.switchTo(self.pane, index);
        const active = self.file();
        if (active.isModified() and tabCount(self.root, active) == 1) {
            self.pending = .close;
            return .{ .ask = .{ .question = .save, .name = active.name() } };
        }
        self.closeActive();
        return null;
    }

    /// Closes the active tab. An empty pane closes too; the last one gets a
    /// new empty file instead.
    fn closeActive(self: *Editor) void {
        const node = self.pane;
        const pane = node.pane();
        const gone = pane.tabs.orderedRemove(pane.active);
        const shown = gone.file;
        gone.destroy(self.allocator);
        if (tabCount(self.root, shown) == 0) self.dropFile(shown);
        if (pane.tabs.items.len > 0) return self.enter(node, @min(pane.active, pane.tabs.items.len - 1));
        if (node.parent == null) {
            const blank = self.newFile() catch return;
            self.addTab(blank) catch return self.dropFile(blank);
            return;
        }
        const next = node.remove(self.allocator).firstLeaf();
        self.enter(next, next.pane().active);
    }

    pub fn newTab(self: *Editor) !void {
        const created = try self.newFile();
        self.addTab(created) catch |err| {
            self.dropFile(created);
            return err;
        };
    }

    /// Moves to the next tab of the active pane, or the previous one.
    pub fn cycleTab(self: *Editor, step: isize) void {
        const pane = self.pane.pane();
        const count: isize = @intCast(pane.tabs.items.len);
        self.switchTo(self.pane, @intCast(@mod(@as(isize, @intCast(pane.active)) + step, count)));
    }

    /// Splits the active pane. The new pane shows the same file.
    pub fn split(self: *Editor, axis: panes.Axis) !void {
        const old = self.tab();
        self.leave();
        const created = try Tab.create(self.allocator, old.file);
        errdefer created.destroy(self.allocator);
        created.cursor = old.cursor;
        created.view = old.view;
        const second = try self.pane.split(self.allocator, axis);
        second.pane().tabs.append(self.allocator, created) catch |err| {
            _ = second.remove(self.allocator);
            return err;
        };
        self.enter(second, 0);
    }

    /// Moves focus to the next pane, or the previous one.
    pub fn cyclePane(self: *Editor, step: isize) !void {
        var list: std.ArrayList(*Node) = .empty;
        defer list.deinit(self.allocator);
        try self.root.leaves(self.allocator, &list);
        const at: isize = @intCast(std.mem.indexOfScalar(*Node, list.items, self.pane).?);
        const next = list.items[@intCast(@mod(at + step, @as(isize, @intCast(list.items.len))))];
        self.switchTo(next, next.pane().active);
        self.focus = .editor;
    }

    pub fn quit(self: *Editor) ?Request {
        self.dropPending();
        return self.quitFrom(0);
    }

    /// Asks about the next file with unsaved changes, or quits.
    fn quitFrom(self: *Editor, from: usize) ?Request {
        for (self.files.items[from..], from..) |item, index| {
            if (!item.isModified()) continue;
            _ = self.show(item);
            self.pending = .{ .quit = index };
            return .{ .ask = .{ .question = .save, .name = item.name() } };
        }
        return .quit;
    }

    /// Saves the active file, or asks for a name if it has none.
    pub fn save(self: *Editor) ?Request {
        const active = self.file();
        const path = active.path orelse return .{ .pick = .save_file };
        active.save(self.io) catch |err| {
            self.notify("Could not save {s}: {t}", .{ active.name(), err });
            self.dropPending();
            return null;
        };
        self.notify("Saved {s}", .{active.name()});
        active.tracking.forgetBlame(self.allocator);
        self.git.refresh();
        if (self.loader.dir) |dir| {
            const inside = path.len > dir.len and std.mem.startsWith(u8, path, dir) and std.fs.path.isSep(path[dir.len]);
            if (inside) self.reloadConfig();
        }
        return self.goOn(.yes);
    }

    /// The answer to an `ask` request.
    pub fn answer(self: *Editor, choice: Answer) ?Request {
        const action = self.pending orelse return null;
        if (choice == .cancel) {
            self.dropPending();
            return null;
        }
        return switch (action) {
            .quit, .close => if (choice == .yes) self.save() else self.goOn(.no),
            .reload => self.goOn(choice),
        };
    }

    /// Finishes what was waiting, after a save (`yes`) or not (`no`).
    fn goOn(self: *Editor, choice: Answer) ?Request {
        const action = self.pending orelse return null;
        self.pending = null;
        switch (action) {
            .quit => |index| return self.quitFrom(index + 1),
            .close => self.closeActive(),
            .reload => |target| {
                if (choice == .yes) {
                    target.reload(self.io) catch |err| self.notify("Could not reload {s}: {t}", .{ target.name(), err });
                } else {
                    target.disk_time = fs.modTime(self.io, target.path.?);
                }
                return self.checkDisk();
            },
        }
        return null;
    }

    fn dropPending(self: *Editor) void {
        self.pending = null;
    }

    /// Takes a result from the mailbox and frees it.
    pub fn receive(self: *Editor, posted: Posted) ?Request {
        switch (posted) {
            .found => |found| self.project.receive(found),
            .search_done => |done| self.project.done(done),
            .terminal => |output| self.terminals.receive(output),
            .git => |job| {
                defer self.refreshVisible(self.root);
                return self.git.receive(job);
            },
            .cancelled => self.dropPending(),
            .dialog_failed => {
                self.dropPending();
                self.notify("No file dialog: install zenity", .{});
            },
            .picked => |picked| {
                defer self.allocator.free(picked.path);
                switch (picked.pick) {
                    .open_file => self.open(picked.path),
                    .save_file => {
                        self.file().setPath(picked.path) catch |err| {
                            self.notify("Could not save: {t}", .{err});
                            return null;
                        };
                        self.applyLanguage(self.file());
                        return self.save();
                    },
                    .open_folder => self.openFolder(picked.path),
                }
            },
        }
        return null;
    }

    /// Frees a result without using it.
    fn drop(self: *Editor, posted: Posted) void {
        switch (posted) {
            .picked => |picked| self.allocator.free(picked.path),
            .found => |found| project_search.freeFound(self.allocator, found),
            .terminal => |output| if (output.bytes) |bytes| self.allocator.free(bytes),
            // `Git.deinit` already freed it.
            .git, .cancelled, .dialog_failed, .search_done => {},
        }
    }

    /// Reloads files that changed on disk. A file with unsaved changes is
    /// shown and the user is asked first.
    pub fn checkDisk(self: *Editor) ?Request {
        defer self.afterEdit();
        for (self.files.items) |item| {
            if (!item.changedOnDisk(self.io)) continue;
            if (item.isModified()) {
                _ = self.show(item);
                self.pending = .{ .reload = item };
                return .{ .ask = .{ .question = .reload, .name = item.name() } };
            }
            item.reload(self.io) catch |err| self.notify("Could not reload {s}: {t}", .{ item.name(), err });
        }
        return null;
    }

    /// Open files follow a file or folder that was renamed.
    pub fn renamed(self: *Editor, old: []const u8, new: []const u8) void {
        for (self.files.items) |item| {
            const path = item.path orelse continue;
            const inside = path.len > old.len and std.fs.path.isSep(path[old.len]);
            if (!std.mem.startsWith(u8, path, old) or !(path.len == old.len or inside)) continue;
            const moved = std.mem.concat(self.allocator, u8, &.{ new, path[old.len..] }) catch continue;
            defer self.allocator.free(moved);
            item.setPath(moved) catch {};
            self.applyLanguage(item);
        }
    }

    /// Moves to `line` or `line:column`, both one-based.
    pub fn gotoLine(self: *Editor, text: []const u8) void {
        var parts = std.mem.splitScalar(u8, std.mem.trim(u8, text, " "), ':');
        const line = std.fmt.parseInt(usize, parts.first(), 10) catch 0;
        const column = if (parts.next()) |part| std.fmt.parseInt(usize, part, 10) catch 0 else 1;
        if (line == 0 or column == 0 or parts.next() != null) return self.notify("Not a line: {s}", .{text});
        const doc_ = self.doc();
        const target = @min(line, doc_.buffer.lineCount()) - 1;
        doc_.cursor.moveTo(doc_.posAtColumn(target, column - 1), false);
        self.afterEdit();
    }

    /// Opens the file of a search hit and selects the match.
    pub fn openHit(self: *Editor, hit: project_search.Hit) void {
        self.open(hit.path);
        const active = self.file();
        if (active.path == null or !std.mem.eql(u8, active.path.?, hit.path)) return;
        const buffer = &active.doc.buffer;
        const start = @min(buffer.lineStart(@min(hit.line, buffer.lineCount() - 1)) + hit.column, buffer.len());
        active.doc.cursor = .{ .anchor = start, .pos = @min(start + hit.len, buffer.len()) };
        self.focus = .editor;
        self.afterEdit();
    }

    /// Searches every file of the open folder for `needle`, on a thread.
    pub fn findInProject(self: *Editor, needle: []const u8) void {
        const folder = self.folder orelse return self.notify("Open a folder first", .{});
        const mailbox = self.mailbox orelse return;
        if (needle.len == 0) return;
        const query: @import("../core/search.zig").Query = .{ .needle = needle, .options = self.find.options };
        self.project.start(mailbox, folder, query, self.settings.search_exclude) catch |err| self.notify("Could not search: {t}", .{err});
    }

    pub fn openFolder(self: *Editor, path: []const u8) void {
        const copy_ = self.allocator.dupe(u8, path) catch return;
        if (self.folder) |old| self.allocator.free(old);
        self.folder = copy_;
        self.folder_version +%= 1;
        self.sidebar.shown = true;
        self.git.open(copy_);
    }

    // Focus and docks

    pub fn dock(self: *Editor, area: Area) *Dock {
        return switch (area) {
            .sidebar => &self.sidebar,
            .bottom => &self.bottom,
            .editor => unreachable,
        };
    }

    pub fn showSide(self: *Editor, panel: SidePanel) void {
        self.side_panel = panel;
        self.focusArea(.sidebar);
        if (panel == .git) self.git.refresh();
    }

    /// The terminal panel starts a terminal when it has none.
    pub fn showBottom(self: *Editor, panel: BottomPanel) void {
        self.bottom_panel = panel;
        self.focusArea(.bottom);
        if (panel == .terminal and self.terminals.list.items.len == 0) self.openTerminal();
    }

    pub fn focusArea(self: *Editor, area: Area) void {
        if (area != .editor) self.dock(area).shown = true;
        self.focus = area;
    }

    pub fn toggleDock(self: *Editor, area: Area) void {
        const target = self.dock(area);
        target.shown = !target.shown;
        if (!target.shown and self.focus == area) self.focus = .editor;
    }

    // Terminals

    /// Starts a shell in the open folder, in a new terminal.
    pub fn openTerminal(self: *Editor) void {
        const mailbox = self.mailbox orelse return;
        self.terminals.open(mailbox, .{
            .shell = self.settings.shell,
            .cwd = self.folder,
            .env = self.environ,
            .scrollback = self.settings.terminal_scrollback,
        }) catch |err| return self.notify("Could not start a terminal: {t}", .{err});
        self.showBottom(.terminal);
    }

    /// Shows the terminal panel, or hides it when it has focus.
    pub fn toggleTerminal(self: *Editor) void {
        if (self.bottom.shown and self.bottom_panel == .terminal and self.focus == .bottom) return self.toggleDock(.bottom);
        self.showBottom(.terminal);
    }

    /// Closing the last terminal hides the panel.
    pub fn closeTerminal(self: *Editor, index: usize) void {
        self.terminals.close(index);
        if (self.terminals.list.items.len == 0 and self.bottom_panel == .terminal) {
            self.bottom.shown = false;
            self.focus = .editor;
        }
    }

    // Config

    /// Loads the settings and key bindings again and applies them.
    pub fn reloadConfig(self: *Editor) void {
        _ = self.config_arena.reset(.retain_capacity);
        const arena = self.config_arena.allocator();
        const base = config.builtin(config.Settings, self.allocator, arena, "settings");
        self.settings = self.loader.load(config.Settings, arena, "settings", base, self);
        self.loadLanguages(arena);
        for (self.files.items) |item| self.applySettings(item);
        self.applyWrap(self.root);
        self.setZoom(if (self.settings.zoom == 0) self.screen_zoom else self.settings.zoom);
        self.default_zoom = self.zoom;
        const entries = self.loader.load([]const keymap.Entry, arena, "keymap", &.{}, self);
        self.bindings = keymap.withUser(arena, entries, self) catch &keymap.default;
        // The git setting may name a program that is there now.
        self.git.available = true;
        self.config_version +%= 1;
    }

    fn applySettings(self: *const Editor, target: *File) void {
        target.doc.tab_width = std.math.clamp(self.settings.tab_width, 1, Document.max_tab_width);
        target.doc.soft_tabs = self.settings.use_spaces;
        target.doc.history.max_size = @as(usize, self.settings.undo_limit_mb) << 20;
        self.applyLanguage(target);
    }

    fn loadLanguages(self: *Editor, arena: std.mem.Allocator) void {
        var rules: std.ArrayList(Rules) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        names.append(arena, plain_text) catch {};
        const files_ = self.loader.names(arena, config.grammar_folder) catch &.{};
        for (files_) |file_| {
            const path = std.fmt.allocPrint(arena, config.grammar_folder ++ "/{s}", .{file_}) catch continue;
            const grammar = self.loader.load(@import("../syntax/grammar.zig").Grammar, arena, path, .{ .name = "" }, self);
            if (grammar.name.len == 0) {
                self.notify("{s}.zon: no .name", .{path});
                continue;
            }
            rules.append(arena, Rules.init(arena, grammar) catch continue) catch continue;
            names.append(arena, grammar.name) catch {};
        }
        self.languages = rules.items;
        self.language_names = names.items;
    }

    /// Picks the grammar of a file: the one chosen by hand, else by its
    /// name or first line.
    fn applyLanguage(self: *const Editor, target: *File) void {
        if (target.language) |chosen| return target.highlighter.setRules(language.byName(self.languages, chosen));
        const path = target.path orelse return target.highlighter.setRules(null);
        var head: [language.head_size]u8 = undefined;
        target.highlighter.setRules(language.detect(self.languages, path, target.doc.buffer.copy(0, &head)));
    }

    /// The language of the active file, chosen by hand.
    pub fn setLanguage(self: *Editor, chosen: []const u8) void {
        const found = language.byName(self.languages, chosen);
        if (found == null and !std.ascii.eqlIgnoreCase(chosen, plain_text)) return self.notify("No language named {s}", .{chosen});
        const target = self.file();
        const copy_ = self.allocator.dupe(u8, if (found) |rules| rules.grammar.name else plain_text) catch return;
        if (target.language) |old| self.allocator.free(old);
        target.language = copy_;
        self.applyLanguage(target);
    }

    /// Comments or uncomments the selected lines.
    pub fn toggleComment(self: *Editor) !void {
        const rules = self.file().highlighter.rules orelse return self.notify("No comments in {s}", .{plain_text});
        const markers = rules.commentMarkers() orelse return self.notify("No comments in {s}", .{rules.grammar.name});
        try comment.toggle(self.doc(), markers.start, markers.end);
    }

    /// Moves to the bracket that matches the one at the cursor.
    pub fn gotoBracket(self: *Editor) void {
        const pair = self.file().highlighter.matchBracket(self.doc(), self.doc().cursor.pos) orelse return;
        self.doc().cursor = .{ .pos = pair[1] };
    }

    // Git

    /// Asks git for what open files need, and makes their gutter markers
    /// again once their text rests. The main loop calls it before drawing.
    /// True when something on screen changed.
    pub fn tick(self: *Editor) bool {
        var changed = false;
        for (self.files.items) |item| {
            if (item.role != .text or item.path == null) continue;
            const tracking = &item.tracking;
            if (self.git.ready()) {
                if (tracking.head == .unknown) self.git.fetchHead(item);
                if (self.git.blame and tracking.blame == .unknown) self.git.fetchBlame(item);
            }
            if (tracking.tick(self.allocator, &item.doc, self.now_ms)) changed = true;
        }
        if (changed) self.refreshVisible(self.root);
        return changed;
    }

    /// Milliseconds until the screen must change by itself, if ever.
    pub fn timeLeft(self: *const Editor) ?u64 {
        var left = self.messageTimeLeft();
        for (self.files.items) |item| if (item.tracking.timeLeft(self.now_ms)) |ms| {
            left = @min(ms, left orelse ms);
        };
        return left;
    }

    /// Moves to the start of the next or previous block of changed lines:
    /// the git markers of a file, or the lines of a diff view.
    pub fn jumpToChange(self: *Editor, forward: bool) void {
        const active = self.file();
        const buffer = &active.doc.buffer;
        const line = buffer.lineOf(active.doc.cursor.pos);
        const marks = if (active.role == .diff) active.marks.items else active.tracking.markers.items;
        var target: ?usize = null;
        var last: ?usize = null;
        for (marks) |mark| {
            const style = switch (mark.kind) {
                .gutter_marker, .line_background => |style| style,
                else => continue,
            };
            if (style == .diff_header) continue;
            const first = buffer.lineOf(mark.range.start);
            const starts = if (last) |end| first > end + 1 else true;
            last = buffer.lineOf(mark.range.end);
            if (!starts) continue;
            if (forward and first > line) {
                target = first;
                break;
            }
            if (!forward and first < line) target = first;
        }
        const found = target orelse return self.notify("No more changes", .{});
        active.doc.cursor = .{ .pos = buffer.lineStart(found) };
    }

    pub fn toggleBlame(self: *Editor) void {
        if (!self.git.ready()) return self.notify("No git repository", .{});
        self.git.blame = !self.git.blame;
        self.notify("Blame {s}", .{if (self.git.blame) "on" else "off"});
    }

    /// A click in the gutter of the active tab: with blame shown, opens the
    /// commit that last changed the line.
    pub fn clickGutter(self: *Editor, line: usize) void {
        if (!self.git.blame or self.doc().history.isModified()) return;
        const lines = switch (self.file().tracking.blame) {
            .ready => |lines| lines,
            else => return,
        };
        self.git.showDiff(.{ .commit = lines.hashOf(line) orelse return });
    }

    /// The history of the active file, in the git panel.
    pub fn fileHistory(self: *Editor) void {
        const path = self.file().path orelse return self.notify("Save the file first", .{});
        self.git.loadHistory(path);
        self.git.page = .history;
        self.showSide(.git);
    }

    fn applyWrap(self: *Editor, node: *Node) void {
        switch (node.kind) {
            .pane => |pane| for (pane.tabs.items) |item| item.view.setWrap(self.settings.wrap),
            .split => |halves| {
                self.applyWrap(halves.first);
                self.applyWrap(halves.second);
            },
        }
    }

    /// Opens the user's settings file, made from the built-in one if missing.
    pub fn openSettings(self: *Editor) !void {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = self.loader.path(&buffer, "settings") orelse {
            self.notify("No config folder", .{});
            return;
        };
        if (fs.modTime(self.io, path) == null) {
            try fs.write(self.io, path, &.{self.loader.source(self.allocator, "settings", self).?});
        }
        self.open(path);
    }

    /// Switches to the next theme and remembers it in the settings file.
    pub fn nextTheme(self: *Editor) !void {
        const arena = self.config_arena.allocator();
        const names = try self.loader.names(arena, config.theme_folder);
        var next: usize = 0;
        for (names, 1..) |theme, after| {
            if (std.mem.eql(u8, theme, self.settings.theme)) next = after % names.len;
        }
        self.notify("Theme: {s}", .{names[next]});
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = self.loader.path(&buffer, "settings") orelse {
            self.settings.theme = names[next];
            self.config_version +%= 1;
            return;
        };
        const value = try std.fmt.allocPrint(arena, "\"{s}\"", .{names[next]});
        const text = try config.setField(arena, self.loader.source(arena, "settings", self).?, "theme", value);
        try fs.write(self.io, path, &.{text});
        self.reloadConfig();
    }

    // Display

    pub fn status(self: *const Editor) Status {
        const doc_ = self.doc();
        const pos = doc_.cursor.pos;
        return .{
            .name = self.name(),
            .modified = self.isModified(),
            .line = doc_.buffer.lineOf(pos) + 1,
            .column = doc_.columnOf(pos) + 1,
            .line_ending = doc_.line_ending.name(),
            .language = if (self.file().highlighter.rules) |rules| rules.grammar.name else plain_text,
            .branch = if (self.git.ready()) self.git.status.branch else "",
            .message = self.currentMessage(),
        };
    }

    /// Window title: the file name, with a dot when there are unsaved changes.
    pub fn title(self: *const Editor, buffer: []u8) []const u8 {
        const dot = if (self.isModified()) "\u{25CF} " else "";
        return std.fmt.bufPrint(buffer, "{s}{s} - 8-Bit", .{ dot, self.name() }) catch "8-Bit";
    }

    pub fn setZoom(self: *Editor, zoom: i32) void {
        self.zoom = @intCast(std.math.clamp(zoom, min_zoom, max_zoom));
    }
};

const testing = std.testing;
const expectText = @import("../core/buffer.zig").expectText;

fn testEditor(text: []const u8) !Editor {
    var editor = try Editor.init(testing.allocator, testing.io);
    errdefer editor.deinit();
    try editor.doc().load(text);
    return editor;
}

test "notify shows a message until its time is over, and logs it" {
    var editor = try testEditor("");
    defer editor.deinit();
    try testing.expectEqual(@as(?[]const u8, null), editor.currentMessage());

    editor.now_ms = 1000;
    editor.notify("Saved {s}", .{"a.txt"});
    try testing.expectEqualStrings("Saved a.txt", editor.currentMessage().?);
    try testing.expectEqual(@as(?u64, 4000), editor.messageTimeLeft());
    editor.now_ms = 4999;
    try testing.expectEqual(@as(?u64, 1), editor.messageTimeLeft());
    editor.now_ms = 5000;
    try testing.expectEqual(@as(?[]const u8, null), editor.currentMessage());
    try testing.expectEqual(@as(?u64, null), editor.messageTimeLeft());
    try testing.expectEqualStrings("Saved a.txt", editor.log.items[editor.log.items.len - 1]);
}

test "a message that is too long is cut" {
    var editor = try testEditor("");
    defer editor.deinit();
    const long: [300]u8 = @splat('x');
    editor.notify("{s}", .{&long});
    try testing.expectEqual(editor.message.len, editor.currentMessage().?.len);
}

test "copy and cut use the selection, or the whole line without one" {
    var editor = try testEditor("one\ntwo\nthree");
    defer editor.deinit();
    const doc = editor.doc();
    doc.cursor.pos = 5;
    try testing.expectEqualStrings("two\n", (try editor.copy()).copy);

    doc.cursor = .{ .anchor = 1, .pos = 6 };
    try testing.expectEqualStrings("ne\ntw", (try editor.cut()).copy);
    try testing.expectEqual(@as(usize, 8), doc.buffer.len());

    doc.cursor = .{ .pos = 7 };
    try testing.expectEqualStrings("three", (try editor.cut()).copy);
    try testing.expectEqual(@as(usize, 3), doc.buffer.len());
    try testing.expect(try doc.undo());
    try testing.expectEqual(@as(usize, 8), doc.buffer.len());
}

test "mouse: click, shift+click, double and triple click, drag" {
    var editor = try testEditor("one two\nthree four\nfive");
    defer editor.deinit();
    const doc = editor.doc();
    const decorations = &editor.tab().decorations;
    editor.view().* = .{ .cols = 20, .rows = 2 };

    editor.mouseDown(2, 0, 1, false);
    try testing.expectEqual(@as(usize, 2), doc.cursor.pos);
    editor.mouseDown(3, 1, 1, true);
    try testing.expectEqual(Range{ .start = 2, .end = 11 }, doc.cursor.selection());
    try testing.expectEqual(@as(usize, 2), decorations.items.len);

    editor.mouseDown(5, 0, 2, false);
    try testing.expectEqual(Range{ .start = 4, .end = 7 }, doc.cursor.selection());
    editor.mouseDown(5, 1, 3, false);
    try testing.expectEqual(Range{ .start = 8, .end = 19 }, doc.cursor.selection());

    editor.mouseDown(1, 0, 1, false);
    try testing.expectEqual(@as(usize, 1), decorations.items.len);
    editor.mouseDrag(2, 1);
    try testing.expectEqual(Range{ .start = 1, .end = 10 }, doc.cursor.selection());
    // Below the last row: the view scrolls and the selection grows.
    editor.mouseDrag(2, 2);
    try testing.expectEqual(@as(usize, 1), editor.view().top.line);
    try testing.expectEqual(Range{ .start = 1, .end = 21 }, doc.cursor.selection());
}

test "status and title" {
    var editor = try testEditor("a\r\n\tb");
    defer editor.deinit();
    editor.doc().cursor.pos = 4;
    var status = editor.status();
    try testing.expectEqualStrings("untitled", status.name);
    try testing.expectEqualStrings("CRLF", status.line_ending);
    try testing.expectEqual(@as(usize, 2), status.line);
    try testing.expectEqual(@as(usize, 5), status.column);
    try testing.expect(!status.modified);

    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("untitled - 8-Bit", editor.title(&buffer));
    editor.typeText("x");
    status = editor.status();
    try testing.expect(status.modified);
    try testing.expectEqualStrings("\u{25CF} untitled - 8-Bit", editor.title(&buffer));
}

test "zoom stays between 1x and 4x" {
    var editor = try testEditor("");
    defer editor.deinit();
    editor.setZoom(0);
    try testing.expectEqual(@as(u8, 1), editor.zoom);
    editor.setZoom(99);
    try testing.expectEqual(@as(u8, 4), editor.zoom);
}

test "two panes of one file: each has its own cursor and both follow edits" {
    var editor = try testEditor("one\ntwo");
    defer editor.deinit();
    editor.doc().cursor.pos = 5;
    try editor.split(.right);
    try testing.expectEqual(@as(usize, 5), editor.doc().cursor.pos);
    editor.doc().cursor.pos = 0;
    editor.typeText(">> ");

    try editor.cyclePane(1);
    try testing.expectEqual(@as(usize, 8), editor.doc().cursor.pos);
    try expectText(&editor.doc().buffer, ">> one\ntwo");
    try editor.cyclePane(1);
    try testing.expectEqual(@as(usize, 3), editor.doc().cursor.pos);

    // Closing the only tab of a pane closes the pane.
    _ = editor.closeTab(0);
    try testing.expect(editor.root.kind == .pane);
    try testing.expectEqual(@as(usize, 1), editor.files.items.len);
}

test "focus and docks" {
    var editor = try testEditor("");
    defer editor.deinit();
    editor.focusArea(.bottom);
    try testing.expect(editor.bottom.shown);
    editor.toggleDock(.bottom);
    try testing.expect(!editor.bottom.shown);
    try testing.expectEqual(Area.editor, editor.focus);
}
