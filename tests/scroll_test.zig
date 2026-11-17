//! End to end: the mouse wheel, smooth wheels and touchpads, and the
//! scrollbars of files and lists.
const std = @import("std");
const app = @import("8-bit");
const Session = @import("session.zig").Session;

const testing = std.testing;
const Scrollbar = app.ui.scrollbar.Scrollbar;

fn openBig(session: *Session, lines: usize) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..lines) |n| try text.print(testing.allocator, "line {d}\n", .{n});
    try session.write("big.txt", text.items);
    session.editor.open(session.path("big.txt"));
    session.draw();
}

fn wheel(session: *Session, x: f32, y: f32, dy: f32) void {
    _ = session.send(.{ .wheel = .{ .x = x, .y = y, .dx = 0, .dy = dy, .mods = .{} } });
}

/// The thumb of the scrollbar drawn at the right edge of `area`.
fn thumb(session: *const Session, area: app.ui.layout.Rect) app.ui.layout.Rect {
    for (session.recorder.fills.items) |fill| {
        const rect = fill.rect;
        if (rect.x > area.x + area.w - 8 and rect.x < area.x + area.w and rect.w < 8 and rect.y >= area.y) return rect;
    }
    std.debug.panic("no scrollbar", .{});
}

test "the wheel scrolls a file; parts of a step add up" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    try openBig(&session, 500);
    const view = session.editor.view();

    wheel(&session, 500, 300, -1);
    try testing.expectEqual(@as(usize, 3), view.top.line);
    wheel(&session, 500, 300, 1);
    try testing.expectEqual(@as(usize, 0), view.top.line);
    // A smooth wheel: a tenth of a step at a time, three rows a step.
    for (0..10) |_| wheel(&session, 500, 300, -0.1);
    try testing.expectEqual(@as(usize, 3), view.top.line);
}

test "file scrollbar: shown for a long file, drag and click scroll" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    const editor = &session.editor;
    try openBig(&session, 1000);
    const area = session.workbench.frame().editor;

    const top = thumb(&session, area);
    try testing.expect(top.h >= 16 and top.h < 40);
    // Drag the thumb to the bottom: the last line is at the top.
    session.drag(top.x + 2, top.y + 2, top.x + 2, area.y + area.h + 100);
    // 1000 lines and the empty one after the last line break.
    try testing.expectEqual(@as(usize, 1000), editor.view().top.line);
    try testing.expect(thumb(&session, area).y > area.y + area.h / 2);
    // A click on the track halfway moves there.
    _ = session.click(top.x + 2, area.y + 40 + (area.h - 40) / 2);
    try testing.expect(@abs(@as(isize, @intCast(editor.view().top.line)) - 500) < 30);
    // The cursor did not move.
    try testing.expectEqual(@as(usize, 0), editor.doc().cursor.pos);

    // A file that fits has none.
    session.editor.open(session.path("b.txt"));
    session.draw();
    for (session.recorder.fills.items) |fill| try testing.expect(!(fill.rect.x > area.x + area.w - 8 and fill.rect.w < 8 and fill.rect.y > area.y + 40));
}

test "list scrollbar: the file tree of a big folder can be dragged" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    var name: [16]u8 = undefined;
    for (0..60) |n| try session.write(try std.fmt.bufPrint(&name, "f{d:0>2}.txt", .{n}), "");
    session.workbench.files.refresh();
    session.draw();
    const sidebar = session.workbench.frame().sidebar.?;

    const top = thumb(&session, sidebar);
    session.drag(top.x + 2, top.y + 2, top.x + 2, sidebar.y + sidebar.h + 100);
    try testing.expect(session.workbench.files.list.top > 30);
    try testing.expect(session.shows("f59.txt"));
    try testing.expect(!session.shows("b.txt"));
    // The wheel scrolls back.
    for (0..30) |_| wheel(&session, sidebar.x + 50, sidebar.y + 100, 1);
    try testing.expectEqual(@as(usize, 0), session.workbench.files.list.top);
}

/// The thumb of the scrollbar drawn along the bottom of `area`.
fn bottomThumb(session: *const Session, area: app.ui.layout.Rect) ?app.ui.layout.Rect {
    for (session.recorder.fills.items) |fill| {
        const rect = fill.rect;
        if (rect.h < 8 and rect.w >= 16 and rect.y > area.y + area.h - 40 and rect.y < area.y + area.h) return rect;
    }
    return null;
}

test "horizontal scrollbar: shown for a long line, drag and Shift+wheel scroll, gone with wrap" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    const editor = &session.editor;
    const long: [400]u8 = @splat('w');
    try session.write("wide.txt", "short\n" ++ long ++ "\n");
    editor.open(session.path("wide.txt"));
    session.draw();
    const area = session.workbench.frame().editor;

    const thumb_ = bottomThumb(&session, area).?;
    try testing.expect(thumb_.w < area.w / 2);
    session.drag(thumb_.x + 4, thumb_.y + 2, area.x + area.w + 100, thumb_.y + 2);
    // The end of the line is in view.
    try testing.expect(editor.view().left + editor.view().cols >= 400);
    try testing.expect(bottomThumb(&session, area).?.x > area.x + area.w / 2);

    _ = session.send(.{ .wheel = .{ .x = 500, .y = 300, .dx = 0, .dy = 1, .mods = .{ .shift = true } } });
    try testing.expect(editor.view().left + editor.view().cols < 400);

    _ = session.press("alt+z");
    try testing.expect(bottomThumb(&session, area) == null);
}
