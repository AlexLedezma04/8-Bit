//! End to end without SDL: the whole window driven by the events `main.zig`
//! passes on, drawn on a recording canvas, with a real folder on disk.
const std = @import("std");
const app = @import("8-bit");
const Session = @import("session.zig").Session;

const testing = std.testing;
const fs = app.platform.fs;

test "the file tree: folders first, .git hidden, click opens, keys open folders" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    const editor = &session.editor;

    try testing.expect(session.shows("Files"));
    try testing.expect(!session.shows(".git"));
    try testing.expect(session.recorder.find("a").?.y < session.recorder.find("b.txt").?.y);

    _ = session.clickText("b.txt");
    try testing.expectEqualStrings("b.txt", editor.name());
    try testing.expectEqual(app.editor.editor.Area.sidebar, editor.focus);
    try testing.expect(session.shows("bee"));
    // The blank untitled tab was replaced.
    try testing.expectEqual(@as(usize, 1), editor.pane.pane().tabs.items.len);

    _ = session.press("home");
    _ = session.press("enter");
    try testing.expect(session.shows("x.txt"));
    _ = session.press("left");
    try testing.expect(!session.shows("x.txt"));
    _ = session.press("right");
    _ = session.press("down");
    _ = session.press("enter");
    try testing.expectEqualStrings("x.txt", editor.name());
    // Enter on a file moves focus to the editor; typing goes there.
    try testing.expectEqual(app.editor.editor.Area.editor, editor.focus);
    session.typeKeys("Z");
    try testing.expect(session.shows("Zex"));
    try testing.expectEqual(@as(usize, 2), editor.pane.pane().tabs.items.len);
}

test "new, rename and delete from the tree, through the prompt and a question" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    const editor = &session.editor;
    _ = session.press("alt+1");
    // A new file goes in the selected folder, or next to the selected file.
    _ = session.press("down");

    _ = session.press("n");
    try testing.expect(session.shows("New file:"));
    session.typeKeys("new.txt");
    _ = session.press("enter");
    try testing.expect(fs.modTime(testing.io, session.path("new.txt")) != null);
    try testing.expectEqualStrings("new.txt", editor.name());
    try testing.expect(!session.shows("New file:"));

    // The new file is selected in the tree; rename it while it is open.
    _ = session.press("alt+1");
    _ = session.press("f2");
    try testing.expect(session.shows("Rename to:"));
    session.typeKeys("renamed.txt");
    _ = session.press("enter");
    try testing.expectEqual(@as(?i96, null), fs.modTime(testing.io, session.path("new.txt")));
    try testing.expectEqualStrings("renamed.txt", editor.name());

    // Esc cancels a prompt and changes nothing.
    _ = session.press("shift+n");
    try testing.expect(session.shows("New folder:"));
    _ = session.press("escape");
    try testing.expect(!session.shows("New folder:"));

    const request = session.press("delete").?;
    try testing.expectEqual(app.editor.editor.Question.delete, request.ask.question);
    try testing.expectEqualStrings("renamed.txt", request.ask.name);
    _ = session.workbench.answer(.delete, .yes);
    try testing.expectEqual(@as(?i96, null), fs.modTime(testing.io, session.path("renamed.txt")));
    for (session.workbench.files.entries.items) |entry| try testing.expect(!std.mem.endsWith(u8, entry.path, "renamed.txt"));

    try testing.expectEqualStrings("Deleted renamed.txt", editor.lastMessage().?);
}

test "docks: the sidebar while a folder is open, the terminal, and their edges can be dragged" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    const editor = &session.editor;

    try testing.expect(session.shows("Files"));
    _ = session.press("ctrl+shift+w");
    try testing.expect(!session.shows("Files"));
    _ = session.press("alt+1");
    try testing.expectEqual(app.editor.editor.Area.editor, editor.focus);
    editor.openFolder(session.folderPath());
    editor.open(session.path("a/x.txt"));
    session.draw();
    try testing.expect(session.shows("Files"));
    _ = session.press("alt+t");
    try testing.expect(session.shows("Terminal 1"));
    // The bottom dock is the terminal: no Messages or Search.
    try testing.expect(!session.shows("Messages"));
    try testing.expect(!session.shows("Search"));

    // The sidebar edge is at 30 cells of 8 pixels.
    session.drag(240, 300, 320, 300);
    try testing.expectEqual(@as(u16, 40), editor.sidebar.size);
    // The tab title starts a cell and a half after the sidebar and its line.
    try testing.expectEqual(@as(f32, 320 + 1 + 12), session.recorder.find("x.txt").?.x);
    // The bottom edge, from 14 rows to 20.
    session.drag(400, 576 - 224, 400, 576 - 320);
    try testing.expectEqual(@as(u16, 20), editor.bottom.size);

    // Zoom doubles every size, because sizes are in cells.
    session.drag(320, 300, 240, 300);
    _ = session.press("ctrl+=");
    try testing.expectEqual(@as(f32, 30 * 16 + 1 + 24), session.recorder.find("x.txt").?.x);
}

test "split panes: their own tabs, click to focus, drag the line, close the last tab" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    const editor = &session.editor;
    _ = session.press("ctrl+shift+w");
    editor.open(session.path("b.txt"));
    session.draw();

    _ = session.press("alt+shift+right");
    try testing.expect(editor.root.kind == .split);
    const left = editor.root.kind.split.first;
    const right = editor.root.kind.split.second;
    try testing.expectEqual(right, editor.pane);

    // Both panes show the file; a click in the left one gives it focus.
    _ = session.click(100, 100);
    try testing.expectEqual(left, editor.pane);
    _ = session.press("ctrl+n");
    try testing.expectEqual(@as(usize, 2), left.pane().tabs.items.len);
    _ = session.press("ctrl+tab");
    try testing.expectEqualStrings("b.txt", editor.name());

    // The line between the panes is in the middle of 800 pixels.
    session.drag(400, 300, 200, 300);
    try testing.expect(@abs(editor.root.kind.split.ratio - 0.25) < 0.01);

    // Close the right pane's only tab with its close button: the pane goes.
    const button = for (session.recorder.texts.items) |item| {
        if (std.mem.eql(u8, item.text, "\u{D7}") and item.x > 210 and item.y < 24) break item;
    } else unreachable;
    _ = session.click(button.x + 2, button.y + 4);
    try testing.expect(editor.root.kind == .pane);
    try testing.expectEqual(@as(usize, 2), editor.root.pane().tabs.items.len);
}

test "resize: the terminal's top edge and the sidebar's edge, with a resize cursor" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    const editor = &session.editor;
    editor.open(session.path("b.txt"));
    _ = session.press("alt+t");
    const before = session.workbench.frame();
    const bottom = before.bottom.?;
    const side = before.sidebar.?;
    const edge = side.x + side.w;

    // Hovering an edge shows the resize cursor; elsewhere the arrow.
    _ = session.send(.{ .mouse_move = .{ .x = 400, .y = bottom.y + 5, .left_down = false } });
    try testing.expectEqual(@as(?app.ui.layout.Frame.Edge, .bottom), session.workbench.edgeCursor());
    _ = session.send(.{ .mouse_move = .{ .x = edge + 5, .y = 200, .left_down = false } });
    try testing.expectEqual(@as(?app.ui.layout.Frame.Edge, .sidebar), session.workbench.edgeCursor());
    _ = session.send(.{ .mouse_move = .{ .x = 500, .y = 200, .left_down = false } });
    try testing.expectEqual(@as(?app.ui.layout.Frame.Edge, null), session.workbench.edgeCursor());

    // The terminal grows when its edge is dragged up, from just inside its tabs.
    session.drag(400, bottom.y + 5, 400, bottom.y - 160);
    try testing.expectEqual(@as(u16, editor.bottom.size), @as(u16, @intFromFloat(@round((before.status.y - (bottom.y - 160)) / 16))));
    try testing.expect(session.workbench.frame().bottom.?.h > bottom.h + 150);
    // The sidebar grows when its edge is dragged right, from the editor side.
    session.drag(edge + 5, 200, edge + 165, 200);
    try testing.expect(session.workbench.frame().sidebar.?.w > side.w + 150);
    // Below the grip the terminal tabs are clicked, not dragged.
    const size = editor.bottom.size;
    const tabs = session.workbench.frame().bottom.?;
    session.drag(tabs.x + 30, tabs.y + 12, tabs.x + 30, tabs.y - 88);
    try testing.expectEqual(size, editor.bottom.size);
}
