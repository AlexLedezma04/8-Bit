//! Picks a file's grammar from the loaded ones: by file name (`Makefile`),
//! then extension, then the program after `#!` on the first line.
const std = @import("std");
const Rules = @import("grammar.zig").Rules;

pub fn detect(languages: []const Rules, path: []const u8, first_line: []const u8) ?*const Rules {
    const name = std.fs.path.basename(path);
    for (languages) |*rules| {
        if (anyEql(rules.grammar.file_names, name)) return rules;
    }
    const dot = std.mem.findScalarLast(u8, name, '.') orelse name.len;
    if (dot > 0 and dot + 1 < name.len) for (languages) |*rules| {
        if (anyEql(rules.grammar.extensions, name[dot + 1 ..])) return rules;
    };
    const program = shebang(first_line) orelse return null;
    for (languages) |*rules| for (rules.grammar.shebangs) |word| {
        if (std.mem.startsWith(u8, program, word)) return rules;
    };
    return null;
}

pub fn byName(languages: []const Rules, name: []const u8) ?*const Rules {
    for (languages) |*rules| if (std.ascii.eqlIgnoreCase(rules.grammar.name, name)) return rules;
    return null;
}

fn anyEql(list: []const []const u8, text: []const u8) bool {
    for (list) |item| if (std.ascii.eqlIgnoreCase(item, text)) return true;
    return false;
}

/// `python3` from `#!/usr/bin/python3` or `#!/usr/bin/env python3`.
fn shebang(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "#!")) return null;
    var words = std.mem.tokenizeAny(u8, line[2..], " \t\r");
    const first = std.fs.path.basenamePosix(words.next() orelse return null);
    if (!std.mem.eql(u8, first, "env")) return first;
    while (words.next()) |word| if (word[0] != '-') return word;
    return null;
}

const testing = std.testing;

test "file name, then extension, then shebang" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const languages = [_]Rules{
        try Rules.init(a, .{ .name = "Makefile", .file_names = &.{ "Makefile", "GNUmakefile" }, .extensions = &.{"mk"} }),
        try Rules.init(a, .{ .name = "Python", .extensions = &.{ "py", "pyw" }, .shebangs = &.{"python"} }),
        try Rules.init(a, .{ .name = "Shell", .extensions = &.{"sh"}, .shebangs = &.{ "sh", "bash" } }),
    };
    try testing.expectEqualStrings("Makefile", detect(&languages, "src/makefile", "").?.grammar.name);
    try testing.expectEqualStrings("Makefile", detect(&languages, "rules.MK", "").?.grammar.name);
    try testing.expectEqualStrings("Python", detect(&languages, "/a.b/tool.py", "#!/bin/sh").?.grammar.name);
    try testing.expectEqualStrings("Python", detect(&languages, "tool", "#!/usr/bin/env -S python3 -u").?.grammar.name);
    try testing.expectEqualStrings("Shell", detect(&languages, "run", "#! /bin/bash").?.grammar.name);
    try testing.expectEqual(@as(?*const Rules, null), detect(&languages, "notes.txt", "hello"));
    try testing.expectEqual(@as(?*const Rules, null), detect(&languages, ".py", ""));
    try testing.expectEqualStrings("Shell", byName(&languages, "shell").?.grammar.name);
}
