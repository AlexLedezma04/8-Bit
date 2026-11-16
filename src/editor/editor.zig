//! Top-level editor state: the open document, its file, the view and the
//! status message. No SDL here: what only the platform can do is returned
//! as a `Request` for `main.zig` to carry out.
const std = @import("std");
const Document = @import("../core/edit.zig").Document;
const Range = @import("../core/buffer.zig").Range;
const View = @import("view.zig").View;
const Decoration = @import("decoration.zig").Decoration;
const fs = @import("../platform/fs.zig");
const config = @import("config.zig");
const keymap = @import("keymap.zig");

pub const Pick = enum { open_file, save_file, open_folder };

pub const Request = union(enum) {
    quit,
    /// Put this text on the clipboard. Valid until the next command.
    copy: [:0]const u8,
    /// Call `paste` with the clipboard text.
    paste,
    /// Show a native dialog. Its result comes back through `receive`.
    pick: Pick,
    /// Ask Save / Don't save / Cancel, then call `answer`.
    confirm,
};

pub const Choice = enum { save, discard, cancel };

/// Result of background work, sent to the main loop through a mailbox.
/// The main thread passes it to `receive`, which frees it.
pub const Posted = union(enum) {
    /// A dialog was confirmed. `path` is allocated with the editor's allocator.
    picked: struct { pick: Pick, path: []u8 },
    cancelled,
    /// No native dialog could be shown.
    dialog_failed,
};

/// What the status bar shows.
pub const Status = struct {
    name: []const u8,
    modified: bool,
    /// One-based.
    line: usize,
    column: usize,
    line_ending: []const u8,
    message: ?[]const u8,
};

pub const Editor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    doc: Document,
    view: View = .{},
    /// File of the document; null until it is saved for the first time.
    path: ?[]u8 = null,
    folder: ?[]u8 = null,
    /// Screen pixels per font pixel.
    zoom: u8 = 1,
    default_zoom: u8 = 1,
    /// The zoom that matches the screen, used when the setting is 0.
    screen_zoom: u8 = 1,
    loader: config.Loader,
    settings: config.Settings = undefined,
    bindings: []const keymap.Binding = &keymap.default,
    /// Holds the settings and bindings until the next `reloadConfig`.
    config_arena: std.heap.ArenaAllocator,
    /// Goes up on every `reloadConfig`, so the UI knows to load the theme again.
    config_version: u32 = 0,
    /// Current time. The main loop sets it before it passes on input.
    now_ms: u64 = 0,
    message: [160]u8 = undefined,
    message_len: usize = 0,
    message_until_ms: u64 = 0,
    /// Waits for the user to save or discard unsaved changes.
    pending: ?Pending = null,
    /// Sorted by position. The view draws them.
    decorations: std.ArrayList(Decoration) = .empty,
    clipboard: std.ArrayList(u8) = .empty,

    pub const min_zoom = 1;
    pub const max_zoom = 4;
    const message_ms = 4000;
    const untitled = "untitled";

    const Pending = union(enum) { quit, open: []u8 };

    /// Starts with the built-in settings. Set `loader.dir` and call
    /// `reloadConfig` to use the user's files.
    pub fn init(allocator: std.mem.Allocator, io: std.Io) Editor {
        var editor: Editor = .{
            .allocator = allocator,
            .io = io,
            .doc = .init(allocator),
            .loader = .{ .io = io, .gpa = allocator },
            .config_arena = .init(allocator),
        };
        editor.reloadConfig();
        return editor;
    }

    pub fn deinit(self: *Editor) void {
        self.dropPending();
        if (self.path) |path| self.allocator.free(path);
        if (self.folder) |folder| self.allocator.free(folder);
        self.decorations.deinit(self.allocator);
        self.clipboard.deinit(self.allocator);
        self.doc.deinit();
        self.config_arena.deinit();
    }

    // Messages

    /// Shows a short message in the status bar for a few seconds. Every
    /// feature reports errors and info through here.
    pub fn notify(self: *Editor, comptime format: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.message, format, args) catch &self.message;
        self.message_len = text.len;
        self.message_until_ms = self.now_ms + message_ms;
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
        self.doc.insert(text) catch |err| self.notify("Could not insert: {t}", .{err});
        self.afterEdit();
    }

    /// Clipboard text arrives after a `paste` request.
    pub fn paste(self: *Editor, text: []const u8) void {
        self.doc.paste(text) catch |err| self.notify("Could not paste: {t}", .{err});
        self.afterEdit();
    }

    /// A click on a cell of the text area. Two clicks select a word, three a line.
    pub fn mouseDown(self: *Editor, cell_x: isize, cell_y: isize, clicks: u8, extend: bool) void {
        const pos = self.view.posAt(&self.doc, cell_x, cell_y);
        switch (clicks) {
            0, 1 => self.doc.cursor.moveTo(pos, extend),
            2 => self.doc.selectWord(pos),
            else => self.doc.selectLine(pos),
        }
        self.refreshDecorations();
    }

    /// The mouse moved with the button down. Past an edge, the view scrolls.
    pub fn mouseDrag(self: *Editor, cell_x: isize, cell_y: isize) void {
        const rows: isize = @intCast(self.view.rows);
        const cols: isize = @intCast(self.view.cols);
        self.view.scrollBy(&self.doc, edgeStep(cell_y, rows), edgeStep(cell_x, cols));
        self.doc.cursor.moveTo(self.view.posAt(&self.doc, cell_x, cell_y), true);
        self.refreshDecorations();
    }

    fn edgeStep(cell: isize, size: isize) isize {
        return if (cell < 0) -1 else if (cell >= size) 1 else 0;
    }

    pub fn scroll(self: *Editor, rows: isize, cols: isize) void {
        self.view.scrollBy(&self.doc, rows, cols);
    }

    /// Call after anything that moved the cursor or changed the text.
    pub fn afterEdit(self: *Editor) void {
        self.view.scrollToCursor(&self.doc);
        self.refreshDecorations();
    }

    /// The cursor line, and the selection, sorted by start.
    fn refreshDecorations(self: *Editor) void {
        self.decorations.clearRetainingCapacity();
        const doc = &self.doc;
        const start = doc.buffer.lineStart(doc.buffer.lineOf(doc.cursor.pos));
        const selection = doc.cursor.selection();
        const marks = [_]Decoration{
            .{ .range = selection, .kind = .{ .text_background = .selection } },
            .{ .range = .{ .start = start, .end = start }, .kind = .{ .line_background = .current_line } },
        };
        const swapped = [_]Decoration{ marks[1], marks[0] };
        const order: []const Decoration = if (selection.len() == 0) marks[1..] else if (selection.start < start) &marks else &swapped;
        self.decorations.appendSlice(self.allocator, order) catch {};
    }

    // Clipboard

    /// The selection, or the whole line when nothing is selected.
    fn clipboardRange(self: *const Editor) Range {
        const selection = self.doc.cursor.selection();
        if (selection.len() > 0) return selection;
        return self.doc.lineRange(self.doc.buffer.lineOf(self.doc.cursor.pos));
    }

    pub fn copy(self: *Editor) !Request {
        const range = self.clipboardRange();
        self.clipboard.clearRetainingCapacity();
        const text = try self.clipboard.addManyAsSlice(self.allocator, range.len() + 1);
        _ = self.doc.buffer.copy(range.start, text[0..range.len()]);
        text[range.len()] = 0;
        return .{ .copy = text[0..range.len() :0] };
    }

    pub fn cut(self: *Editor) !Request {
        const request = try self.copy();
        try self.doc.replace(self.clipboardRange(), "");
        return request;
    }

    // Files

    pub fn isModified(self: *const Editor) bool {
        return self.doc.history.isModified();
    }

    pub fn name(self: *const Editor) []const u8 {
        return if (self.path) |path| std.fs.path.basename(path) else untitled;
    }

    /// Opens `path`, after asking about unsaved changes.
    pub fn open(self: *Editor, path: []const u8) ?Request {
        const owned = self.allocator.dupe(u8, path) catch return null;
        return self.guard(.{ .open = owned });
    }

    pub fn quit(self: *Editor) ?Request {
        return self.guard(.quit);
    }

    /// Saves to the document's file, or asks for one if it has none.
    pub fn save(self: *Editor) ?Request {
        const path = self.path orelse return .{ .pick = .save_file };
        fs.write(self.io, path, &self.doc.buffer.halves()) catch |err| {
            self.notify("Could not save {s}: {t}", .{ self.name(), err });
            self.dropPending();
            return null;
        };
        self.doc.history.markSaved();
        self.notify("Saved {s}", .{self.name()});
        if (self.loader.dir) |dir| {
            const inside = path.len > dir.len and std.mem.startsWith(u8, path, dir) and std.fs.path.isSep(path[dir.len]);
            if (inside) self.reloadConfig();
        }
        const action = self.pending orelse return null;
        self.pending = null;
        return self.perform(action);
    }

    /// The answer to a `confirm` request.
    pub fn answer(self: *Editor, choice: Choice) ?Request {
        const action = self.pending orelse return null;
        switch (choice) {
            .cancel => self.dropPending(),
            .save => return self.save(),
            .discard => {
                self.pending = null;
                return self.perform(action);
            },
        }
        return null;
    }

    /// Takes a result from the mailbox and frees it.
    pub fn receive(self: *Editor, posted: Posted) ?Request {
        switch (posted) {
            .cancelled => self.dropPending(),
            .dialog_failed => {
                self.dropPending();
                self.notify("No file dialog: install zenity", .{});
            },
            .picked => |picked| switch (picked.pick) {
                .open_file => {
                    defer self.allocator.free(picked.path);
                    return self.open(picked.path);
                },
                .save_file => {
                    self.setPath(picked.path);
                    return self.save();
                },
                .open_folder => {
                    if (self.folder) |old| self.allocator.free(old);
                    self.folder = picked.path;
                    self.notify("Folder: {s}", .{picked.path});
                },
            },
        }
        return null;
    }

    /// Does `action` now, or first asks what to do with unsaved changes.
    fn guard(self: *Editor, action: Pending) ?Request {
        if (!self.isModified()) return self.perform(action);
        self.dropPending();
        self.pending = action;
        return .confirm;
    }

    fn perform(self: *Editor, action: Pending) ?Request {
        switch (action) {
            .quit => return .quit,
            .open => |path| self.load(path),
        }
        return null;
    }

    fn dropPending(self: *Editor) void {
        if (self.pending) |action| switch (action) {
            .open => |path| self.allocator.free(path),
            .quit => {},
        };
        self.pending = null;
    }

    /// Takes ownership of `path`.
    fn setPath(self: *Editor, path: []u8) void {
        if (self.path) |old| self.allocator.free(old);
        self.path = path;
    }

    /// Replaces the document with the file at `path`. A file that does not
    /// exist yet opens as an empty document that will be saved there.
    fn load(self: *Editor, path: []u8) void {
        const text = fs.read(self.io, self.allocator, path) catch |err| switch (err) {
            error.FileNotFound => self.allocator.dupeSentinel(u8, "", 0) catch return,
            else => {
                self.notify("Could not open {s}: {t}", .{ std.fs.path.basename(path), err });
                self.allocator.free(path);
                return;
            },
        };
        defer self.allocator.free(text);
        self.doc.load(text) catch |err| {
            self.notify("Could not open {s}: {t}", .{ std.fs.path.basename(path), err });
            self.allocator.free(path);
            return;
        };
        self.setPath(path);
        self.view.top = .{};
        self.view.left = 0;
        self.afterEdit();
    }

    // Config

    /// Loads the settings and key bindings again and applies them.
    pub fn reloadConfig(self: *Editor) void {
        _ = self.config_arena.reset(.retain_capacity);
        const arena = self.config_arena.allocator();
        const base = config.builtin(config.Settings, self.allocator, arena, "settings");
        const settings = self.loader.load(config.Settings, arena, "settings", base, self);
        self.settings = settings;
        self.doc.tab_width = std.math.clamp(settings.tab_width, 1, Document.max_tab_width);
        self.doc.soft_tabs = settings.use_spaces;
        self.doc.history.max_size = @as(usize, settings.undo_limit_mb) << 20;
        self.view.setWrap(settings.wrap);
        self.setZoom(if (settings.zoom == 0) self.screen_zoom else settings.zoom);
        self.default_zoom = self.zoom;
        const entries = self.loader.load([]const keymap.Entry, arena, "keymap", &.{}, self);
        self.bindings = keymap.withUser(arena, entries, self) catch &keymap.default;
        self.config_version +%= 1;
    }

    /// Opens the user's settings file, made from the built-in one if missing.
    pub fn openSettings(self: *Editor) !?Request {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = self.loader.path(&buffer, "settings") orelse {
            self.notify("No config folder", .{});
            return null;
        };
        if (fs.read(self.io, self.allocator, path)) |text| self.allocator.free(text) else |err| switch (err) {
            error.FileNotFound => try fs.write(self.io, path, &.{self.loader.source(self.allocator, "settings", self).?}),
            else => return err,
        }
        return self.open(path);
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
        const pos = self.doc.cursor.pos;
        return .{
            .name = self.name(),
            .modified = self.isModified(),
            .line = self.doc.buffer.lineOf(pos) + 1,
            .column = self.doc.columnOf(pos) + 1,
            .line_ending = self.doc.line_ending.name(),
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

fn testEditor(text: []const u8) !Editor {
    var editor = Editor.init(testing.allocator, testing.io);
    errdefer editor.deinit();
    try editor.doc.load(text);
    return editor;
}

test "notify shows a message until its time is over" {
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
    editor.doc.cursor.pos = 5;
    try testing.expectEqualStrings("two\n", (try editor.copy()).copy);

    editor.doc.cursor = .{ .anchor = 1, .pos = 6 };
    try testing.expectEqualStrings("ne\ntw", (try editor.cut()).copy);
    try testing.expectEqual(@as(usize, 8), editor.doc.buffer.len());

    editor.doc.cursor = .{ .pos = 7 };
    try testing.expectEqualStrings("three", (try editor.cut()).copy);
    try testing.expectEqual(@as(usize, 3), editor.doc.buffer.len());
    try testing.expect(try editor.doc.undo());
    try testing.expectEqual(@as(usize, 8), editor.doc.buffer.len());
}

test "mouse: click, shift+click, double and triple click, drag" {
    var editor = try testEditor("one two\nthree four\nfive");
    defer editor.deinit();
    editor.view = .{ .cols = 20, .rows = 2 };

    editor.mouseDown(2, 0, 1, false);
    try testing.expectEqual(@as(usize, 2), editor.doc.cursor.pos);
    editor.mouseDown(3, 1, 1, true);
    try testing.expectEqual(Range{ .start = 2, .end = 11 }, editor.doc.cursor.selection());
    try testing.expectEqual(@as(usize, 2), editor.decorations.items.len);

    editor.mouseDown(5, 0, 2, false);
    try testing.expectEqual(Range{ .start = 4, .end = 7 }, editor.doc.cursor.selection());
    editor.mouseDown(5, 1, 3, false);
    try testing.expectEqual(Range{ .start = 8, .end = 19 }, editor.doc.cursor.selection());

    editor.mouseDown(1, 0, 1, false);
    try testing.expectEqual(@as(usize, 1), editor.decorations.items.len);
    editor.mouseDrag(2, 1);
    try testing.expectEqual(Range{ .start = 1, .end = 10 }, editor.doc.cursor.selection());
    // Below the last row: the view scrolls and the selection grows.
    editor.mouseDrag(2, 2);
    try testing.expectEqual(@as(usize, 1), editor.view.top.line);
    try testing.expectEqual(Range{ .start = 1, .end = 21 }, editor.doc.cursor.selection());
}

test "status and title" {
    var editor = try testEditor("a\r\n\tb");
    defer editor.deinit();
    editor.doc.cursor.pos = 4;
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
