//! End to end: opening and remembering folders, the welcome screen, the
//! right-click menus, the status bar and the sidebar.
const std = @import("std");
const app = @import("8-bit");
const Session = @import("session.zig").Session;

const testing = std.testing;
const fs = app.platform.fs;
const Request = app.editor.editor.Request;
const Area = app.editor.editor.Area;

/// A session whose config folder is a temporary one, so state is kept.
fn withConfig(session: *Session, config: *testing.TmpDir, buffer: []u8) !void {
    try session.init();
    config.* = testing.tmpDir(.{});
    session.editor.loader.dir = try std.fmt.bufPrint(buffer, ".zig-cache/tmp/{s}", .{config.sub_path});
}

fn picked(session: *Session, pick: app.editor.editor.Pick, path: []const u8) void {
    _ = session.editor.receive(.{ .picked = .{ .pick = pick, .path = testing.allocator.dupe(u8, path) catch unreachable } });
    session.draw();
}

test "open a folder or a file; the open folder comes back on the next start, a closed one does not" {
    var session: Session = undefined;
    var config: testing.TmpDir = undefined;
    var buffer: [128]u8 = undefined;
    try withConfig(&session, &config, &buffer);
    defer config.cleanup();
    defer session.deinit();
    const editor = &session.editor;

    try testing.expectEqual(Request{ .pick = .open_folder }, session.press("ctrl+shift+o").?);
    try testing.expectEqual(Request{ .pick = .open_file }, session.press("ctrl+o").?);
    picked(&session, .open_folder, session.path("a"));
    try testing.expect(session.shows("x.txt"));
    picked(&session, .open_file, session.path("b.txt"));
    try testing.expectEqualStrings("b.txt", editor.name());

    try session.restart();
    try testing.expect(std.mem.endsWith(u8, session.editor.folder.?, "a"));
    try testing.expect(session.shows("x.txt"));

    _ = session.press("ctrl+shift+w");
    try testing.expectEqual(@as(?[]u8, null), session.editor.folder);
    try session.restart();
    try testing.expectEqual(@as(?[]u8, null), session.editor.folder);
    try testing.expect(session.shows("Recent folders"));
}

test "welcome: recent folders newest first, click opens, x and Delete remove, kept between runs" {
    var session: Session = undefined;
    var config: testing.TmpDir = undefined;
    var buffer: [128]u8 = undefined;
    try withConfig(&session, &config, &buffer);
    defer config.cleanup();
    defer session.deinit();

    session.editor.openFolder(session.folderPath());
    session.editor.openFolder(session.path("a"));
    session.editor.closeFolder();
    session.draw();
    try testing.expect(session.shows("Open Folder..."));
    try testing.expect(session.shows("Ctrl+Shift+O"));
    try testing.expect(!session.shows("Files"));
    // Newest first: "a", then the session folder.
    const newest = session.last("a").?;
    const older = session.last(std.fs.path.basename(session.folderPath())).?;
    try testing.expect(newest.y < older.y);

    // Typing does not reach the hidden blank file.
    session.typeKeys("zz");
    try testing.expect(session.editor.welcome());

    try testing.expectEqual(Request{ .pick = .open_file }, session.clickText("Open File...").?);
    _ = session.clickText("a");
    try testing.expect(session.shows("x.txt"));
    try testing.expect(session.shows("Files"));

    session.editor.closeFolder();
    session.draw();
    // The x of the first row, then Delete on the one left.
    _ = session.clickText("\u{D7}");
    try testing.expectEqual(@as(usize, 1), session.editor.recent.items.len);
    try testing.expect(session.last("a") == null);
    try session.restart();
    try testing.expectEqual(@as(usize, 1), session.editor.recent.items.len);
    _ = session.press("delete");
    try testing.expect(session.shows("No recent folders"));
    try session.restart();
    try testing.expect(session.shows("No recent folders"));
}

test "editor menu: Copy, Cut and Paste; Copy and Cut need a selection; Esc and clicks outside close it" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    const editor = &session.editor;
    const theme = &session.workbench.theme;
    editor.open(session.path("b.txt"));
    session.draw();

    _ = session.rightClickText("bee");
    try testing.expectEqual(theme.line_number, session.last("Copy").?.color);
    try testing.expectEqual(theme.line_number, session.last("Cut").?.color);
    try testing.expectEqual(theme.text, session.last("Paste").?.color);
    // A disabled item does nothing and the menu stays.
    try testing.expectEqual(@as(?Request, null), session.clickMenu("Copy"));
    try testing.expect(session.last("Cut") != null);
    _ = session.press("escape");
    try testing.expect(session.last("Cut") == null);

    _ = session.press("ctrl+a");
    _ = session.rightClickText("bee");
    // A right click inside the selection keeps it.
    try testing.expectEqual(theme.text, session.last("Copy").?.color);
    try testing.expectEqualStrings("bee\n", session.clickMenu("Copy").?.copy);
    try testing.expect(session.last("Cut") == null);

    _ = session.rightClickText("bee");
    _ = session.click(790, 500);
    try testing.expect(session.last("Cut") == null);
    try app.core.buffer.expectText(&editor.doc().buffer, "bee\n");

    _ = session.rightClickText("bee");
    try testing.expectEqualStrings("bee\n", session.clickMenu("Cut").?.copy);
    try testing.expect(!session.shows("bee"));
    _ = session.rightClick(400, 100);
    try testing.expectEqual(Request.paste, session.clickMenu("Paste").?);
    session.workbench.paste("pasted");
    session.draw();
    try testing.expect(session.shows("pasted"));
}

test "file tree menu: new, copy, cut, paste and delete files and folders" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    const editor = &session.editor;
    const theme = &session.workbench.theme;

    // Below the last row nothing is selected: only New and Paste work.
    _ = session.rightClick(100, 400);
    try testing.expectEqual(theme.line_number, session.last("Copy").?.color);
    try testing.expectEqual(theme.line_number, session.last("Paste").?.color);
    _ = session.clickMenu("New File");
    try testing.expect(session.shows("New file:"));
    session.typeKeys("n.txt");
    _ = session.press("enter");
    try testing.expect(fs.modTime(testing.io, session.path("n.txt")) != null);

    // A copy next to the original gets a free name.
    _ = session.rightClickText("b.txt");
    _ = session.clickMenu("Copy");
    _ = session.rightClick(100, 400);
    _ = session.clickMenu("Paste");
    try testing.expect(session.shows("b copy.txt"));

    // Cut moves, and an open file follows.
    editor.open(session.path("b copy.txt"));
    _ = session.rightClickText("b copy.txt");
    _ = session.clickMenu("Cut");
    _ = session.rightClickText("a");
    _ = session.clickMenu("Paste");
    try testing.expectEqual(@as(?i96, null), fs.modTime(testing.io, session.path("b copy.txt")));
    try testing.expect(fs.modTime(testing.io, session.path("a/b copy.txt")) != null);
    try testing.expect(std.mem.endsWith(u8, editor.file().path.?, "a" ++ std.fs.path.sep_str ++ "b copy.txt"));

    // A folder with everything in it; never into itself.
    _ = session.rightClickText("a");
    _ = session.clickMenu("Copy");
    _ = session.rightClickText("a");
    _ = session.clickMenu("Paste");
    try testing.expectEqualStrings("Cannot paste a into itself", editor.lastMessage().?);
    _ = session.rightClick(100, 400);
    _ = session.clickMenu("Paste");
    try testing.expect(fs.modTime(testing.io, session.path("a copy/x.txt")) != null);

    // Keys do the same.
    _ = session.clickText("n.txt");
    _ = session.press("ctrl+c");
    _ = session.press("ctrl+v");
    try testing.expect(fs.modTime(testing.io, session.path("n copy.txt")) != null);

    // Delete asks first.
    _ = session.rightClickText("n copy.txt");
    const request = session.clickMenu("Delete").?;
    try testing.expectEqual(app.editor.editor.Question.delete, request.ask.question);
    try testing.expectEqualStrings("n copy.txt", request.ask.name);
    _ = session.workbench.answer(.delete, .yes);
    session.draw();
    try testing.expectEqual(@as(?i96, null), fs.modTime(testing.io, session.path("n copy.txt")));
    try testing.expect(!session.shows("n copy.txt"));
}

test "status bar: only the git branch and the language" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    try session.write("main.zig", "const a = 1;\n");
    session.editor.open(session.path("main.zig"));
    _ = session.waitForGit();

    try testing.expect(session.inStatusBar("main"));
    try testing.expect(session.inStatusBar("Zig"));
    try testing.expect(!session.inStatusBar("main.zig"));
    try testing.expect(!session.inStatusBar("Ln"));
    try testing.expect(!session.inStatusBar("LF"));

    // Outside a repository there is no branch.
    session.editor.openFolder(session.path("a"));
    try fs.delete(testing.io, session.path(".git"));
    session.editor.openFolder(session.path("a"));
    _ = session.waitForGit();
    try testing.expect(!session.inStatusBar("main"));
    try testing.expect(session.inStatusBar("Zig"));
}

test "sidebar: shown while a folder is open, Files and Git tabs, the choice is remembered" {
    var session: Session = undefined;
    var config: testing.TmpDir = undefined;
    var buffer: [128]u8 = undefined;
    try withConfig(&session, &config, &buffer);
    defer config.cleanup();
    defer session.deinit();
    session.editor.openFolder(session.folderPath());
    session.draw();

    try testing.expect(session.shows("Files"));
    _ = session.clickText("Git");
    try testing.expectEqual(app.editor.editor.SidePanel.git, session.editor.side_panel);
    try testing.expectEqual(Area.sidebar, session.editor.focus);

    try session.restart();
    try testing.expectEqual(app.editor.editor.SidePanel.git, session.editor.side_panel);
    _ = session.clickText("Files");
    try testing.expect(session.shows("b.txt"));
    try session.restart();
    try testing.expectEqual(app.editor.editor.SidePanel.files, session.editor.side_panel);

    _ = session.press("ctrl+shift+w");
    try testing.expect(session.last("Files") == null);
    try testing.expect(session.last("Git") == null);
}
