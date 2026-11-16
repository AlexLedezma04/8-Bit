//! End to end: an editing session through the editor's document, the way
//! key presses will drive it.
const std = @import("std");
const app = @import("8-bit");

const testing = std.testing;
const expectText = app.core.buffer.expectText;

test "type, move, select, delete, undo and redo a file" {
    var ed = try app.editor.editor.Editor.init(testing.allocator, testing.io);
    defer ed.deinit();
    const doc = ed.doc();

    try doc.buffer.load("fn main() void {\r\n}\r\n");
    try testing.expectEqual(@as(usize, 3), doc.buffer.lineCount());

    // Type a line inside the function, one key at a time.
    doc.move(.line_end, false);
    for ("\n    say(\"h\u{E9}llo\");") |*char| try doc.insert(char[0..1]);
    try expectText(&doc.buffer, "fn main() void {\n    say(\"h\u{E9}llo\");\r\n}\r\n");
    try testing.expectEqual(@as(usize, 4), doc.buffer.lineCount());
    try testing.expectEqual(@as(usize, 1), doc.buffer.lineOf(doc.cursor.pos));

    // Select the word in the string and type over it.
    doc.move(.word_left, false);
    doc.move(.word_right, true);
    try doc.insert("bye");
    try expectText(&doc.buffer, "fn main() void {\n    say(\"bye\");\r\n}\r\n");

    // Up keeps the column; delete to the end of the first line.
    doc.move(.up, false);
    try testing.expectEqual(@as(usize, 12), doc.cursor.pos);
    doc.move(.line_end, true);
    try doc.delete(.left);
    try expectText(&doc.buffer, "fn main() vo\n    say(\"bye\");\r\n}\r\n");

    // Paste over everything.
    doc.selectAll();
    try doc.paste("empty\n");
    try expectText(&doc.buffer, "empty\n");
    try testing.expectEqual(@as(usize, 2), doc.buffer.lineCount());

    // Undo all the way back to the loaded file, then redo all of it.
    var steps: usize = 0;
    while (try doc.undo()) steps += 1;
    try expectText(&doc.buffer, "fn main() void {\r\n}\r\n");
    try testing.expectEqual(@as(usize, 3), doc.buffer.lineCount());
    try testing.expectEqual(@as(usize, 16), doc.cursor.pos);

    var redone: usize = 0;
    while (try doc.redo()) redone += 1;
    try testing.expectEqual(steps, redone);
    try expectText(&doc.buffer, "empty\n");
    try testing.expectEqual(@as(usize, 6), doc.cursor.pos);
}
