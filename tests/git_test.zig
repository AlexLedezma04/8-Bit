//! End to end git: the whole window driven by events, against a real
//! repository in a temporary folder, with the real git CLI.
const std = @import("std");
const app = @import("8-bit");
const Session = @import("session.zig").Session;

const testing = std.testing;
const fs = app.platform.fs;
const Area = app.editor.editor.Area;

/// A session with one commit of every file.
fn committed(session: *Session) !void {
    try session.init();
    try session.git(&.{ "add", "-A" });
    try session.git(&.{ "commit", "-q", "-m", "First" });
    _ = session.send(.{ .focus = true });
    _ = session.waitForGit();
}

fn expectMessage(session: *const Session, expected: []const u8) !void {
    try testing.expectEqualStrings(expected, session.editor.lastMessage() orelse "(none)");
}

/// True when the text of the active tab has `part`. A line of code is
/// drawn in many runs, one per color, so this is what to check for it.
fn docHas(session: *Session, part: []const u8) bool {
    const doc = session.editor.doc();
    const text = testing.allocator.alloc(u8, doc.buffer.len()) catch return false;
    defer testing.allocator.free(text);
    return std.mem.indexOf(u8, doc.buffer.copy(0, text), part) != null;
}

fn markerCount(session: *const Session) usize {
    var count: usize = 0;
    for (session.editor.tab().decorations.items) |item| count += @intFromBool(item.kind == .gutter_marker);
    return count;
}

test "status: letters and colors in the tree, the branch in the status bar, refresh on focus and save" {
    var session: Session = undefined;
    try committed(&session);
    defer session.deinit();
    const theme = &session.workbench.theme;

    try testing.expect(session.inStatusBar("main"));
    try testing.expect(!session.shows("M"));

    try session.write("b.txt", "bee changed\n");
    try session.write("new.txt", "new\n");
    try session.write(".gitignore", "out/\n");
    try session.write("out/o.txt", "ignored\n");
    try session.write("a/x.txt", "ex changed\n");
    _ = session.send(.{ .focus = true });
    _ = session.waitForGit();

    try testing.expectEqual(theme.git_changed, session.recorder.find("b.txt").?.color);
    try testing.expectEqual(theme.git_changed, session.recorder.find("M").?.color);
    try testing.expectEqual(theme.git_untracked, session.recorder.find("new.txt").?.color);
    try testing.expect(session.shows("U"));
    try testing.expectEqual(theme.line_number, session.recorder.find("out").?.color);
    // A folder with a change inside.
    try testing.expectEqual(theme.git_changed, session.recorder.find("a").?.color);

    // Staged outside the editor; a save from the editor refreshes.
    try session.git(&.{ "add", "new.txt" });
    editorOpen(&session, "b.txt");
    session.typeKeys("x");
    _ = session.press("ctrl+s");
    _ = session.waitForGit();
    try testing.expectEqual(theme.git_added, session.recorder.find("new.txt").?.color);
    try testing.expect(session.shows("A"));
}

fn editorOpen(session: *Session, name: []const u8) void {
    session.editor.open(session.path(name));
    session.editor.focus = .editor;
    session.draw();
}

test "no repository, and git that is not installed: no Git tab" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    const editor = &session.editor;
    try testing.expect(session.last("Git") != null);
    _ = session.press("ctrl+shift+g");
    try testing.expectEqual(app.editor.editor.SidePanel.git, editor.sidePanel());

    // A folder that is not there is in no repository: the Files tab only,
    // and Ctrl+Shift+G says why.
    editor.openFolder("no/such/folder");
    session.draw();
    try testing.expect(session.last("Git") == null);
    try testing.expect(session.last("Files") != null);
    try testing.expectEqual(app.editor.editor.SidePanel.files, editor.sidePanel());
    _ = session.press("ctrl+shift+g");
    try expectMessage(&session, "No git repository");
    try testing.expectEqualStrings("", editor.status().branch);

    editor.openFolder(session.folderPath());
    editor.settings.git = "no-such-git-8bit";
    _ = session.send(.{ .focus = true });
    _ = session.waitForGit();
    try expectMessage(&session, "git is not installed: git features are off");
    try testing.expect(session.last("Git") == null);
    // Said once.
    editor.notify("later", .{});
    _ = session.send(.{ .focus = true });
    _ = session.waitForGit();
    try testing.expectEqualStrings("later", editor.lastMessage().?);
}

test "gutter markers follow the text after a short delay, F7 jumps between changes" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    const editor = &session.editor;
    try session.write("c.txt", "one\ntwo\nthree\nfour\nfive\nsix\n");
    try session.git(&.{ "add", "-A" });
    try session.git(&.{ "commit", "-q", "-m", "First" });
    editorOpen(&session, "c.txt");
    _ = session.waitForGit();
    try testing.expectEqual(@as(usize, 0), markerCount(&session));

    // A changed line: nothing until the text has rested.
    editor.now_ms = 1000;
    _ = session.press("end");
    session.typeKeys("!");
    try testing.expect(!editor.tick());
    try testing.expectEqual(@as(?u64, app.editor.tracking.delay_ms), editor.timeLeft());
    editor.now_ms += app.editor.tracking.delay_ms;
    try testing.expect(editor.tick());
    try testing.expectEqual(@as(usize, 1), markerCount(&session));

    // An added line at the end and a removed one in the middle.
    _ = session.press("ctrl+end");
    session.typeKeys("seven");
    _ = session.press("ctrl+home");
    _ = session.press("down");
    _ = session.press("down");
    _ = session.press("down");
    _ = session.press("shift+down");
    _ = session.press("delete");
    // The main loop ticks after every event; the delay starts again with each change.
    _ = editor.tick();
    editor.now_ms += app.editor.tracking.delay_ms - 1;
    try testing.expect(!editor.tick());
    editor.now_ms += 1;
    try testing.expect(editor.tick());
    try testing.expectEqual(@as(usize, 3), markerCount(&session));

    // Changed line 1, "four" removed above line 4, "seven" added on line 6.
    _ = session.press("ctrl+home");
    _ = session.press("f7");
    try testing.expectEqual(@as(usize, 4), editor.doc().buffer.lineOf(editor.doc().cursor.pos) + 1);
    _ = session.press("f7");
    try testing.expectEqual(@as(usize, 6), editor.doc().buffer.lineOf(editor.doc().cursor.pos) + 1);
    _ = session.press("f7");
    try expectMessage(&session, "No more changes");
    _ = session.press("shift+f7");
    try testing.expectEqual(@as(usize, 4), editor.doc().buffer.lineOf(editor.doc().cursor.pos) + 1);
    _ = session.press("shift+f7");
    try testing.expectEqual(@as(usize, 1), editor.doc().buffer.lineOf(editor.doc().cursor.pos) + 1);

    // A commit made outside the editor: once the window has focus again,
    // the markers are gone.
    _ = session.press("ctrl+s");
    try session.git(&.{ "commit", "-q", "-am", "Second" });
    _ = session.send(.{ .focus = true });
    _ = session.waitForGit();
    try testing.expectEqual(@as(usize, 0), markerCount(&session));
}

test "diff viewer: the current file, the panel's changes and staged files, a commit" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    const editor = &session.editor;
    try session.write("main.zig", "const a = 1;\nconst b = 2;\n");
    try session.git(&.{ "add", "-A" });
    try session.git(&.{ "commit", "-q", "-m", "First" });
    editorOpen(&session, "main.zig");
    _ = session.waitForGit();

    // Alt+D: unsaved changes too, with the colors of the language.
    _ = session.press("ctrl+end");
    session.typeKeys("const c = 3;");
    _ = session.press("alt+d");
    try testing.expectEqualStrings("main.zig (changes)", editor.name());
    try testing.expect(docHas(&session, "@@ -1,2 +1,3 @@"));
    try testing.expectEqual(session.workbench.theme.syntax.keyword, session.recorder.find("const").?.color);
    try testing.expect(session.shows("+"));
    try testing.expectEqualStrings("Zig", editor.status().language);
    // Read only.
    session.typeKeys("x");
    try testing.expect(!docHas(&session, "xconst"));
    try testing.expect(!editor.isModified());

    // From the panel: the work tree against the index.
    _ = session.press("ctrl+w");
    _ = session.press("ctrl+s");
    _ = session.press("ctrl+shift+g");
    _ = session.waitForGit();
    try testing.expect(session.shows("Changes (1)"));
    _ = session.press("down");
    _ = session.press("down");
    _ = session.press("enter");
    _ = session.waitForGit();
    try testing.expectEqualStrings("main.zig (changes)", editor.name());
    try testing.expect(docHas(&session, "const c = 3;"));

    // The index against HEAD.
    _ = session.press("alt+1");
    _ = session.press("s");
    _ = session.waitForGit();
    try testing.expect(session.shows("Staged (1)"));
    _ = session.press("home");
    _ = session.press("down");
    _ = session.press("enter");
    _ = session.waitForGit();
    try testing.expectEqualStrings("main.zig (staged)", editor.name());
    try testing.expect(docHas(&session, "const c = 3;"));

    // One commit, from the history.
    try session.git(&.{ "commit", "-q", "-m", "Add c" });
    _ = session.press("alt+1");
    _ = session.press("tab");
    _ = session.waitForGit();
    try testing.expect(session.shows("Add c"));
    _ = session.press("home");
    _ = session.press("enter");
    _ = session.waitForGit();
    try testing.expect(std.mem.startsWith(u8, editor.name(), "Commit "));
    try testing.expect(docHas(&session, "Tester"));
    try testing.expect(docHas(&session, "\nmain.zig\n"));
    try testing.expect(docHas(&session, "const c = 3;"));
    // F7 jumps to the changed lines of a diff.
    _ = session.press("ctrl+home");
    _ = session.press("f7");
    try testing.expectEqualStrings("const c = 3;", currentLine(&session));
}

fn currentLine(session: *Session) []const u8 {
    const doc = session.editor.doc();
    const range = doc.lineRange(doc.buffer.lineOf(doc.cursor.pos));
    const static = struct {
        var buffer: [256]u8 = undefined;
    };
    return std.mem.trimEnd(u8, doc.buffer.copy(range.start, static.buffer[0..@min(range.len(), 256)]), "\n");
}

test "git panel: switch with the dock tabs and keys; stage, unstage, discard" {
    var session: Session = undefined;
    try committed(&session);
    defer session.deinit();
    const editor = &session.editor;
    try session.write("b.txt", "bee changed\n");
    try session.write("new.txt", "new\n");

    _ = session.press("ctrl+shift+g");
    _ = session.waitForGit();
    try testing.expectEqual(app.editor.editor.SidePanel.git, editor.side_panel);
    try testing.expectEqual(Area.sidebar, editor.focus);
    try testing.expect(session.shows("Staged (0)"));
    try testing.expect(session.shows("Changes (2)"));
    _ = session.press("ctrl+shift+e");
    try testing.expectEqual(app.editor.editor.SidePanel.files, editor.side_panel);
    try testing.expect(!session.shows("Staged (0)"));
    _ = session.clickText("Git");
    try testing.expect(session.shows("Staged (0)"));

    // `s` on a file, `u` back, Shift+S all, Shift+U all.
    _ = session.press("down");
    _ = session.press("down");
    _ = session.press("s");
    _ = session.waitForGit();
    try testing.expect(session.shows("Staged (1)"));
    try testing.expect(session.shows("Changes (1)"));
    _ = session.press("home");
    _ = session.press("down");
    _ = session.press("u");
    _ = session.waitForGit();
    try testing.expect(session.shows("Staged (0)"));
    _ = session.press("shift+s");
    _ = session.waitForGit();
    try testing.expect(session.shows("Staged (2)"));
    try testing.expect(session.shows("Changes (0)"));
    // `u` on the Staged title unstages all.
    _ = session.press("home");
    _ = session.press("u");
    _ = session.waitForGit();
    try testing.expect(session.shows("Staged (0)"));

    // Delete asks first, then discards. An untracked file is deleted.
    _ = session.press("end");
    var request = session.press("delete").?;
    try testing.expectEqual(app.editor.editor.Question.discard, request.ask.question);
    try testing.expectEqualStrings("new.txt", request.ask.name);
    _ = session.workbench.answer(.discard, .cancel);
    _ = session.waitForGit();
    try testing.expect(fs.modTime(testing.io, session.path("new.txt")) != null);
    request = session.press("delete").?;
    _ = session.workbench.answer(.discard, .yes);
    _ = session.waitForGit();
    try testing.expectEqual(@as(?i96, null), fs.modTime(testing.io, session.path("new.txt")));
    try testing.expect(session.shows("Changes (1)"));
    _ = session.press("end");
    _ = session.press("delete");
    _ = session.workbench.answer(.discard, .yes);
    _ = session.waitForGit();
    const text = try fs.read(testing.io, testing.allocator, session.path("b.txt"));
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("bee\n", text);
    try testing.expect(session.shows("Changes (0)"));
}

test "commit: a message tab, empty is refused, Ctrl+Enter commits, amend, hook errors" {
    var session: Session = undefined;
    try committed(&session);
    defer session.deinit();
    const editor = &session.editor;
    try session.write("b.txt", "bee changed\n");
    try session.git(&.{ "add", "b.txt" });

    _ = session.press("ctrl+enter");
    try testing.expectEqualStrings("Commit message", editor.name());
    try testing.expectEqualStrings("Git Commit", editor.status().language);
    _ = session.press("ctrl+enter");
    try expectMessage(&session, "Write a commit message first");

    // All editing keys work in the message.
    session.typeKeys("Change bee");
    _ = session.press("shift+home");
    _ = session.press("ctrl+x");
    _ = session.press("ctrl+z");
    _ = session.press("end");
    _ = session.press("enter");
    session.typeKeys("# a comment");
    _ = session.press("ctrl+enter");
    _ = session.waitForGit();
    try expectMessage(&session, "Committed");
    try testing.expect(!std.mem.eql(u8, editor.name(), "Commit message"));
    const subject = try session.gitOutput(&.{ "log", "-1", "--format=%B" });
    defer testing.allocator.free(subject);
    try testing.expectEqualStrings("Change bee", subject);

    // Amend starts from the last message.
    _ = session.press("ctrl+shift+enter");
    _ = session.waitForGit();
    try testing.expectEqualStrings("Amend commit", editor.name());
    try testing.expect(session.shows("Change bee"));
    session.typeKeys(" again");
    _ = session.press("ctrl+enter");
    _ = session.waitForGit();
    try expectMessage(&session, "Amended the last commit");
    const amended = try session.gitOutput(&.{ "log", "--format=%s" });
    defer testing.allocator.free(amended);
    try testing.expectEqualStrings("Change bee again\nFirst", amended);

    // A hook that refuses: its message is shown and the tab stays.
    if (@import("builtin").os.tag == .windows) return;
    try session.write(".git/hooks/pre-commit", "#!/bin/sh\necho 'hook says no' >&2\nexit 1\n");
    try session.write("b.txt", "bee refused\n");
    try session.git(&.{ "add", "b.txt" });
    const hook = try std.Io.Dir.cwd().openFile(testing.io, session.path(".git/hooks/pre-commit"), .{});
    defer hook.close(testing.io);
    try hook.setPermissions(testing.io, .fromMode(0o755));
    _ = session.press("ctrl+enter");
    session.typeKeys("Refused");
    _ = session.press("ctrl+enter");
    _ = session.waitForGit();
    try expectMessage(&session, "git: hook says no");
    try testing.expectEqualStrings("Commit message", editor.name());
}

test "history: pages of 200 while scrolling, Enter opens a commit, the history of one file" {
    var session: Session = undefined;
    try committed(&session);
    defer session.deinit();
    const editor = &session.editor;
    var buffer: [32]u8 = undefined;
    for (0..app.git.log.page + 4) |i| {
        try session.git(&.{ "commit", "-q", "--allow-empty", "-m", try std.fmt.bufPrint(&buffer, "Empty {d}", .{i}) });
    }
    try session.write("b.txt", "bee 2\n");
    try session.git(&.{ "commit", "-q", "-am", "Change bee" });

    _ = session.press("ctrl+shift+g");
    _ = session.press("tab");
    _ = session.waitForGit();
    try testing.expectEqual(@as(usize, app.git.log.page), editor.git.history.commits.items.len);
    try testing.expect(session.shows("Change bee"));
    try testing.expect(session.shows("Empty 203"));
    // Near the end the next page loads.
    _ = session.press("end");
    _ = session.waitForGit();
    try testing.expectEqual(@as(usize, app.git.log.page + 6), editor.git.history.commits.items.len);
    try testing.expect(editor.git.history.complete);
    _ = session.press("end");
    _ = session.waitForGit();
    try testing.expect(session.shows("First"));
    _ = session.press("enter");
    _ = session.waitForGit();
    try testing.expect(docHas(&session, "\nb.txt\n"));
    try testing.expect(docHas(&session, "\nbee\n"));
    try testing.expect(docHas(&session, "\na/x.txt\n"));

    // Alt+H: only the commits of b.txt.
    editorOpen(&session, "b.txt");
    _ = session.press("alt+h");
    _ = session.waitForGit();
    try testing.expect(session.shows("History of b.txt"));
    try testing.expectEqual(@as(usize, 2), editor.git.history.commits.items.len);
    try testing.expect(!session.shows("Empty"));
}

test "branches: list with the current one marked, create, switch, git refuses" {
    var session: Session = undefined;
    try committed(&session);
    defer session.deinit();
    const editor = &session.editor;

    _ = session.press("ctrl+shift+g");
    _ = session.press("tab");
    _ = session.press("tab");
    _ = session.waitForGit();
    try testing.expectEqual(session.workbench.theme.accent, session.recorder.find("main").?.color);

    _ = session.press("n");
    try testing.expect(session.shows("New branch:"));
    session.typeKeys("dev");
    _ = session.press("enter");
    _ = session.waitForGit();
    try expectMessage(&session, "Created branch");
    try testing.expect(session.inStatusBar("dev"));
    try testing.expectEqual(session.workbench.theme.accent, session.recorder.find("dev").?.color);

    // A commit on dev, then back to main: the open file follows.
    editorOpen(&session, "b.txt");
    try session.write("b.txt", "bee on dev\n");
    try session.git(&.{ "commit", "-q", "-am", "Dev bee" });
    _ = session.press("alt+1");
    _ = session.press("home");
    if (!std.mem.eql(u8, editor.git.branches.items[0].name, "main")) _ = session.press("down");
    _ = session.press("enter");
    _ = session.waitForGit();
    try expectMessage(&session, "Switched branch");
    try testing.expect(session.inStatusBar("main"));
    try testing.expect(session.shows("bee"));
    try testing.expect(!session.shows("bee on dev"));

    // Unsaved work in the way: git refuses and says why.
    try session.write("b.txt", "local change\n");
    _ = session.press("alt+1");
    _ = session.press("home");
    _ = session.press("enter");
    _ = session.waitForGit();
    try testing.expect(std.mem.startsWith(u8, editor.lastMessage().?, "git: error: Your local changes"));
    try testing.expectEqualStrings("main", editor.status().branch);
}

test "blame: gutter text per line, hidden while edited, a click opens the commit" {
    var session: Session = undefined;
    try committed(&session);
    defer session.deinit();
    const editor = &session.editor;
    try session.write("b.txt", "bee\nsecond line, long enough to scroll with blame\n");
    try session.git(&.{ "commit", "-q", "-am", "Second line" });
    editorOpen(&session, "b.txt");
    _ = session.send(.{ .focus = true });

    _ = session.press("alt+b");
    try expectMessage(&session, "Blame on");
    _ = session.waitForGit();
    const first = session.recorder.find("Tester").?;
    try testing.expect(std.mem.indexOf(u8, first.text, " 20") != null);

    // Edits hide it; undo brings it back.
    session.typeKeys("x");
    try testing.expect(!session.shows("Tester"));
    _ = session.press("ctrl+z");
    try testing.expect(session.shows("Tester"));

    // A click on the second line in the gutter opens its commit.
    const second = session.recorder.texts.items[
        blk: {
            var count: usize = 0;
            for (session.recorder.texts.items, 0..) |item, i| if (std.mem.indexOf(u8, item.text, "Tester") != null) {
                count += 1;
                if (count == 2) break :blk i;
            };
            unreachable;
        }
    ];
    _ = session.click(second.x + 4, second.y + 8);
    _ = session.waitForGit();
    try testing.expect(std.mem.startsWith(u8, editor.name(), "Commit "));
    try testing.expect(docHas(&session, "Second line"));

    // The end of the long line: the narrow text scrolls; without blame it
    // scrolls back.
    _ = session.press("ctrl+w");
    _ = session.press("end");
    try testing.expect(editor.view().left > 0);
    _ = session.press("alt+b");
    try expectMessage(&session, "Blame off");
    try testing.expectEqual(@as(usize, 0), editor.view().left);
}

test "a repository made or deleted outside while the folder is open" {
    var session: Session = undefined;
    try committed(&session);
    defer session.deinit();
    const editor = &session.editor;
    editor.open(session.path("b.txt"));
    session.typeKeys("x");
    _ = session.waitForGit();
    editor.now_ms += 1000;
    _ = session.waitForGit();
    try testing.expect(editor.file().tracking.markers.items.len > 0);
    try testing.expect(session.inStatusBar("main"));

    // Deleted: no Git tab, no branch, no gutter markers.
    try fs.delete(testing.io, session.path(".git"));
    _ = session.send(.{ .focus = true });
    _ = session.waitForGit();
    try testing.expect(!editor.git.ready());
    try testing.expect(session.last("Git") == null);
    try testing.expect(!session.inStatusBar("main"));
    try testing.expectEqual(@as(usize, 0), editor.file().tracking.markers.items.len);

    // Made again: all of it comes back.
    try session.git(&.{ "init", "-q", "-b", "main" });
    _ = session.send(.{ .focus = true });
    _ = session.waitForGit();
    try testing.expect(editor.git.ready());
    try testing.expect(session.last("Git") != null);
    try testing.expect(session.inStatusBar("main"));
}

test "the Staged and Changes titles collapse and expand their files" {
    var session: Session = undefined;
    try committed(&session);
    defer session.deinit();
    try session.write("b.txt", "changed\n");
    try session.write("new.txt", "new\n");
    try session.git(&.{ "add", "new.txt" });
    _ = session.press("ctrl+shift+g");
    _ = session.waitForGit();
    try testing.expect(session.shows("new.txt"));
    try testing.expect(session.shows("b.txt"));

    // One click on a title hides its files; the arrow turns.
    _ = session.clickText("Changes (1)");
    try testing.expect(!session.shows("b.txt"));
    try testing.expect(session.shows("new.txt"));
    try testing.expectEqualStrings("\u{25B6}", session.recorder.texts.items[indexOf(&session, "Changes (1)") - 1].text);
    _ = session.clickText("Changes (1)");
    try testing.expect(session.shows("b.txt"));

    // Enter on a title does the same.
    _ = session.press("home");
    _ = session.press("enter");
    try testing.expect(!session.shows("new.txt"));
    try testing.expect(session.shows("Staged (1)"));
    _ = session.press("enter");
    try testing.expect(session.shows("new.txt"));
}

fn indexOf(session: *const Session, text: []const u8) usize {
    for (session.recorder.texts.items, 0..) |item, i| if (std.mem.eql(u8, item.text, text)) return i;
    unreachable;
}

/// Makes the markers again, as the main loop does once the text rests.
fn settle(session: *Session) void {
    _ = session.editor.tick();
    session.editor.now_ms += app.editor.tracking.delay_ms;
    _ = session.editor.tick();
    session.draw();
}

/// Clicks the gutter beside the first marker drawn in `color`, past the
/// sidebar's resize grip.
fn clickMarker(session: *Session, color: app.ui.theme.Color) void {
    for (session.recorder.fills.items) |fill| if (std.meta.eql(fill.color, color)) {
        _ = session.click(fill.rect.x + 16, fill.rect.y + 1);
        return;
    };
    std.debug.panic("no marker", .{});
}

test "a click on a changed line's gutter: next change, its diff inline, revert" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    const theme = &session.workbench.theme;
    try session.write("c.txt", "one\ntwo\nthree\nfour\n");
    try session.git(&.{ "add", "-A" });
    try session.git(&.{ "commit", "-q", "-m", "First" });
    try session.write("c.txt", "one\nTWO\nthree\nfour\nfive\n");
    editorOpen(&session, "c.txt");
    _ = session.waitForGit();

    clickMarker(&session, theme.git_changed);
    try testing.expect(session.shows("Revert"));
    _ = session.clickMenu("Next Change");
    try testing.expectEqual(@as(usize, 5), session.cursor()[0]);
    _ = session.press("ctrl+alt+z");
    try testing.expect(!docHas(&session, "five"));

    // Show Diff: the line at HEAD under the changed one, in the same tab,
    // until the next key.
    settle(&session);
    clickMarker(&session, theme.git_changed);
    _ = session.clickMenu("Show Diff");
    try testing.expectEqualStrings("c.txt", session.editor.name());
    const old = session.recorder.find("two").?;
    try testing.expect(old.y > session.recorder.find("TWO").?.y);
    try testing.expectEqual(@as(usize, 1), session.recorder.filled(theme.diff_removed));
    try testing.expectEqual(@as(usize, 1), session.recorder.filled(theme.diff_added));
    _ = session.press("up");
    try testing.expect(!session.shows("two"));

    clickMarker(&session, theme.git_changed);
    _ = session.clickMenu("Revert");
    try testing.expect(docHas(&session, "one\ntwo\nthree\nfour\n"));
    settle(&session);
    try testing.expectEqual(@as(usize, 0), markerCount(&session));
    _ = session.press("ctrl+alt+z");
    try expectMessage(&session, "No change here");
}
