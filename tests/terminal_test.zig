//! End to end: terminals in the bottom panel with a real shell behind them
//! (/bin/sh, or cmd.exe on Windows), driven by key, text and mouse events.
const std = @import("std");
const builtin = @import("builtin");
const app = @import("8-bit");
const Session = @import("session.zig").Session;

const testing = std.testing;
const Area = app.editor.editor.Area;
const Request = app.editor.editor.Request;
const windows = builtin.os.tag == .windows;

/// A command that prints `first-second`, while the command line itself
/// does not show it, so the screen tells the two apart.
fn echo(comptime first: []const u8, comptime second: []const u8) []const u8 {
    return if (windows) "echo " ++ first ++ "^-" ++ second else "echo " ++ first ++ "''-" ++ second;
}

fn run(session: *Session, command: []const u8) void {
    session.typeKeys(command);
    _ = session.press("enter");
}

/// The drawn text that is exactly `text`.
fn textAt(session: *const Session, text: []const u8) app.ui.canvas.Recorder.Text {
    for (session.recorder.texts.items) |item| if (std.mem.eql(u8, item.text, text)) return item;
    std.debug.panic("not on screen: {s}", .{text});
}

test "Ctrl+` starts a shell in the folder; keys and text go to it" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    const editor = &session.editor;
    try session.write("only-here.txt", "");
    // The file tree would show the file names too.
    _ = session.press("ctrl+b");

    _ = session.press("ctrl+`");
    try testing.expectEqual(Area.bottom, editor.focus);
    try testing.expect(session.shows("Terminal 1"));
    run(&session, echo("8bit", "ok"));
    try session.waitForTerminal("8bit-ok");
    run(&session, if (windows) "dir /b" else "ls");
    try session.waitForTerminal("only-here.txt");

    // Escape is the shell's; window keys still work.
    _ = session.press("escape");
    try testing.expectEqual(Area.bottom, editor.focus);
    _ = session.press("ctrl+`");
    try testing.expect(!editor.bottom.shown);
    try testing.expectEqual(Area.editor, editor.focus);
    // Typing in the editor does not reach the shell.
    session.typeKeys("abc");
    try testing.expect(session.shows("abc"));
    _ = session.press("ctrl+`");
    try testing.expectEqual(@as(usize, 1), editor.terminals.list.items.len);
    try testing.expect(session.shows("8bit-ok"));
}

test "tabs: a second terminal, Ctrl+Tab switches, the close button stops one" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    const terminals = &session.editor.terminals;
    _ = session.press("ctrl+`");
    run(&session, echo("first", "one"));
    try session.waitForTerminal("first-one");

    _ = session.press("ctrl+shift+`");
    try testing.expectEqual(@as(usize, 2), terminals.list.items.len);
    try testing.expectEqual(@as(usize, 1), terminals.active);
    try testing.expect(session.shows("Terminal 2"));
    try testing.expect(!session.shows("first-one"));
    _ = session.press("ctrl+tab");
    try testing.expectEqual(@as(usize, 0), terminals.active);
    try testing.expect(session.shows("first-one"));

    // The close button is two cells after the title.
    const tab = textAt(&session, "Terminal 1");
    _ = session.click(tab.x + ("Terminal 1".len + 1) * 8 + 4, tab.y + 8);
    try testing.expectEqual(@as(usize, 1), terminals.list.items.len);
    try testing.expect(session.shows("Terminal 2"));
    try testing.expect(!session.shows("Terminal 1"));
}

test "drag selects and Ctrl+Shift+C copies; Ctrl+Shift+V pastes; the wheel scrolls back" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    session.editor.bottom.size = 30;
    _ = session.press("ctrl+`");
    run(&session, echo("8bit", "ok"));
    try session.waitForTerminal("8bit-ok");

    const output = textAt(&session, "8bit-ok");
    // Right to left: the left edge is next to the sidebar's resize grip.
    session.drag(output.x + 7 * 8 + 1, output.y + 8, output.x + 6, output.y + 8);
    const copied = session.press("ctrl+shift+c").?;
    try testing.expectEqualStrings("8bit-ok", copied.copy);

    try testing.expectEqual(Request.paste, session.press("ctrl+shift+v").?);
    session.workbench.paste(comptime echo("was", "pasted") ++ "\n");
    try session.waitForTerminal("was-pasted");

    run(&session, if (windows) "for /L %i in (1,1,60) do @echo L%i." else "seq -f L%g. 1 60");
    try session.waitForTerminal("L60.");
    try testing.expect(!session.shows("L1."));
    const line = textAt(&session, "L60.");
    for (0..40) |_| _ = session.send(.{ .wheel = .{ .x = line.x, .y = line.y, .dx = 0, .dy = 1, .mods = .{} } });
    try testing.expect(session.shows("L1."));
    try testing.expect(!session.shows("L60."));
    // Typing goes back to the bottom.
    session.typeKeys("x");
    try testing.expect(session.shows("L60."));
}

test "a shell that exits says so, Enter closes it, Ctrl+` starts a new one" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    const editor = &session.editor;
    _ = session.press("ctrl+`");
    run(&session, "exit");
    try session.waitForTerminal("[Process ended. Enter closes it.]");
    _ = session.press("enter");
    try testing.expectEqual(@as(usize, 0), editor.terminals.list.items.len);
    try testing.expect(!editor.bottom.shown);
    try testing.expectEqual(Area.editor, editor.focus);

    _ = session.press("ctrl+`");
    try testing.expect(session.shows("Terminal 2"));
    run(&session, echo("new", "shell"));
    try session.waitForTerminal("new-shell");
}

test "colors and the alternate screen of a real program" {
    // cmd.exe has no printf; the parser and grid tests cover this on Windows.
    if (windows) return error.SkipZigTest;
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    _ = session.press("ctrl+`");
    // The quotes keep the words of the command line apart from the output.
    run(&session, "printf '\\033[1;31mre''d\\033[0m \\033[38;2;1;2;3mrg''b\\033[0m\\n'");
    try session.waitForTerminal("rgb");
    const theme = &session.workbench.theme;
    try testing.expectEqual(theme.terminal.bright_red, textAt(&session, "red").color);
    try testing.expectEqual(app.ui.theme.Color.rgb(0x010203), textAt(&session, "rgb").color);

    run(&session, "printf '\\033[?1049h\\033[Hfull''screen'");
    try session.waitForTerminal("fullscreen");
    try testing.expect(session.editor.terminals.current().?.session.grid.alternate);
    try testing.expect(!session.shows("rgb"));
    run(&session, "printf '\\033[?1049l'");
    try session.waitForTerminal("rgb");
    try testing.expect(!session.shows("fullscreen"));
}
