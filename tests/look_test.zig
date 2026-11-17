//! End to end: which font each part of the window uses, hover colors and
//! the logo, drawn on a recording canvas.
const std = @import("std");
const app = @import("8-bit");
const Session = @import("session.zig").Session;

const testing = std.testing;
const Font = app.ui.canvas.Font;

fn fontOf(session: *const Session, text: []const u8) Font {
    return (session.last(text) orelse std.debug.panic("not on screen: {s}", .{text})).font;
}

test "code in JetBrains Mono, the UI in Inter" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    session.editor.open(session.path("b.txt"));
    _ = session.waitForGit();

    try testing.expectEqual(Font.code, fontOf(&session, "bee"));
    try testing.expectEqual(Font.code, fontOf(&session, "1"));
    for ([_][]const u8{ "Files", "Git", "b.txt", "Plain Text", "main" }) |label| {
        try testing.expectEqual(Font.ui, fontOf(&session, label));
    }
    _ = session.rightClickText("bee");
    try testing.expectEqual(Font.ui, fontOf(&session, "Copy"));
}

test "hover: the row and the tab under the mouse light up until it leaves" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    // x.txt is a tab that is not active, and not in the closed folder a.
    session.editor.open(session.path("a/x.txt"));
    _ = session.press("ctrl+n");
    _ = session.send(.{ .mouse_move = .{ .x = -1, .y = -1, .left_down = false } });
    const plain = session.recorder.fills.items.len;

    const row = session.last("b.txt").?;
    _ = session.send(.{ .mouse_move = .{ .x = row.x, .y = row.y + 4, .left_down = false } });
    try testing.expectEqual(plain + 1, session.recorder.fills.items.len);
    const tab = session.last("x.txt").?;
    _ = session.send(.{ .mouse_move = .{ .x = tab.x, .y = tab.y, .left_down = false } });
    try testing.expectEqual(plain + 1, session.recorder.fills.items.len);
    _ = session.send(.{ .mouse_move = .{ .x = -1, .y = -1, .left_down = false } });
    try testing.expectEqual(plain, session.recorder.fills.items.len);
}

test "the logo shows while no file is open" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    try testing.expectEqual(@as(usize, 1), session.recorder.logos);
    session.editor.open(session.path("b.txt"));
    session.draw();
    try testing.expectEqual(@as(usize, 0), session.recorder.logos);
    _ = session.editor.closeFolder();
    session.draw();
    try testing.expectEqual(@as(usize, 1), session.recorder.logos);
}

test "a tab with unsaved changes keeps its close button" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    session.editor.open(session.path("b.txt"));
    session.typeKeys("x");
    try testing.expect(session.editor.isModified());
    const tab = session.last("b.txt").?;
    const cross = session.last("\u{D7}").?;
    try testing.expectEqual(tab.y, cross.y);
    try testing.expect(cross.x > tab.x);
}

test "the actions next to the logo are in the text color" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    for ([_][]const u8{ "New File", "Open File...", "Close Folder" }) |label| {
        try testing.expectEqual(session.workbench.theme.text, session.last(label).?.color);
    }
}
