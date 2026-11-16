//! End to end: find, replace, go to line and find in project, driven by keys
//! on the whole window, with real files on disk.
const std = @import("std");
const app = @import("8-bit");
const Session = @import("session.zig").Session;

const testing = std.testing;
const Range = app.core.buffer.Range;
const Area = app.editor.editor.Area;

fn openFile(session: *Session, name: []const u8, text: []const u8) !void {
    try session.write(name, text);
    session.editor.open(session.path(name));
    session.draw();
}

fn matchCount(session: *const Session) usize {
    var count: usize = 0;
    for (session.editor.tab().decorations.items) |item| {
        if (item.kind == .text_background and item.kind.text_background == .match) count += 1;
    }
    return count;
}

fn expectSelection(session: *const Session, start: usize, end: usize) !void {
    try testing.expectEqual(Range{ .start = start, .end = end }, session.editor.doc().cursor.selection());
}

test "find: matches follow typing, Enter and F3 go round, options, Esc" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    try openFile(&session, "f.txt", "one two One\nTwo one\n");

    _ = session.press("ctrl+f");
    try testing.expect(session.shows("Find:"));
    session.typeKeys("on");
    try testing.expect(session.shows("1 of 3"));
    session.typeKeys("e");
    try expectSelection(&session, 0, 3);
    try testing.expectEqual(@as(usize, 3), matchCount(&session));

    _ = session.press("enter");
    try testing.expect(session.shows("2 of 3"));
    _ = session.press("f3");
    try expectSelection(&session, 16, 19);
    _ = session.press("enter");
    try testing.expect(session.shows("1 of 3"));
    _ = session.press("shift+enter");
    try testing.expect(session.shows("3 of 3"));
    _ = session.press("shift+f3");
    try expectSelection(&session, 8, 11);

    // "One" is no match with match case.
    _ = session.press("alt+c");
    try testing.expect(session.shows("2 matches"));
    _ = session.press("alt+w");
    try testing.expect(session.editor.find.options.whole_word);
    try testing.expectEqual(@as(usize, 2), matchCount(&session));

    // Esc closes and hides the matches; F3 still goes on.
    _ = session.press("escape");
    try testing.expect(!session.shows("Find:"));
    try testing.expectEqual(@as(usize, 0), matchCount(&session));
    _ = session.press("f3");
    try expectSelection(&session, 16, 19);

    // Ctrl+F with a selection searches for it; nothing found says so.
    _ = session.press("ctrl+f");
    try testing.expectEqualStrings("one", session.workbench.prompt.text());
    session.typeKeys("x");
    try testing.expect(session.shows("No matches"));
}

test "replace: one, then all as one undo step" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    try openFile(&session, "r.txt", "cat Cat cat\n");
    const buffer = &session.editor.doc().buffer;

    // Nothing to find yet: Ctrl+H asks for it first.
    _ = session.press("ctrl+h");
    try testing.expect(session.shows("Replace:"));
    session.typeKeys("cat");
    _ = session.press("enter");
    try testing.expect(session.shows("Replace with:"));
    try testing.expect(session.shows("1 of 3"));
    session.typeKeys("dog");
    _ = session.press("enter");
    try app.core.buffer.expectText(buffer, "dog Cat cat\n");
    try testing.expect(session.shows("1 of 2"));
    _ = session.press("alt+a");
    try app.core.buffer.expectText(buffer, "dog dog dog\n");
    try testing.expect(session.shows("Replaced 2"));
    _ = session.press("escape");

    _ = session.press("ctrl+z");
    try app.core.buffer.expectText(buffer, "dog Cat cat\n");
    _ = session.press("ctrl+z");
    try app.core.buffer.expectText(buffer, "cat Cat cat\n");

    // The second time, Ctrl+H asks for the replacement at once.
    _ = session.press("ctrl+h");
    try testing.expect(session.shows("Replace with:"));
    try testing.expectEqualStrings("dog", session.workbench.prompt.text());
}

test "go to line and line:column; bad input is reported" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    try openFile(&session, "g.txt", "one\ntwo\nthree\n");

    _ = session.press("ctrl+g");
    try testing.expect(session.shows("Go to line:"));
    session.typeKeys("3:2");
    _ = session.press("enter");
    try testing.expect(!session.shows("Go to line:"));
    try testing.expect(session.shows("Ln 3, Col 2"));

    _ = session.press("ctrl+g");
    session.typeKeys("99");
    _ = session.press("enter");
    try testing.expect(session.shows("Ln 4, Col 1"));

    _ = session.press("ctrl+g");
    session.typeKeys("x");
    _ = session.press("enter");
    try testing.expect(session.shows("Not a line: x"));
}

test "find in project: results while it runs, Enter opens, Esc stops" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    const editor = &session.editor;
    try session.write("zig-out/y.txt", "ex");
    try session.write(".git/z.txt", "ex");
    try session.write("big.bin", "ex\x00");

    _ = session.press("ctrl+shift+f");
    try testing.expect(session.shows("Find in folder:"));
    session.typeKeys("ex");
    _ = session.press("enter");
    try testing.expectEqual(Area.bottom, editor.focus);
    try testing.expect(session.shows("Searching \"ex\""));
    session.waitForSearch();
    try testing.expect(session.shows("\"ex\": 1 result in 1 file"));
    try testing.expect(session.shows("x.txt:1: ex"));
    try testing.expect(!session.shows("y.txt:"));

    _ = session.press("enter");
    try testing.expectEqualStrings("x.txt", editor.name());
    try testing.expectEqual(Area.editor, editor.focus);
    try expectSelection(&session, 0, 2);

    // The selection is searched again; Esc in the results stops it.
    _ = session.press("ctrl+shift+f");
    try testing.expectEqualStrings("ex", session.workbench.prompt.text());
    _ = session.press("enter");
    _ = session.press("escape");
    session.waitForSearch();
    try testing.expect(session.shows("Stopped: \"ex\""));

    // A click on a title of the bottom bar switches the panel.
    _ = session.clickText("Messages");
    try testing.expectEqual(app.editor.editor.BottomPanel.messages, session.editor.bottom_panel);
    try testing.expect(!session.shows("Stopped:"));
}
