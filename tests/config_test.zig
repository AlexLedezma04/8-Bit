//! End to end without SDL: settings, themes and key bindings from a real
//! config folder, through the same calls `main.zig` makes.
const std = @import("std");
const app = @import("8-bit");

const testing = std.testing;
const Editor = app.editor.editor.Editor;
const run = app.editor.commands.run;
const keymap = app.editor.keymap;
const theme = app.ui.theme;
const fs = app.platform.fs;
const expectText = app.core.buffer.expectText;

/// An editor whose config folder is a temporary folder.
const Session = struct {
    tmp: testing.TmpDir,
    editor: Editor,
    dir: [128]u8 = undefined,
    path_buffer: [192]u8 = undefined,

    fn init(self: *Session) !void {
        self.* = .{ .tmp = testing.tmpDir(.{}), .editor = try Editor.init(testing.allocator, testing.io) };
        self.editor.loader.dir = std.fmt.bufPrint(&self.dir, ".zig-cache/tmp/{s}", .{self.tmp.sub_path}) catch unreachable;
        self.editor.reloadConfig();
    }

    fn deinit(self: *Session) void {
        self.editor.deinit();
        self.tmp.cleanup();
    }

    fn path(self: *Session, name: []const u8) []const u8 {
        return std.fmt.bufPrint(&self.path_buffer, "{s}/{s}", .{ self.editor.loader.dir.?, name }) catch unreachable;
    }

    fn write(self: *Session, name: []const u8, text: []const u8) !void {
        try fs.write(testing.io, self.path(name), &.{text});
    }

    fn read(self: *Session, name: []const u8) ![:0]u8 {
        return fs.read(testing.io, testing.allocator, self.path(name));
    }

    /// Replaces the open document's text, as if typed after Ctrl+A.
    fn retype(self: *Session, text: []const u8) void {
        _ = run(&self.editor, .select_all);
        self.editor.paste(text);
    }

    fn press(self: *Session, key: []const u8) ?app.editor.editor.Request {
        const combo = keymap.parseKey(key).?;
        return run(&self.editor, keymap.lookup(self.editor.bindings, combo.key, combo.mods).?);
    }

    fn loadTheme(self: *Session) theme.Theme {
        return theme.load(self.editor.loader, self.editor.config_arena.allocator(), self.editor.settings.theme, &self.editor);
    }
};

test "open settings with Ctrl+, , change them, save, and they apply at once" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    const editor = &session.editor;

    // The first time, the file is made from the built-in settings.
    _ = session.press("ctrl+,");
    try testing.expectEqualStrings("settings.zon", editor.name());
    const text = try session.read("settings.zon");
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, ".tab_width = 4,") != null);
    try testing.expectEqual(true, editor.settings.line_numbers);

    session.retype(".{ .tab_width = 2, .use_spaces = false, .wrap = true, .zoom = 3, .line_numbers = false, .undo_limit_mb = 1 }");
    _ = session.press("ctrl+s");
    try testing.expectEqualStrings("Saved settings.zon", editor.currentMessage().?);
    try testing.expectEqual(@as(usize, 2), editor.doc().tab_width);
    try testing.expect(!editor.doc().soft_tabs);
    try testing.expect(editor.view().wrap);
    try testing.expectEqual(@as(u8, 3), editor.zoom);
    try testing.expect(!editor.settings.line_numbers);
    try testing.expectEqual(@as(usize, 1 << 20), editor.doc().history.max_size);
    // Left out of the file: the built-in value.
    try testing.expectEqualStrings("dark", editor.settings.theme);

    // Tab now inserts a tab character.
    _ = session.press("ctrl+end");
    _ = session.press("tab");
    try testing.expectEqual(@as(u8, '\t'), editor.doc().buffer.charAt(editor.doc().buffer.len() - 1).cp);
}

test "a bad settings file reports its line and keeps the defaults" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    const editor = &session.editor;

    try session.write("settings.zon", ".{\n    .tab_width = 2,\n    .wrap = \"yes\",\n}");
    editor.reloadConfig();
    try testing.expectStringStartsWith(editor.currentMessage().?, "settings.zon:3: ");
    try testing.expectEqual(@as(usize, 4), editor.doc().tab_width);
    try testing.expect(!editor.view().wrap);
}

test "Alt+T switches themes, the settings file remembers it, and user themes join in" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    const editor = &session.editor;

    try testing.expectEqual(app.ui.theme.Color.rgb(0x1e1f22), session.loadTheme().background);
    _ = session.press("alt+t");
    try testing.expectEqualStrings("Theme: light", editor.currentMessage().?);
    try testing.expectEqualStrings("light", editor.settings.theme);
    try testing.expectEqual(app.ui.theme.Color.rgb(0xf8f8f4), session.loadTheme().background);
    const text = try session.read("settings.zon");
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, ".theme = \"light\",") != null);
    // The comments of the file are kept.
    try testing.expect(std.mem.indexOf(u8, text, "// Columns between tab stops") != null);

    // A user theme with one color; the rest comes from the dark theme.
    try session.write("themes/mine.zon", ".{ .text = 0xff0000 }");
    _ = session.press("alt+t");
    try testing.expectEqualStrings("mine", editor.settings.theme);
    const mine = session.loadTheme();
    try testing.expectEqual(app.ui.theme.Color.rgb(0xff0000), mine.text);
    try testing.expectEqual(app.ui.theme.Color.rgb(0x1e1f22), mine.background);

    _ = session.press("alt+t");
    try testing.expectEqualStrings("dark", editor.settings.theme);

    // A theme that does not exist: a message and the dark theme.
    try session.write("settings.zon", ".{ .theme = \"gone\" }");
    editor.reloadConfig();
    try testing.expectEqual(app.ui.theme.Color.rgb(0x1e1f22), session.loadTheme().background);
    try testing.expectEqualStrings("No themes/gone.zon", editor.currentMessage().?);
}

test "keymap.zon bindings win over the defaults; bad names show a message" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    const editor = &session.editor;
    try editor.doc().load("one\ntwo");

    try session.write("keymap.zon",
        \\.{
        \\    .{ .key = "ctrl+shift+k", .command = "select_all" },
        \\    .{ .key = "ctrl+a", .command = "move_file_end" },
        \\}
    );
    editor.reloadConfig();
    _ = session.press("ctrl+shift+k");
    try testing.expectEqual(@as(usize, 7), editor.doc().cursor.selection().len());
    _ = session.press("ctrl+a");
    try testing.expectEqual(@as(usize, 0), editor.doc().cursor.selection().len());
    try testing.expectEqual(@as(usize, 7), editor.doc().cursor.pos);
    // Defaults still work.
    _ = session.press("ctrl+home");
    try testing.expectEqual(@as(usize, 0), editor.doc().cursor.pos);

    try session.write("keymap.zon", ".{ .{ .key = \"hyper+x\", .command = \"save\" } }");
    editor.reloadConfig();
    try testing.expectEqualStrings("keymap.zon: unknown key \"hyper+x\"", editor.currentMessage().?);
    try session.write("keymap.zon", ".{ .{ .key = \"f5\", .command = \"fly\" } }");
    editor.reloadConfig();
    try testing.expectEqualStrings("keymap.zon: unknown command \"fly\"", editor.currentMessage().?);
    try testing.expectEqual(keymap.default.len, editor.bindings.len);
    try expectText(&editor.doc().buffer, "one\ntwo");
}
