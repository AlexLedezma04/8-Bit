//! A whole window for end to end tests: editor, workbench and a recording
//! canvas, with a real folder on disk that is a git repository, and a real
//! shell for terminals. Driven by the events `main.zig` passes on.
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

/// The shell of terminals in tests: the same on every machine.
pub const shell = if (@import("builtin").os.tag == .windows) "cmd.exe" else "/bin/sh";

pub const Session = struct {
    tmp: testing.TmpDir,
    env: std.process.Environ.Map,
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
            .env = try testing.environ.createMap(testing.allocator),
            .editor = try .init(testing.allocator, testing.io),
            .mailbox = .{ .allocator = testing.allocator, .io = testing.io, .wake = noWake },
            .workbench = undefined,
            .recorder = .{ .allocator = testing.allocator },
        };
        // The folder is inside this project's repository; git must not see it.
        const tmp_root = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, ".zig-cache/tmp", testing.allocator);
        defer testing.allocator.free(tmp_root);
        try self.env.put("GIT_CEILING_DIRECTORIES", tmp_root);
        self.start();
        const folder = try std.fmt.bufPrint(&self.folder, ".zig-cache/tmp/{s}", .{self.tmp.sub_path});
        self.folder_len = folder.len;
        try self.write("b.txt", "bee\n");
        try self.write("a/x.txt", "ex\n");
        try self.git(&.{ "init", "-q", "-b", "main" });
        for ([_][2][]const u8{
            .{ "user.name", "Tester" },    .{ "user.email", "tester@example.com" }, .{ "commit.gpgsign", "false" },
            // Windows runners turn on autocrlf; tests expect files as written.
            .{ "core.autocrlf", "false" },
        }) |pair| {
            try self.git(&.{ "config", pair[0], pair[1] });
        }
        self.editor.openFolder(folder);
        self.draw();
    }

    fn start(self: *Session) void {
        self.editor.mailbox = &self.mailbox;
        self.editor.environ = &self.env;
        self.editor.settings.shell = shell;
        self.workbench.init(&self.editor);
    }

    /// Quits and starts again, as `main.zig` does without arguments: what
    /// the config folder remembers comes back.
    pub fn restart(self: *Session) !void {
        const dir = self.editor.loader.dir;
        self.workbench.deinit();
        self.editor.deinit();
        self.editor = try .init(testing.allocator, testing.io);
        self.editor.loader.dir = dir;
        self.editor.reloadConfig();
        self.editor.restore(true);
        self.start();
        self.draw();
    }

    pub fn folderPath(self: *const Session) []const u8 {
        return self.folder[0..self.folder_len];
    }

    /// Runs git in the folder, as the user would in a terminal.
    pub fn git(self: *Session, args: []const []const u8) !void {
        const output = try app.git.repo.run(testing.allocator, testing.io, "git", self.folderPath(), args);
        defer output.deinit(testing.allocator);
        if (!output.ok) {
            std.debug.print("git {s}: {s}\n", .{ args[0], output.stderr });
            return error.GitFailed;
        }
    }

    /// What git prints, trimmed. Free it.
    pub fn gitOutput(self: *Session, args: []const []const u8) ![]u8 {
        const output = try app.git.repo.run(testing.allocator, testing.io, "git", self.folderPath(), args);
        defer testing.allocator.free(output.stderr);
        defer testing.allocator.free(output.stdout);
        return testing.allocator.dupe(u8, std.mem.trim(u8, output.stdout, " \r\n"));
    }

    /// Lets git work as the main loop would: ticks the editor and takes what
    /// the git jobs post until none is left, then draws. Returns the last
    /// request an answer made.
    pub fn waitForGit(self: *Session) ?Request {
        var request: ?Request = null;
        while (true) {
            _ = self.editor.tick();
            if (self.editor.git.jobs.items.len == 0) break;
            const posted = self.mailbox.take() orelse {
                std.Thread.yield() catch {};
                continue;
            };
            if (self.editor.receive(posted)) |made| request = made;
        }
        self.draw();
        return request;
    }

    pub fn deinit(self: *Session) void {
        self.recorder.deinit();
        self.workbench.deinit();
        self.editor.deinit();
        self.mailbox.deinit();
        self.env.deinit();
        self.tmp.cleanup();
    }

    /// A file of the folder, named as the file tree names it: with the OS
    /// separator after the folder, so paths compare equal on Windows too.
    pub fn path(self: *Session, name: []const u8) []const u8 {
        const joined = std.fmt.bufPrint(&self.path_buffer, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ self.folder[0..self.folder_len], name }) catch unreachable;
        std.mem.replaceScalar(u8, joined[self.folder_len..], '/', std.fs.path.sep);
        return joined;
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

    pub fn rightClick(self: *Session, x: f32, y: f32) ?Request {
        const request = self.send(.{ .mouse_down = .{ .x = x, .y = y, .button = .right, .clicks = 1, .mods = .{} } });
        _ = self.send(.{ .mouse_up = .{ .x = x, .y = y, .button = .right } });
        return request;
    }

    /// Right-clicks the middle of a text on screen.
    pub fn rightClickText(self: *Session, part: []const u8) ?Request {
        const found = self.recorder.find(part) orelse std.debug.panic("not on screen: {s}", .{part});
        return self.rightClick(found.x + 4, found.y + 8);
    }

    /// The last text drawn that is exactly `text`: the menu is drawn last.
    pub fn last(self: *const Session, text: []const u8) ?Recorder.Text {
        var i = self.recorder.texts.items.len;
        while (i > 0) : (i -= 1) {
            const item = self.recorder.texts.items[i - 1];
            if (std.mem.eql(u8, item.text, text)) return item;
        }
        return null;
    }

    /// Clicks an item of the open menu.
    pub fn clickMenu(self: *Session, label: []const u8) ?Request {
        const found = self.last(label) orelse std.debug.panic("no menu item: {s}", .{label});
        return self.click(found.x + 4, found.y + 8);
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

    /// Text drawn in the status bar, the last row of the window.
    pub fn inStatusBar(self: *const Session, part: []const u8) bool {
        const bottom = self.workbench.height - app.ui.layout.Metrics.init(1).item();
        for (self.recorder.texts.items) |item| {
            if (item.y >= bottom and std.mem.indexOf(u8, item.text, part) != null) return true;
        }
        return false;
    }

    /// The line and column of the cursor, one-based.
    pub fn cursor(self: *const Session) [2]usize {
        const doc = self.editor.doc();
        return .{ doc.buffer.lineOf(doc.cursor.pos) + 1, doc.columnOf(doc.cursor.pos) + 1 };
    }

    /// Takes what the shells of terminals write until `part` is on screen.
    /// Fails after 10 seconds, showing what is on screen.
    pub fn waitForTerminal(self: *Session, part: []const u8) !void {
        const clock: std.Io.Clock = .awake;
        const deadline = clock.now(testing.io).addDuration(.fromMilliseconds(10_000));
        while (!self.shows(part)) {
            if (clock.now(testing.io).nanoseconds > deadline.nanoseconds) {
                for (self.recorder.texts.items) |item| std.debug.print("{d}: {s}\n", .{ item.y, item.text });
                std.debug.print("not on screen: {s}\n", .{part});
                return error.Timeout;
            }
            const posted = self.mailbox.take() orelse {
                std.Thread.yield() catch {};
                continue;
            };
            _ = self.editor.receive(posted);
            self.draw();
        }
    }
};

fn noWake() void {}
