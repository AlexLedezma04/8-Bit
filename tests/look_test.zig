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
    session.draw();
    const plain = session.recorder.fills;

    const row = session.last("b.txt").?;
    _ = session.send(.{ .mouse_move = .{ .x = row.x, .y = row.y + 4, .left_down = false } });
    try testing.expectEqual(plain + 1, session.recorder.fills);
    const tab = session.last("untitled").?;
    _ = session.send(.{ .mouse_move = .{ .x = tab.x, .y = tab.y, .left_down = false } });
    try testing.expectEqual(plain + 1, session.recorder.fills);
    _ = session.send(.{ .mouse_move = .{ .x = -1, .y = -1, .left_down = false } });
    try testing.expectEqual(plain, session.recorder.fills);
}

test "the logo is on the welcome screen only" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    try testing.expectEqual(@as(usize, 0), session.recorder.logos);
    session.editor.closeFolder();
    session.draw();
    try testing.expectEqual(@as(usize, 1), session.recorder.logos);
    try testing.expect(session.shows("8-Bit"));
}
