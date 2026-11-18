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
    // Made after the file tree was read, so only the shell shows it.
    try session.write("only-here.txt", "");

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
    editor.open(session.path("b.txt"));
    session.typeKeys("abc");
    try testing.expect(session.shows("abcbee"));
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

    // The close button is right after the title.
    const tab = textAt(&session, "Terminal 1");
    _ = session.click(tab.x + app.ui.layout.Metrics.init(1).labelWidth("Terminal 1") + 8, tab.y + 8);
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

    // The number of a closed terminal is free again.
    _ = session.press("ctrl+`");
    try testing.expect(session.shows("Terminal 1"));
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

test "the terminal button in the status bar and Alt+T show and hide the terminal" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    const editor = &session.editor;
    editor.open(session.path("b.txt"));
    session.draw();
    // An icon, not a word; its frame is drawn in the status bar text color.
    try testing.expect(!session.inStatusBar("Terminal"));
    const button = app.ui.status_bar.terminalButton(.init(1), session.workbench.frame().status);
    const icon_color = session.workbench.theme.status_bar_text;
    try testing.expect(session.recorder.filled(icon_color) >= 4);

    _ = session.click(button.x + button.w / 2, button.y + button.h / 2);
    try testing.expect(editor.bottom.shown);
    // The tabs of the terminals take one compact row.
    const bottom = session.workbench.frame().bottom.?;
    const tab = session.last("Terminal 1").?;
    try testing.expect(tab.y >= bottom.y and tab.y + 16 <= bottom.y + 24);
    try testing.expectEqual(@as(usize, 1), editor.terminals.list.items.len);
    // Hidden again even when the editor has focus.
    _ = session.click(500, 100);
    try testing.expectEqual(Area.editor, editor.focus);
    _ = session.click(button.x + button.w / 2, button.y + button.h / 2);
    try testing.expect(!editor.bottom.shown);

    _ = session.press("alt+t");
    try testing.expect(editor.bottom.shown);
    try testing.expectEqual(Area.bottom, editor.focus);
    // Alt+T works from inside the terminal too.
    _ = session.press("alt+t");
    try testing.expect(!editor.bottom.shown);
    try testing.expectEqual(@as(usize, 1), editor.terminals.list.items.len);
}

test "a repository made or deleted in the terminal shows up once its output rests" {
    if (windows) return error.SkipZigTest;
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    const editor = &session.editor;

    _ = session.press("ctrl+`");
    run(&session, "rm -rf .git && touch made.txt && " ++ comptime echo("gone", "now"));
    try session.waitForTerminal("gone-now");
    // Not yet: the output must rest first.
    try testing.expect(editor.git.ready());
    editor.now_ms += 1000;
    _ = session.waitForGit();
    try testing.expect(!editor.git.ready());
    try testing.expect(session.last("Git") == null);
    try testing.expect(session.shows("made.txt"));

    run(&session, "git init -q -b main && " ++ comptime echo("back", "again"));
    try session.waitForTerminal("back-again");
    editor.now_ms += 1000;
    _ = session.waitForGit();
    try testing.expect(editor.git.ready());
    try testing.expect(session.last("Git") != null);
    try testing.expect(session.inStatusBar("main"));
}

test "the + button opens more terminals; numbers are reused, smallest first" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    const terminals = &session.editor.terminals;
    _ = session.press("alt+t");

    // The + comes right after the last tab.
    for (0..2) |_| {
        const bottom = session.workbench.frame().bottom.?;
        const last = session.last(terminals.list.items[terminals.list.items.len - 1].name()).?;
        const plus_x = last.x + app.ui.layout.Metrics.init(1).labelWidth("Terminal 1") + 3 * 8 + 12;
        try testing.expect(plus_x < bottom.x + bottom.w);
        _ = session.click(plus_x, bottom.y + 12);
    }
    try testing.expectEqual(@as(usize, 3), terminals.list.items.len);
    try testing.expectEqual(@as(usize, 2), terminals.active);
    try testing.expect(session.shows("Terminal 3"));

    // Close Terminal 2: the next one is Terminal 2 again, then 4.
    session.editor.closeTerminal(1);
    session.editor.openTerminal();
    try testing.expectEqualStrings("Terminal 2", terminals.list.items[2].name());
    session.editor.openTerminal();
    try testing.expectEqualStrings("Terminal 4", terminals.list.items[3].name());
    session.draw();
    for ([_][]const u8{ "Terminal 1", "Terminal 3", "Terminal 2", "Terminal 4" }) |name| try testing.expect(session.shows(name));
}

/// `stty size` says the rows and columns that fill the panel below its tabs.
fn expectShellFillsPanel(session: *Session) !void {
    const metrics: app.ui.layout.Metrics = .init(1);
    const bottom = session.workbench.frame().bottom.?;
    const rows = metrics.rows(bottom.h - app.ui.tabs.height(metrics, .compact));
    var buffer: [32]u8 = undefined;
    run(session, "echo size-$(stty size)");
    try session.waitForTerminal(try std.fmt.bufPrint(&buffer, "size-{d} {d}", .{ rows, metrics.cols(bottom.w) }));
}

test "the shell gets the size of the panel, and the new one after a resize" {
    if (windows) return error.SkipZigTest;
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    _ = session.press("ctrl+`");
    try expectShellFillsPanel(&session);
    session.editor.bottom.size = 25;
    session.draw();
    try expectShellFillsPanel(&session);
}
