//! Key bindings: the default table from key combos to commands, and the
//! user's bindings from `keymap.zon`, which win over the defaults.
const std = @import("std");
const event = @import("../platform/event.zig");
const Key = event.Key;
const Mods = event.Mods;
const KeyPress = event.KeyPress;
const Command = @import("commands.zig").Command;

pub const Binding = struct { key: Key, mods: Mods = .{}, command: Command };

/// One binding of `keymap.zon`, by name: `.{ .key = "ctrl+shift+k", .command = "save" }`.
pub const Entry = struct { key: []const u8, command: []const u8 };

const ctrl: Mods = .{ .ctrl = true };
const shift: Mods = .{ .shift = true };
const alt: Mods = .{ .alt = true };
const ctrl_shift: Mods = .{ .ctrl = true, .shift = true };
const alt_shift: Mods = .{ .alt = true, .shift = true };

/// Cursor moves. Each one also gets a Shift binding that selects.
const moves = [_]Binding{
    .{ .key = .left, .command = .move_left },
    .{ .key = .right, .command = .move_right },
    .{ .key = .up, .command = .move_up },
    .{ .key = .down, .command = .move_down },
    .{ .key = .home, .command = .move_line_start },
    .{ .key = .end, .command = .move_line_end },
    .{ .key = .page_up, .command = .move_page_up },
    .{ .key = .page_down, .command = .move_page_down },
    .{ .key = .left, .mods = ctrl, .command = .move_word_left },
    .{ .key = .right, .mods = ctrl, .command = .move_word_right },
    .{ .key = .home, .mods = ctrl, .command = .move_file_start },
    .{ .key = .end, .mods = ctrl, .command = .move_file_end },
};

const others = [_]Binding{
    .{ .key = .char('a'), .mods = ctrl, .command = .select_all },
    .{ .key = .enter, .command = .insert_newline },
    .{ .key = .enter, .mods = shift, .command = .insert_newline },
    .{ .key = .tab, .command = .indent },
    .{ .key = .tab, .mods = shift, .command = .outdent },
    .{ .key = .backspace, .command = .delete_left },
    .{ .key = .backspace, .mods = shift, .command = .delete_left },
    .{ .key = .delete, .command = .delete_right },
    .{ .key = .backspace, .mods = ctrl, .command = .delete_word_left },
    .{ .key = .delete, .mods = ctrl, .command = .delete_word_right },
    .{ .key = .char('z'), .mods = ctrl, .command = .undo },
    .{ .key = .char('y'), .mods = ctrl, .command = .redo },
    .{ .key = .char('z'), .mods = ctrl_shift, .command = .redo },
    .{ .key = .char('c'), .mods = ctrl, .command = .copy },
    .{ .key = .char('x'), .mods = ctrl, .command = .cut },
    .{ .key = .char('v'), .mods = ctrl, .command = .paste },
    .{ .key = .char('s'), .mods = ctrl, .command = .save },
    .{ .key = .char('s'), .mods = ctrl_shift, .command = .save_as },
    .{ .key = .char('o'), .mods = ctrl, .command = .open },
    .{ .key = .char('o'), .mods = ctrl_shift, .command = .open_folder },
    .{ .key = .char('q'), .mods = ctrl, .command = .quit },
    .{ .key = .char('z'), .mods = alt, .command = .toggle_wrap },
    .{ .key = .char('='), .mods = ctrl, .command = .zoom_in },
    .{ .key = .char('+'), .mods = ctrl, .command = .zoom_in },
    .{ .key = .char('='), .mods = ctrl_shift, .command = .zoom_in },
    .{ .key = .char('-'), .mods = ctrl, .command = .zoom_out },
    .{ .key = .char('0'), .mods = ctrl, .command = .zoom_reset },
    .{ .key = .char(','), .mods = ctrl, .command = .open_settings },
    .{ .key = .char('t'), .mods = alt, .command = .next_theme },
    .{ .key = .char('n'), .mods = ctrl, .command = .new_file },
    .{ .key = .char('w'), .mods = ctrl, .command = .close_tab },
    .{ .key = .tab, .mods = ctrl, .command = .next_tab },
    .{ .key = .tab, .mods = ctrl_shift, .command = .prev_tab },
    .{ .key = .char('\\'), .mods = ctrl, .command = .split_right },
    .{ .key = .char('\\'), .mods = ctrl_shift, .command = .split_down },
    .{ .key = .right, .mods = alt_shift, .command = .split_right },
    .{ .key = .down, .mods = alt_shift, .command = .split_down },
    .{ .key = .f6, .command = .next_pane },
    .{ .key = .f6, .mods = shift, .command = .prev_pane },
    .{ .key = .char('b'), .mods = ctrl, .command = .toggle_sidebar },
    .{ .key = .char('j'), .mods = ctrl, .command = .toggle_bottom },
    .{ .key = .char('1'), .mods = alt, .command = .focus_sidebar },
    .{ .key = .char('e'), .mods = ctrl_shift, .command = .show_files },
    .{ .key = .char('g'), .mods = ctrl_shift, .command = .show_git },
    .{ .key = .escape, .command = .focus_editor },
    .{ .key = .char('0'), .mods = alt, .command = .focus_bottom },
    .{ .key = .char('g'), .mods = ctrl, .command = .goto_line },
    .{ .key = .char('f'), .mods = ctrl, .command = .find },
    .{ .key = .f3, .command = .find_next },
    .{ .key = .f3, .mods = shift, .command = .find_prev },
    .{ .key = .char('h'), .mods = ctrl, .command = .replace },
    .{ .key = .char('a'), .mods = alt, .command = .replace_all },
    .{ .key = .char('c'), .mods = alt, .command = .toggle_match_case },
    .{ .key = .char('w'), .mods = alt, .command = .toggle_whole_word },
    .{ .key = .char('f'), .mods = ctrl_shift, .command = .find_in_project },
    .{ .key = .char('/'), .mods = ctrl, .command = .toggle_comment },
    // Where `/` is Shift+7, as on Latin American, Spanish and German keyboards.
    .{ .key = .char('7'), .mods = ctrl_shift, .command = .toggle_comment },
    .{ .key = .char('m'), .mods = ctrl_shift, .command = .goto_bracket },
    .{ .key = .char('l'), .mods = alt, .command = .set_language },
    .{ .key = .enter, .mods = ctrl, .command = .git_commit },
    .{ .key = .enter, .mods = ctrl_shift, .command = .git_amend },
    .{ .key = .char('d'), .mods = alt, .command = .show_changes },
    .{ .key = .f7, .command = .next_change },
    .{ .key = .f7, .mods = shift, .command = .prev_change },
    .{ .key = .char('b'), .mods = alt, .command = .toggle_blame },
    .{ .key = .char('h'), .mods = alt, .command = .file_history },
    .{ .key = .char('`'), .mods = ctrl, .command = .toggle_terminal },
    .{ .key = .f12, .mods = alt, .command = .toggle_terminal },
    .{ .key = .char('`'), .mods = ctrl_shift, .command = .new_terminal },
    .{ .key = .f12, .mods = alt_shift, .command = .new_terminal },
};

pub const default = moves ++ selecting(moves) ++ others;

/// The same keys with Shift, bound to the `select_` twin of each `move_`.
fn selecting(comptime bindings: [moves.len]Binding) [moves.len]Binding {
    var result = bindings;
    for (&result) |*binding| {
        binding.mods.shift = true;
        const direction = @tagName(binding.command)["move_".len..];
        binding.command = @field(Command, "select_" ++ direction);
    }
    return result;
}

/// The user's bindings, then the defaults, so the first match is the user's.
/// A bad key or command name is reported and skipped.
pub fn withUser(arena: std.mem.Allocator, entries: []const Entry, notifier: anytype) ![]const Binding {
    var list: std.ArrayList(Binding) = try .initCapacity(arena, entries.len + default.len);
    for (entries) |entry| {
        const press = parseKey(entry.key) orelse {
            notifier.notify("keymap.zon: unknown key \"{s}\"", .{entry.key});
            continue;
        };
        const command = Command.fromName(entry.command) orelse {
            notifier.notify("keymap.zon: unknown command \"{s}\"", .{entry.command});
            continue;
        };
        list.appendAssumeCapacity(.{ .key = press.key, .mods = press.mods, .command = command });
    }
    list.appendSliceAssumeCapacity(&default);
    return list.items;
}

/// Reads a combo like "ctrl+shift+k", "alt+f4" or "ctrl++". Keys are one
/// character or a name of `Key`.
pub fn parseKey(text: []const u8) ?KeyPress {
    var rest = text;
    var mods: Mods = .{};
    while (true) {
        inline for (.{ "ctrl", "shift", "alt" }) |name| {
            if (rest.len > name.len + 1 and std.mem.startsWith(u8, rest, name ++ "+")) {
                @field(mods, name) = true;
                rest = rest[name.len + 1 ..];
                break;
            }
        } else break;
    }
    const key: Key = if (rest.len == 1 and std.ascii.isPrint(rest[0]))
        .char(std.ascii.toLower(rest[0]))
    else
        std.meta.stringToEnum(Key, rest) orelse return null;
    return .{ .key = key, .mods = mods };
}

pub fn lookup(bindings: []const Binding, key: Key, mods: Mods) ?Command {
    for (bindings) |binding| {
        if (binding.key == key and binding.mods == mods) return binding.command;
    }
    return null;
}

const testing = std.testing;

fn expectBinding(command: ?Command, key: Key, mods: Mods) !void {
    try testing.expectEqual(command, lookup(&default, key, mods));
}

test "moves, and Shift selects with every move" {
    try expectBinding(.move_left, .left, .{});
    try expectBinding(.move_line_end, .end, .{});
    try expectBinding(.move_page_down, .page_down, .{});
    try expectBinding(.move_word_right, .right, ctrl);
    try expectBinding(.move_file_start, .home, ctrl);
    for (moves) |move| {
        var mods = move.mods;
        mods.shift = true;
        const selects = lookup(&default, move.key, mods).?;
        try testing.expectEqualStrings(@tagName(move.command)["move_".len..], @tagName(selects)["select_".len..]);
    }
    try expectBinding(.select_word_left, .left, ctrl_shift);
    try expectBinding(.select_all, .char('a'), ctrl);
}

test "editing, clipboard and file keys" {
    try expectBinding(.undo, .char('z'), ctrl);
    try expectBinding(.redo, .char('y'), ctrl);
    try expectBinding(.redo, .char('z'), ctrl_shift);
    try expectBinding(.copy, .char('c'), ctrl);
    try expectBinding(.cut, .char('x'), ctrl);
    try expectBinding(.paste, .char('v'), ctrl);
    try expectBinding(.save, .char('s'), ctrl);
    try expectBinding(.save_as, .char('s'), ctrl_shift);
    try expectBinding(.open, .char('o'), ctrl);
    try expectBinding(.quit, .char('q'), ctrl);
    try expectBinding(.indent, .tab, .{});
    try expectBinding(.outdent, .tab, shift);
    try expectBinding(.zoom_in, .char('='), ctrl);
    try expectBinding(.zoom_out, .char('-'), ctrl);
    try expectBinding(.zoom_reset, .char('0'), ctrl);
}

test "unbound combos and plain letters give nothing" {
    try expectBinding(null, .char('z'), .{});
    try expectBinding(null, .char('q'), alt);
    try expectBinding(null, .f5, ctrl);
}

test "parseKey reads mods and key names" {
    try testing.expectEqual(KeyPress{ .key = .char('k'), .mods = ctrl_shift }, parseKey("ctrl+shift+K").?);
    try testing.expectEqual(KeyPress{ .key = .f4, .mods = alt }, parseKey("alt+f4").?);
    try testing.expectEqual(KeyPress{ .key = .char('+'), .mods = ctrl }, parseKey("ctrl++").?);
    try testing.expectEqual(KeyPress{ .key = .page_down }, parseKey("page_down").?);
    try testing.expectEqual(@as(?KeyPress, null), parseKey("ctrl+nope"));
    try testing.expectEqual(@as(?KeyPress, null), parseKey("ctrl+"));
}

test "user bindings win, bad names are reported and skipped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var notifier: @import("config.zig").TestNotifier = .{};
    const bindings = try withUser(arena.allocator(), &.{
        .{ .key = "ctrl+s", .command = "quit" },
        .{ .key = "ctrl+nope", .command = "save" },
        .{ .key = "f5", .command = "no_such_command" },
    }, &notifier);
    try testing.expectEqual(@as(?Command, .quit), lookup(bindings, .char('s'), ctrl));
    try testing.expectEqual(@as(?Command, .save_as), lookup(bindings, .char('s'), ctrl_shift));
    try testing.expectEqual(@as(?Command, null), lookup(bindings, .f5, .{}));
    try testing.expectEqualStrings("keymap.zon: unknown command \"no_such_command\"", notifier.message);
    try testing.expectEqual(default.len + 1, bindings.len);
}

test "no combo is bound twice" {
    for (default, 0..) |a, i| {
        for (default[i + 1 ..]) |b| try testing.expect(!(a.key == b.key and a.mods == b.mods));
    }
}
