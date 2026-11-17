//! End to end: the minimap at the right of a file shows its words, its git
//! changes and the part on screen; a press or a drag there scrolls.
const std = @import("std");
const app = @import("8-bit");
const Session = @import("session.zig").Session;

const testing = std.testing;
const Rect = app.ui.layout.Rect;

/// The rectangles filled in `color`, in the order drawn.
fn fills(session: *const Session, color: app.ui.theme.Color, buffer: []Rect) []Rect {
    var len: usize = 0;
    for (session.recorder.fills.items) |fill| if (std.meta.eql(fill.color, color) and len < buffer.len) {
        buffer[len] = fill.rect;
        len += 1;
    };
    return buffer[0..len];
}

test "the minimap: a bar per word, the changes of the file, a press scrolls there" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    const theme = &session.workbench.theme;
    const editor = &session.editor;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "ab  cd\n");
    for (1..300) |n| try text.print(testing.allocator, "line {d}\n", .{n});
    try session.write("m.txt", text.items);
    try session.git(&.{ "add", "-A" });
    try session.git(&.{ "commit", "-q", "-m", "First" });
    try text.appendSlice(testing.allocator, "end\n");
    try session.write("m.txt", text.items);
    session.editor.open(session.path("m.txt"));
    _ = session.waitForGit();

    // A bar of one pixel per character, high as one, for "ab" and "cd".
    var buffer: [2]Rect = undefined;
    const words = fills(&session, theme.line_number, &buffer);
    try testing.expectEqual(@as(f32, 2), words[0].w);
    try testing.expectEqual(@as(f32, 1), words[0].h);
    try testing.expectEqual(@as(f32, 4), words[1].x - words[0].x);

    // The added last line is off screen: only the minimap marks it.
    const marks = fills(&session, theme.git_added, &buffer);
    try testing.expectEqual(@as(usize, 1), marks.len);
    const mark = marks[0];
    _ = session.click(mark.x + 1, mark.y + 1);
    try testing.expect(editor.view().top.line > 250);
    try testing.expectEqual(@as(usize, 2), fills(&session, theme.git_added, &buffer).len);

    session.drag(mark.x + 1, mark.y + 1, mark.x + 1, 0);
    try testing.expectEqual(@as(usize, 0), editor.view().top.line);
}
