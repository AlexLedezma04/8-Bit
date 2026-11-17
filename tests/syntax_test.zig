//! Every built-in grammar loads without errors and highlights its sample in
//! tests/samples, which is found by file name, extension or shebang.
const std = @import("std");
const app = @import("8-bit");
const Session = @import("session.zig").Session;

const testing = std.testing;
const syntax = app.syntax.syntax;
const language = app.syntax.language;

test "every grammar loads and highlights its sample" {
    var editor = try app.editor.editor.Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    try testing.expectEqual(@as(?[]const u8, null), editor.lastMessage());
    const languages = editor.languages;
    try testing.expectEqual(@as(usize, 96), languages.len);

    const covered = try testing.allocator.alloc(bool, languages.len);
    defer testing.allocator.free(covered);
    @memset(covered, false);
    var spans: std.ArrayList(syntax.Span) = .empty;
    defer spans.deinit(testing.allocator);

    var dir = try std.Io.Dir.cwd().openDir(testing.io, "tests/samples", .{ .iterate = true });
    defer dir.close(testing.io);
    var entries = dir.iterate();
    while (try entries.next(testing.io)) |entry| {
        const text = try dir.readFileAlloc(testing.io, entry.name, testing.allocator, .unlimited);
        defer testing.allocator.free(text);
        const head = text[0..@min(text.len, language.head_size)];
        const rules = language.detect(languages, entry.name, head) orelse {
            std.debug.print("no language for {s}\n", .{entry.name});
            return error.NoLanguage;
        };
        covered[(@intFromPtr(rules) - @intFromPtr(languages.ptr)) / @sizeOf(@TypeOf(rules.*))] = true;

        var state: syntax.State = 0;
        var styled: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            state = try syntax.tokenize(testing.allocator, rules, line, state, &spans);
            var end: usize = 0;
            for (spans.items) |span| {
                try testing.expect(span.start >= end and span.start < span.end and span.end <= line.len);
                end = span.end;
            }
            styled += spans.items.len;
        }
        if (state != 0) std.debug.print("{s} ends inside a string or comment\n", .{entry.name});
        try testing.expectEqual(@as(syntax.State, 0), state);
        try testing.expect(styled > 0);
    }
    for (covered, languages) |seen, rules| {
        if (!seen) std.debug.print("no sample for {s}\n", .{rules.grammar.name});
        try testing.expect(seen);
    }
}

test "no file name is claimed twice; a shared extension has one grammar without hints" {
    var editor = try app.editor.editor.Editor.init(testing.allocator, testing.io);
    defer editor.deinit();
    const languages = editor.languages;
    for (languages, 0..) |a, i| for (languages[i + 1 ..]) |b| {
        for (a.grammar.file_names) |name| for (b.grammar.file_names) |other| {
            if (std.ascii.eqlIgnoreCase(name, other)) std.debug.print("{s} and {s} both claim {s}\n", .{ a.grammar.name, b.grammar.name, name });
            try testing.expect(!std.ascii.eqlIgnoreCase(name, other));
        };
        for (a.grammar.extensions) |ext| for (b.grammar.extensions) |other| {
            if (!std.ascii.eqlIgnoreCase(ext, other)) continue;
            const bare = a.grammar.hints.len == 0 and b.grammar.hints.len == 0;
            if (bare) std.debug.print("{s} and {s} share .{s} without hints\n", .{ a.grammar.name, b.grammar.name, ext });
            try testing.expect(!bare);
        };
    };
}

fn colorOf(session: *const Session, text: []const u8) app.ui.theme.Color {
    return (session.recorder.find(text) orelse std.debug.panic("not on screen: {s}", .{text})).color;
}

fn bracketCount(session: *const Session) usize {
    var count: usize = 0;
    for (session.editor.tab().decorations.items) |item| {
        if (item.kind == .text_background and item.kind.text_background == .bracket) count += 1;
    }
    return count;
}

test "the window draws colors, the language, brackets; comments and languages by key" {
    var session: Session = undefined;
    try session.init();
    defer session.deinit();
    const editor = &session.editor;
    try session.write("main.zig", "const x = \"hi\"; // note\nfn f(a: u8) void {}\n");
    editor.open(session.path("main.zig"));
    session.draw();
    const colors = session.workbench.theme.syntax;

    try testing.expect(session.shows("Zig"));
    try testing.expectEqual(colors.keyword, colorOf(&session, "const"));
    try testing.expectEqual(colors.string, colorOf(&session, "\"hi\""));
    try testing.expectEqual(colors.comment, colorOf(&session, "// note"));
    try testing.expectEqual(colors.type, colorOf(&session, "u8"));

    // The cursor before `(` marks it and its partner; a key jumps there.
    editor.doc().cursor = .{ .pos = 28 };
    _ = session.press("left");
    _ = session.press("right");
    try testing.expectEqual(@as(usize, 2), bracketCount(&session));
    _ = session.press("ctrl+shift+m");
    try testing.expectEqual(@as(usize, 34), editor.doc().cursor.pos);

    // Ctrl+/ comments the line; Ctrl+Shift+7 (where / is Shift+7) uncomments.
    _ = session.press("ctrl+/");
    try testing.expect(session.shows("// fn f"));
    _ = session.press("ctrl+shift+7");
    try testing.expect(!session.shows("// fn f"));
    _ = session.press("ctrl+z");
    try testing.expect(session.shows("// fn f"));

    // Pick a language by hand.
    _ = session.press("alt+l");
    try testing.expect(session.shows("Language:"));
    session.typeKeys("pyth");
    _ = session.press("down");
    _ = session.press("enter");
    try testing.expect(session.shows("Python"));
    try testing.expectEqual(session.workbench.theme.text, colorOf(&session, "const"));
    _ = session.press("alt+l");
    session.typeKeys("nope");
    _ = session.press("enter");
    try testing.expectEqualStrings("No language named nope", session.editor.lastMessage().?);
}
