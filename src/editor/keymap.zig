//! Default key bindings: a table from key combos to commands.
const std = @import("std");
const event = @import("../platform/event.zig");
const Key = event.Key;
const Mods = event.Mods;
const Command = @import("commands.zig").Command;

pub const Binding = struct { key: Key, mods: Mods = .{}, command: Command };

const ctrl: Mods = .{ .ctrl = true };
const shift: Mods = .{ .shift = true };
const alt: Mods = .{ .alt = true };
const ctrl_shift: Mods = .{ .ctrl = true, .shift = true };

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

test "no combo is bound twice" {
    for (default, 0..) |a, i| {
        for (default[i + 1 ..]) |b| try testing.expect(!(a.key == b.key and a.mods == b.mods));
    }
}
