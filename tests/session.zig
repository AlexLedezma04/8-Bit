//! A whole window for end to end tests: editor, workbench and a recording
//! canvas, with a real folder on disk. Driven by the events `main.zig` passes on.
const std = @import("std");
const app = @import("8-bit");

const testing = std.testing;
const Editor = app.editor.editor.Editor;
const Request = app.editor.editor.Request;
const Mailbox = app.editor.editor.Mailbox;
const Workbench = app.ui.workbench.Workbench;
const Recorder = app.ui.canvas.Recorder;
const keymap = app.editor.keymap;
const fs = app.platform.fs;

pub const Session = struct {
    tmp: testing.TmpDir,
    editor: Editor,
    mailbox: Mailbox,
    workbench: Workbench,
    recorder: Recorder,
    folder: [128]u8 = undefined,
    folder_len: usize = 0,
    path_buffer: [192]u8 = undefined,

    /// A window of 800x600 with a folder open.
    pub fn init(self: *Session) !void {
        self.* = .{
            .tmp = testing.tmpDir(.{}),
            .editor = try .init(testing.allocator, testing.io),
            .mailbox = .{ .allocator = testing.allocator, .io = testing.io, .wake = noWake },
            .workbench = undefined,
            .recorder = .{ .allocator = testing.allocator },
        };
        self.editor.mailbox = &self.mailbox;
        self.workbench.init(&self.editor);
        const folder = try std.fmt.bufPrint(&self.folder, ".zig-cache/tmp/{s}", .{self.tmp.sub_path});
        self.folder_len = folder.len;
        try self.write("b.txt", "bee\n");
        try self.write("a/x.txt", "ex\n");
        try self.write(".git/HEAD", "");
        self.editor.openFolder(folder);
        self.draw();
    }

    pub fn deinit(self: *Session) void {
        self.recorder.deinit();
        self.workbench.deinit();
        self.editor.deinit();
        self.mailbox.deinit();
        self.tmp.cleanup();
    }

    pub fn path(self: *Session, name: []const u8) []const u8 {
        return std.fmt.bufPrint(&self.path_buffer, "{s}/{s}", .{ self.folder[0..self.folder_len], name }) catch unreachable;
    }

    pub fn write(self: *Session, name: []const u8, text: []const u8) !void {
        try fs.write(testing.io, self.path(name), &.{text});
    }

    pub fn draw(self: *Session) void {
        self.recorder.clear();
        self.workbench.draw(self.recorder.canvas());
    }

    pub fn send(self: *Session, ev: app.platform.event.Event) ?Request {
        const outcome = self.workbench.handle(ev);
        self.draw();
        return outcome.request;
    }

    pub fn press(self: *Session, combo: []const u8) ?Request {
        const parsed = keymap.parseKey(combo).?;
        return self.send(.{ .key = parsed });
    }

    /// A key that also types text, as SDL sends it.
    pub fn typeKeys(self: *Session, text: []const u8) void {
        for (text) |char| {
            _ = self.send(.{ .key = .{ .key = .char(std.ascii.toLower(char)) } });
            _ = self.send(.{ .text = &.{char} });
        }
    }

    pub fn click(self: *Session, x: f32, y: f32) ?Request {
        const request = self.send(.{ .mouse_down = .{ .x = x, .y = y, .button = .left, .clicks = 1, .mods = .{} } });
        _ = self.send(.{ .mouse_up = .{ .x = x, .y = y, .button = .left } });
        return request;
    }

    /// Clicks the middle of a text on screen.
    pub fn clickText(self: *Session, part: []const u8) ?Request {
        const found = self.recorder.find(part) orelse std.debug.panic("not on screen: {s}", .{part});
        return self.click(found.x + 4, found.y + 8);
    }

    pub fn drag(self: *Session, from_x: f32, from_y: f32, to_x: f32, to_y: f32) void {
        _ = self.send(.{ .mouse_down = .{ .x = from_x, .y = from_y, .button = .left, .clicks = 1, .mods = .{} } });
        _ = self.send(.{ .mouse_move = .{ .x = to_x, .y = to_y, .left_down = true } });
        _ = self.send(.{ .mouse_up = .{ .x = to_x, .y = to_y, .button = .left } });
    }

    pub fn shows(self: *const Session, part: []const u8) bool {
        return self.recorder.find(part) != null;
    }

    /// Takes what find in project posts until it is done, then draws.
    pub fn waitForSearch(self: *Session) void {
        app.editor.project_search.waitForTest(&self.editor.project, &self.mailbox);
        self.draw();
    }
};

fn noWake() void {}
