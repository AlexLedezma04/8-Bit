//! The colors the UI uses. Their values live in theme files (assets/themes
//! and the user's themes folder); a file is written as hex numbers.
const std = @import("std");
const config = @import("../editor/config.zig");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn rgb(hex: u24) Color {
        return .{ .r = @truncate(hex >> 16), .g = @truncate(hex >> 8), .b = @truncate(hex) };
    }

    pub const fromZon = rgb;
};

pub const Theme = struct {
    background: Color,
    text: Color,
    cursor: Color,
    selection: Color,
    search_match: Color,
    matching_bracket: Color,
    current_line: Color,

    gutter: Color,
    line_number: Color,
    line_number_current: Color,

    status_bar: Color,
    status_bar_text: Color,
    unsaved: Color,

    /// Background of the sidebar, the bottom panel and their tab bars.
    panel: Color,
    tab_text: Color,
    tab_active_text: Color,

    border: Color,
    accent: Color,
    /// Under the mouse.
    hover: Color,
    /// The selected row of the focused list, and of the others.
    list_selection: Color,
    list_inactive: Color,
    /// Background of context menus.
    menu: Color,

    git_added: Color,
    git_changed: Color,
    git_removed: Color,
    git_untracked: Color,
    /// Line backgrounds of a diff view.
    diff_added: Color,
    diff_removed: Color,

    syntax: Syntax,
    terminal: Ansi,

    /// The color of a file with this git status.
    pub fn gitColor(self: *const Theme, kind: GitKind) Color {
        return switch (kind) {
            .modified, .renamed => self.git_changed,
            .added => self.git_added,
            .deleted => self.git_removed,
            .untracked, .conflict => self.git_untracked,
            .ignored => self.line_number,
        };
    }

    /// The color of a decoration.
    pub fn styleColor(self: *const Theme, style: DecorationStyle) Color {
        return switch (style) {
            .selection => self.selection,
            .current_line => self.current_line,
            .match => self.search_match,
            .bracket => self.matching_bracket,
            .added => self.git_added,
            .changed => self.git_changed,
            .removed => self.git_removed,
            .diff_added => self.diff_added,
            .diff_removed => self.diff_removed,
            .diff_header => self.panel,
        };
    }
};

const GitKind = @import("../git/status.zig").Kind;
const DecorationStyle = @import("../editor/decoration.zig").Style;

pub const Syntax = struct {
    comment: Color,
    keyword: Color,
    string: Color,
    number: Color,
    constant: Color,
    type: Color,
    builtin: Color,
    function: Color,
    operator: Color,
    punctuation: Color,
};

/// The 16 colors terminal programs pick by number, in that order.
pub const Ansi = struct {
    black: Color,
    red: Color,
    green: Color,
    yellow: Color,
    blue: Color,
    magenta: Color,
    cyan: Color,
    white: Color,
    bright_black: Color,
    bright_red: Color,
    bright_green: Color,
    bright_yellow: Color,
    bright_blue: Color,
    bright_magenta: Color,
    bright_cyan: Color,
    bright_white: Color,

    pub fn get(self: *const Ansi, index: u4) Color {
        return switch (index) {
            inline else => |i| @field(self, @typeInfo(Ansi).@"struct".field_names[i]),
        };
    }
};

const folder = config.theme_folder;

/// The theme `name`. Colors it leaves out come from the dark theme.
pub fn load(loader: config.Loader, arena: std.mem.Allocator, name: []const u8, notifier: anytype) Theme {
    const base = config.builtin(Theme, loader.gpa, arena, folder ++ "/dark");
    const file = std.fmt.allocPrint(arena, folder ++ "/{s}", .{name}) catch return base;
    return loader.load(Theme, arena, file, base, notifier);
}

const testing = std.testing;

test "rgb splits a hex color" {
    try testing.expectEqual(Color{ .r = 0x12, .g = 0x34, .b = 0x56, .a = 255 }, Color.rgb(0x123456));
}

test "built-in themes set every color" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const dark = config.builtin(Theme, testing.allocator, arena.allocator(), "themes/dark");
    const light = config.builtin(Theme, testing.allocator, arena.allocator(), "themes/light");
    try testing.expectEqual(Color.rgb(0x1e1f22), dark.background);
    try testing.expectEqual(Color.rgb(0xffffff), light.background);
    try testing.expectEqual(dark.terminal.red, dark.terminal.get(1));
    try testing.expectEqual(dark.terminal.bright_white, dark.terminal.get(15));
}

test "a theme that leaves colors out gets them from the default theme" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, folder);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "themes/mine.zon", .data = ".{ .text = 0xff0000, .syntax = .{ .keyword = 0x00ff00 } }" });
    const loader: config.Loader = .{
        .io = testing.io,
        .gpa = testing.allocator,
        .dir = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{tmp.sub_path}),
    };

    var notifier: config.TestNotifier = .{};
    const mine = load(loader, arena.allocator(), "mine", &notifier);
    try testing.expectEqual(Color.rgb(0xff0000), mine.text);
    try testing.expectEqual(Color.rgb(0x00ff00), mine.syntax.keyword);
    try testing.expectEqual(Color.rgb(0x1e1f22), mine.background);
    try testing.expectEqual(Color.rgb(0x7a7e85), mine.syntax.comment);

    const light = load(loader, arena.allocator(), "light", &notifier);
    try testing.expectEqual(Color.rgb(0xffffff), light.background);
    try testing.expectEqualStrings("", notifier.message);
}
