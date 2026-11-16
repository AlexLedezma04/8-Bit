//! End to end without SDL: whole editing sessions through the same calls
//! `main.zig` makes (commands, typed text, dialog results), with real files.
const std = @import("std");
const app = @import("8-bit");

const testing = std.testing;
const Editor = app.editor.editor.Editor;
const Request = app.editor.editor.Request;
const run = app.editor.commands.run;
const keymap = app.editor.keymap;
const fs = app.platform.fs;
const expectText = app.core.buffer.expectText;

/// A temporary folder with an editor, and helpers that play the part of main.
const Session = struct {
    tmp: testing.TmpDir,
    editor: Editor,
    path_buffer: [160]u8 = undefined,

    fn init() !Session {
        return .{ .tmp = testing.tmpDir(.{}), .editor = try .init(testing.allocator, testing.io) };
    }

    fn deinit(self: *Session) void {
        self.editor.deinit();
        self.tmp.cleanup();
    }

    fn path(self: *Session, name: []const u8) []const u8 {
        return std.fmt.bufPrint(&self.path_buffer, ".zig-cache/tmp/{s}/{s}", .{ self.tmp.sub_path, name }) catch unreachable;
    }

    fn write(self: *Session, name: []const u8, text: []const u8) !void {
        try fs.write(testing.io, self.path(name), &.{text});
    }

    fn expectFile(self: *Session, name: []const u8, expected: []const u8) !void {
        const text = try fs.read(testing.io, testing.allocator, self.path(name));
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(expected, text);
    }

    /// A key press, looked up in the default key bindings.
    fn press(self: *Session, key: app.platform.event.Key, mods: app.platform.event.Mods) ?Request {
        return run(&self.editor, keymap.lookup(&keymap.default, key, mods).?);
    }

    /// A native dialog was confirmed with this file.
    fn pick(self: *Session, kind: app.editor.editor.Pick, name: []const u8) !?Request {
        const picked = try testing.allocator.dupe(u8, self.path(name));
        return self.editor.receive(.{ .picked = .{ .pick = kind, .path = picked } });
    }
};

const ctrl: app.platform.event.Mods = .{ .ctrl = true };

fn expectAsk(question: app.editor.editor.Question, name: []const u8, request: ?Request) !void {
    try testing.expectEqual(question, request.?.ask.question);
    try testing.expectEqualStrings(name, request.?.ask.name);
}

test "open a file, edit it with keys, save it, and the bytes on disk are right" {
    var session = try Session.init();
    defer session.deinit();
    const editor = &session.editor;
    // CRLF line endings and no final newline: both must survive.
    try session.write("main.zig", "fn main() void {\r\n}");

    editor.open(session.path("main.zig"));
    try testing.expectEqualStrings("main.zig", editor.status().name);
    try testing.expectEqualStrings("CRLF", editor.status().line_ending);
    try testing.expect(!editor.isModified());

    _ = session.press(.end, .{});
    _ = session.press(.enter, .{});
    _ = session.press(.tab, .{});
    editor.typeText("return;");
    try testing.expect(editor.isModified());
    try testing.expectEqual(@as(usize, 2), editor.status().line);
    try testing.expectEqual(@as(usize, 12), editor.status().column);

    try testing.expectEqual(@as(?Request, null), session.press(.char('s'), ctrl));
    try testing.expect(!editor.isModified());
    try testing.expectEqualStrings("Saved main.zig", editor.currentMessage().?);
    try session.expectFile("main.zig", "fn main() void {\r\n    return;\r\n}");
}

test "the unsaved flag follows undo and redo around the saved state" {
    var session = try Session.init();
    defer session.deinit();
    const editor = &session.editor;
    try session.write("a.txt", "one");
    editor.open(session.path("a.txt"));

    editor.typeText("x");
    _ = session.press(.char('s'), ctrl);
    editor.typeText("y");
    try testing.expect(editor.isModified());
    _ = session.press(.char('z'), ctrl);
    try testing.expect(!editor.isModified());
    _ = session.press(.char('z'), ctrl);
    try testing.expect(editor.isModified());
    _ = session.press(.char('y'), ctrl);
    try testing.expect(!editor.isModified());
}

test "quit with unsaved changes asks, and each answer does its job" {
    var session = try Session.init();
    defer session.deinit();
    const editor = &session.editor;
    try session.write("a.txt", "one");
    editor.open(session.path("a.txt"));
    try testing.expectEqual(Request.quit, session.press(.char('q'), ctrl).?);

    editor.typeText("1");
    try expectAsk(.save, "a.txt", session.press(.char('q'), ctrl));
    try testing.expectEqual(@as(?Request, null), editor.answer(.cancel));
    try testing.expect(editor.isModified());
    try session.expectFile("a.txt", "one");

    try expectAsk(.save, "a.txt", session.press(.char('q'), ctrl));
    try testing.expectEqual(Request.quit, editor.answer(.no).?);
    try session.expectFile("a.txt", "one");

    try expectAsk(.save, "a.txt", session.press(.char('q'), ctrl));
    try testing.expectEqual(Request.quit, editor.answer(.yes).?);
    try session.expectFile("a.txt", "1one");
}

test "a new document is saved through the save dialog, also on the way out" {
    var session = try Session.init();
    defer session.deinit();
    const editor = &session.editor;
    editor.typeText("hello");
    try testing.expectEqualStrings("untitled", editor.status().name);

    // Quit -> Save -> no file yet -> save dialog -> file picked -> saved -> quit.
    try expectAsk(.save, "untitled", session.press(.char('q'), ctrl));
    try testing.expectEqual(Request{ .pick = .save_file }, editor.answer(.yes).?);
    try testing.expectEqual(Request.quit, (try session.pick(.save_file, "new.txt")).?);
    try session.expectFile("new.txt", "hello");
    try testing.expectEqualStrings("new.txt", editor.status().name);
}

test "cancelling the save dialog cancels the quit" {
    var session = try Session.init();
    defer session.deinit();
    const editor = &session.editor;
    editor.typeText("hello");
    _ = session.press(.char('q'), ctrl);
    _ = editor.answer(.yes);
    try testing.expectEqual(@as(?Request, null), editor.receive(.cancelled));
    try testing.expect(editor.isModified());
    // The next save is a plain save again, not the end of a quit.
    try testing.expectEqual(Request{ .pick = .save_file }, session.press(.char('s'), ctrl).?);
    try testing.expectEqual(@as(?Request, null), try session.pick(.save_file, "kept.txt"));
    try session.expectFile("kept.txt", "hello");
}

test "many files: open in tabs, switch to an open one, close with a question" {
    var session = try Session.init();
    defer session.deinit();
    const editor = &session.editor;
    try session.write("a.txt", "aaa");
    try session.write("b.txt", "bbb\n");
    // The blank untitled tab is replaced by the first file.
    editor.open(session.path("a.txt"));
    editor.typeText("x");

    try testing.expectEqual(Request{ .pick = .open_file }, session.press(.char('o'), ctrl).?);
    try testing.expectEqual(@as(?Request, null), try session.pick(.open_file, "b.txt"));
    try expectText(&editor.doc().buffer, "bbb\n");
    try testing.expectEqual(@as(usize, 2), editor.pane.pane().tabs.items.len);
    try testing.expectEqual(@as(usize, 2), editor.files.items.len);

    // Already open: switch to it. Its cursor and changes are still there.
    editor.open(session.path("a.txt"));
    try testing.expectEqualStrings("a.txt", editor.status().name);
    try testing.expectEqual(@as(usize, 1), editor.doc().cursor.pos);
    try testing.expectEqual(@as(usize, 2), editor.files.items.len);

    try expectAsk(.save, "a.txt", session.press(.char('w'), ctrl));
    try testing.expectEqual(@as(?Request, null), editor.answer(.no));
    try testing.expectEqualStrings("b.txt", editor.status().name);
    try testing.expectEqual(@as(usize, 1), editor.files.items.len);
    try session.expectFile("a.txt", "aaa");

    // Closing the last tab leaves an empty file.
    _ = session.press(.char('w'), ctrl);
    try testing.expectEqualStrings("untitled", editor.status().name);
    try testing.expectEqual(@as(usize, 1), editor.files.items.len);
}

test "a file changed on disk reloads quietly, or asks when it has unsaved changes" {
    var session = try Session.init();
    defer session.deinit();
    const editor = &session.editor;
    try session.write("a.txt", "one\ntwo\n");
    editor.open(session.path("a.txt"));
    editor.doc().cursor.pos = 4;
    try testing.expectEqual(@as(?Request, null), editor.checkDisk());

    try session.write("a.txt", "one\nTWO\nthree\n");
    editor.file().disk_time = 1;
    try testing.expectEqual(@as(?Request, null), editor.checkDisk());
    try expectText(&editor.doc().buffer, "one\nTWO\nthree\n");
    try testing.expectEqual(@as(usize, 4), editor.doc().cursor.pos);
    try testing.expect(!editor.isModified());

    editor.typeText("mine ");
    try session.write("a.txt", "theirs\n");
    editor.file().disk_time = 1;
    try expectAsk(.reload, "a.txt", editor.checkDisk());
    try testing.expectEqual(@as(?Request, null), editor.answer(.no));
    try expectText(&editor.doc().buffer, "one\nmine TWO\nthree\n");
    // Kept: not asked again until the file changes again.
    try testing.expectEqual(@as(?Request, null), editor.checkDisk());

    editor.file().disk_time = 1;
    try expectAsk(.reload, "a.txt", editor.checkDisk());
    try testing.expectEqual(@as(?Request, null), editor.answer(.yes));
    try expectText(&editor.doc().buffer, "theirs\n");
}

test "a file that does not exist opens empty and is created by save" {
    var session = try Session.init();
    defer session.deinit();
    const editor = &session.editor;
    editor.open(session.path("fresh.txt"));
    try testing.expectEqualStrings("fresh.txt", editor.status().name);
    editor.typeText("first");
    _ = session.press(.char('s'), ctrl);
    try session.expectFile("fresh.txt", "first");
}

test "errors are reported with notify" {
    var session = try Session.init();
    defer session.deinit();
    const editor = &session.editor;
    // A folder cannot be opened as a file.
    editor.open(session.path(""));
    try testing.expect(std.mem.startsWith(u8, editor.currentMessage().?, "Could not open"));
    try testing.expectEqualStrings("untitled", editor.status().name);

    _ = editor.receive(.dialog_failed);
    try testing.expectEqualStrings("No file dialog: install zenity", editor.currentMessage().?);

    // Saving under a file, as if it were a folder, fails and keeps the changes.
    try session.write("plain.txt", "");
    editor.typeText("x");
    _ = try session.pick(.save_file, "plain.txt/file.txt");
    try testing.expect(std.mem.startsWith(u8, editor.currentMessage().?, "Could not save"));
    try testing.expect(editor.isModified());
}

test "copy, cut and paste go through clipboard requests" {
    var session = try Session.init();
    defer session.deinit();
    const editor = &session.editor;
    try session.write("a.txt", "one\r\ntwo\r\n");
    editor.open(session.path("a.txt"));

    // No selection: the whole line.
    const copied = session.press(.char('c'), ctrl).?.copy;
    try testing.expectEqualStrings("one\r\n", copied);
    try testing.expectEqual(Request.paste, session.press(.char('v'), ctrl).?);
    // Text from another program, with LF endings: changed to match the file.
    editor.paste("x\ny\n");
    try expectText(&editor.doc().buffer, "x\r\ny\r\none\r\ntwo\r\n");

    _ = session.press(.char('a'), ctrl);
    try testing.expectEqualStrings("x\r\ny\r\none\r\ntwo\r\n", session.press(.char('x'), ctrl).?.copy);
    try expectText(&editor.doc().buffer, "");
    // Paste and cut are one undo step each.
    _ = session.press(.char('z'), ctrl);
    _ = session.press(.char('z'), ctrl);
    try expectText(&editor.doc().buffer, "one\r\ntwo\r\n");
    try testing.expect(!editor.isModified());
}

test "a big file: only the lines on screen are touched when moving around" {
    var session = try Session.init();
    defer session.deinit();
    const editor = &session.editor;
    const line_count = 200_000;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..line_count) |n| try text.print(testing.allocator, "line {d}\n", .{n});
    try editor.doc().load(text.items);
    editor.view().* = .{ .cols = 80, .rows = 40 };

    _ = session.press(.end, ctrl);
    try testing.expectEqual(@as(usize, line_count + 1), editor.status().line);
    // The cursor keeps its margin of two rows above the bottom edge.
    try testing.expectEqual(@as(usize, line_count - 37), editor.view().top.line);
    _ = run(editor, .toggle_wrap);
    _ = session.press(.page_up, .{});
    _ = session.press(.home, ctrl);
    try testing.expectEqual(@as(usize, 0), editor.view().top.line);
}
