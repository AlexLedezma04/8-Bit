//! Every user action, and the one function that runs them. Keys, the mouse,
//! dialogs and panels all go through here.
//! A new action is one enum value and one case in `execute`.
const std = @import("std");
const editor_zig = @import("editor.zig");
const Editor = editor_zig.Editor;
const Request = editor_zig.Request;
const panes = @import("panes.zig");

/// The tag name is the command's text name, used by key binding files.
pub const Command = enum {
    move_left,
    move_right,
    move_word_left,
    move_word_right,
    move_line_start,
    move_line_end,
    move_up,
    move_down,
    move_page_up,
    move_page_down,
    move_file_start,
    move_file_end,
    select_left,
    select_right,
    select_word_left,
    select_word_right,
    select_line_start,
    select_line_end,
    select_up,
    select_down,
    select_page_up,
    select_page_down,
    select_file_start,
    select_file_end,
    select_all,
    insert_newline,
    indent,
    outdent,
    delete_left,
    delete_right,
    delete_word_left,
    delete_word_right,
    undo,
    redo,
    copy,
    cut,
    paste,
    open,
    open_folder,
    close_folder,
    save,
    save_as,
    quit,
    goto_line,
    find,
    find_next,
    find_prev,
    replace,
    replace_next,
    replace_all,
    toggle_match_case,
    toggle_whole_word,
    toggle_comment,
    goto_bracket,
    set_language,
    toggle_wrap,
    zoom_in,
    zoom_out,
    zoom_reset,
    open_settings,
    next_theme,
    new_file,
    close_tab,
    next_tab,
    prev_tab,
    split_right,
    split_down,
    next_pane,
    prev_pane,
    focus_sidebar,
    focus_editor,
    show_files,
    show_git,
    git_commit,
    git_amend,
    show_changes,
    next_change,
    prev_change,
    revert_change,
    toggle_blame,
    file_history,
    toggle_terminal,
    new_terminal,

    pub fn fromName(name: []const u8) ?Command {
        return std.meta.stringToEnum(Command, name);
    }
};

/// Runs `command`. Returns what `main.zig` must do for it, if anything.
pub fn run(editor: *Editor, command: Command) ?Request {
    const request = execute(editor, command) catch |err| blk: {
        editor.notify("{t} failed: {t}", .{ command, err });
        break :blk null;
    };
    editor.afterEdit();
    return request;
}

fn execute(editor: *Editor, command: Command) !?Request {
    const doc = editor.doc();
    const view = editor.view();
    switch (command) {
        .move_left => doc.move(.left, false),
        .move_right => doc.move(.right, false),
        .move_word_left => doc.move(.word_left, false),
        .move_word_right => doc.move(.word_right, false),
        .move_line_start => doc.move(.line_start, false),
        .move_line_end => doc.move(.line_end, false),
        .move_up => view.moveVertical(doc, -1, false),
        .move_down => view.moveVertical(doc, 1, false),
        .move_page_up => view.moveVertical(doc, -view.pageRows(), false),
        .move_page_down => view.moveVertical(doc, view.pageRows(), false),
        .move_file_start => doc.move(.file_start, false),
        .move_file_end => doc.move(.file_end, false),
        .select_left => doc.move(.left, true),
        .select_right => doc.move(.right, true),
        .select_word_left => doc.move(.word_left, true),
        .select_word_right => doc.move(.word_right, true),
        .select_line_start => doc.move(.line_start, true),
        .select_line_end => doc.move(.line_end, true),
        .select_up => view.moveVertical(doc, -1, true),
        .select_down => view.moveVertical(doc, 1, true),
        .select_page_up => view.moveVertical(doc, -view.pageRows(), true),
        .select_page_down => view.moveVertical(doc, view.pageRows(), true),
        .select_file_start => doc.move(.file_start, true),
        .select_file_end => doc.move(.file_end, true),
        .select_all => doc.selectAll(),
        .insert_newline => try doc.insertNewline(),
        .indent => try doc.indent(),
        .outdent => try doc.outdent(),
        .delete_left => try doc.delete(.left),
        .delete_right => try doc.delete(.right),
        .delete_word_left => try doc.delete(.word_left),
        .delete_word_right => try doc.delete(.word_right),
        .undo => _ = try doc.undo(),
        .redo => _ = try doc.redo(),
        .copy => return try editor.copy(),
        .cut => return try editor.cut(),
        .paste => return .paste,
        .open => return .{ .pick = .open_file },
        .open_folder => return .{ .pick = .open_folder },
        .close_folder => return editor.closeFolder(),
        .save => return editor.save(),
        .save_as => return .{ .pick = .save_file },
        .quit => return editor.quit(),
        .goto_line => return .{ .prompt = .goto_line },
        .find => return .{ .prompt = .find },
        .replace => return .{ .prompt = .replace },
        .find_next, .find_prev => {
            if (editor.find.needle.items.len == 0) return .{ .prompt = .find };
            if (!editor.find.step(doc, if (command == .find_next) .forward else .back)) editor.notify("Not found: {s}", .{editor.find.needle.items});
        },
        .replace_next => if (!try editor.find.replaceNext(doc)) editor.notify("Not found: {s}", .{editor.find.needle.items}),
        .replace_all => editor.notify("Replaced {d}", .{try editor.find.replaceAll(doc)}),
        .toggle_comment => try editor.toggleComment(),
        .goto_bracket => editor.gotoBracket(),
        .set_language => return .{ .prompt = .language },
        .toggle_match_case => editor.notify("Match case {s}", .{if (editor.find.toggle(.match_case)) "on" else "off"}),
        .toggle_whole_word => editor.notify("Whole word {s}", .{if (editor.find.toggle(.whole_word)) "on" else "off"}),
        .toggle_wrap => {
            view.setWrap(!view.wrap);
            editor.notify("Line wrap {s}", .{if (view.wrap) "on" else "off"});
        },
        .zoom_in => editor.setZoom(@as(i32, editor.zoom) + 1),
        .zoom_out => editor.setZoom(@as(i32, editor.zoom) - 1),
        .zoom_reset => editor.setZoom(editor.default_zoom),
        .open_settings => try editor.openSettings(),
        .next_theme => try editor.nextTheme(),
        .new_file => try editor.newTab(),
        .close_tab => return editor.closeTab(editor.pane.pane().active),
        .next_tab => editor.cycleTab(1),
        .prev_tab => editor.cycleTab(-1),
        .split_right => try editor.split(.right),
        .split_down => try editor.split(.down),
        .next_pane => try editor.cyclePane(1),
        .prev_pane => try editor.cyclePane(-1),
        .focus_sidebar => editor.focusArea(.sidebar),
        .focus_editor => editor.focusArea(.editor),
        .show_files => editor.showSide(.files),
        .show_git => editor.showSide(.git),
        .git_commit => try editor.commit(),
        .git_amend => editor.git.amend(),
        .show_changes => try editor.git.showFileChanges(editor.file()),
        .next_change => editor.jumpToChange(true),
        .prev_change => editor.jumpToChange(false),
        .revert_change => try editor.revertChange(),
        .toggle_blame => editor.toggleBlame(),
        .file_history => editor.fileHistory(),
        .toggle_terminal => editor.toggleTerminal(),
        .new_terminal => editor.openTerminal(),
    }
    return null;
}

const testing = std.testing;
const expectText = @import("../core/buffer.zig").expectText;

test "every command has a text name" {
    try testing.expectEqual(@as(?Command, .save), Command.fromName("save"));
    try testing.expectEqual(@as(?Command, .select_word_left), Command.fromName("select_word_left"));
    try testing.expectEqual(@as(?Command, null), Command.fromName("no_such_command"));
    try testing.expectEqualStrings("goto_line", @tagName(Command.goto_line));
}

test "run moves, selects and edits" {
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    try editor.doc().load("one two\nthree");

    _ = run(&editor, .move_word_right);
    _ = run(&editor, .select_line_end);
    try testing.expectEqual(@as(usize, 2), editor.tab().decorations.items.len);
    _ = run(&editor, .delete_left);
    _ = run(&editor, .insert_newline);
    _ = run(&editor, .indent);
    try expectText(&editor.doc().buffer, "one\n    \nthree");
    _ = run(&editor, .undo);
    _ = run(&editor, .undo);
    try expectText(&editor.doc().buffer, "one two\nthree");
    _ = run(&editor, .redo);
    try expectText(&editor.doc().buffer, "one\nthree");
}

test "page moves use the height of the view" {
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    try editor.doc().load("0\n1\n2\n3\n4\n5\n6\n7\n8\n9");
    editor.view().* = .{ .cols = 10, .rows = 4 };

    _ = run(&editor, .move_page_down);
    try testing.expectEqual(@as(usize, 6), editor.doc().cursor.pos);
    _ = run(&editor, .select_page_down);
    try testing.expectEqual(@as(usize, 12), editor.doc().cursor.pos);
    try testing.expectEqual(@as(usize, 4), editor.view().top.line);
    _ = run(&editor, .move_page_up);
    try testing.expectEqual(@as(usize, 6), editor.doc().cursor.pos);
}

test "commands that need the platform return a request" {
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    try editor.doc().load("text");

    try testing.expectEqualStrings("text", run(&editor, .copy).?.copy);
    try testing.expectEqual(Request.paste, run(&editor, .paste).?);
    try testing.expectEqual(Request{ .pick = .open_file }, run(&editor, .open).?);
    try testing.expectEqual(Request{ .pick = .open_folder }, run(&editor, .open_folder).?);
    try testing.expectEqual(Request{ .pick = .save_file }, run(&editor, .save_as).?);
    // No file yet: save asks for one.
    try testing.expectEqual(Request{ .pick = .save_file }, run(&editor, .save).?);
    try testing.expectEqual(Request.quit, run(&editor, .quit).?);
}

test "zoom and wrap commands" {
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    _ = run(&editor, .zoom_in);
    _ = run(&editor, .zoom_in);
    try testing.expectEqual(@as(u8, 3), editor.zoom);
    _ = run(&editor, .zoom_out);
    try testing.expectEqual(@as(u8, 2), editor.zoom);
    _ = run(&editor, .zoom_reset);
    try testing.expectEqual(@as(u8, 1), editor.zoom);

    _ = run(&editor, .toggle_wrap);
    try testing.expect(editor.view().wrap);
    try testing.expectEqualStrings("Line wrap on", editor.lastMessage().?);
}

test "tab and pane commands" {
    var editor = try Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    // The first new file takes the place of the placeholder.
    _ = run(&editor, .new_file);
    _ = run(&editor, .new_file);
    _ = run(&editor, .new_file);
    const pane = editor.pane.pane();
    try testing.expectEqual(@as(usize, 3), pane.tabs.items.len);
    try testing.expectEqual(@as(usize, 2), pane.active);
    _ = run(&editor, .next_tab);
    try testing.expectEqual(@as(usize, 0), pane.active);
    _ = run(&editor, .prev_tab);
    try testing.expectEqual(@as(usize, 2), pane.active);
    _ = run(&editor, .close_tab);
    try testing.expectEqual(@as(usize, 2), editor.files.items.len);

    _ = run(&editor, .split_down);
    try testing.expectEqual(panes.Axis.down, editor.root.kind.split.axis);
    _ = run(&editor, .prev_pane);
    try testing.expectEqual(editor.root.kind.split.first, editor.pane);
}
