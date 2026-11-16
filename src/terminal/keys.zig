//! Turns a key press into the bytes a terminal program reads: arrows,
//! F-keys, Ctrl+letters, Alt as an ESC prefix. Plain characters come as
//! typed text instead. SDL-free.
const std = @import("std");
const event = @import("../platform/event.zig");
const KeyPress = event.KeyPress;
const Mods = event.Mods;

/// The bytes of `press`, or null for a key that types text (or none).
/// `app_cursor` is the DECCKM mode, where arrows send `ESC O`.
pub fn encode(press: KeyPress, app_cursor: bool, buffer: *[16]u8) ?[]const u8 {
    const mods = press.mods;
    // xterm's modifier number: 1 + Shift + 2 Alt + 4 Ctrl.
    const code: u8 = 1 + @as(u8, @intFromBool(mods.shift)) + 2 * @as(u8, @intFromBool(mods.alt)) + 4 * @as(u8, @intFromBool(mods.ctrl));
    const plain = code == 1;
    return switch (press.key) {
        .enter => prefixed(mods.alt, "\r", buffer),
        .escape => "\x1b",
        .tab => if (mods.shift) "\x1b[Z" else "\t",
        .backspace => prefixed(mods.alt, if (mods.ctrl) "\x08" else "\x7f", buffer),
        .up, .down, .right, .left, .home, .end => {
            const letter: u8 = switch (press.key) {
                .up => 'A',
                .down => 'B',
                .right => 'C',
                .left => 'D',
                .home => 'H',
                else => 'F',
            };
            if (!plain) return std.fmt.bufPrint(buffer, "\x1b[1;{d}{c}", .{ code, letter }) catch unreachable;
            return std.fmt.bufPrint(buffer, "\x1b{c}{c}", .{ @as(u8, if (app_cursor) 'O' else '['), letter }) catch unreachable;
        },
        .f1, .f2, .f3, .f4 => {
            const letter = "PQRS"[@backingInt(press.key) - @backingInt(event.Key.f1)];
            if (!plain) return std.fmt.bufPrint(buffer, "\x1b[1;{d}{c}", .{ code, letter }) catch unreachable;
            return std.fmt.bufPrint(buffer, "\x1bO{c}", .{letter}) catch unreachable;
        },
        .insert, .delete, .page_up, .page_down, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => {
            const number: u8 = switch (press.key) {
                .insert => 2,
                .delete => 3,
                .page_up => 5,
                .page_down => 6,
                .f5 => 15,
                .f6 => 17,
                .f7 => 18,
                .f8 => 19,
                .f9 => 20,
                .f10 => 21,
                .f11 => 23,
                else => 24,
            };
            if (!plain) return std.fmt.bufPrint(buffer, "\x1b[{d};{d}~", .{ number, code }) catch unreachable;
            return std.fmt.bufPrint(buffer, "\x1b[{d}~", .{number}) catch unreachable;
        },
        else => {
            const char = @backingInt(press.key);
            if (char >= 128 or !(mods.ctrl or mods.alt)) return null;
            if (!mods.ctrl) {
                buffer[0..2].* = .{ 0x1b, if (mods.shift) std.ascii.toUpper(char) else char };
                return buffer[0..2];
            }
            const control: u8 = switch (char) {
                'a'...'z' => char - 'a' + 1,
                ' ', '2', '@' => 0,
                '[', '3' => 0x1b,
                '\\', '4' => 0x1c,
                ']', '5' => 0x1d,
                '6' => 0x1e,
                '/', '-', '7' => 0x1f,
                else => return null,
            };
            buffer[1] = control;
            return prefixed(mods.alt, buffer[1..2], buffer);
        },
    };
}

/// `bytes` after an ESC when Alt is held.
fn prefixed(alt: bool, bytes: []const u8, buffer: *[16]u8) []const u8 {
    if (!alt) return bytes;
    std.mem.copyBackwards(u8, buffer[1 .. bytes.len + 1], bytes);
    buffer[0] = 0x1b;
    return buffer[0 .. bytes.len + 1];
}

const testing = std.testing;

fn expectKey(expected: ?[]const u8, key: event.Key, mods: Mods, app_cursor: bool) !void {
    var buffer: [16]u8 = undefined;
    const got = encode(.{ .key = key, .mods = mods }, app_cursor, &buffer);
    if (expected) |bytes| try testing.expectEqualStrings(bytes, got.?) else try testing.expectEqual(@as(?[]const u8, null), got);
}

test "named keys" {
    try expectKey("\r", .enter, .{}, false);
    try expectKey("\x7f", .backspace, .{}, false);
    try expectKey("\x1b[Z", .tab, .{ .shift = true }, false);
    try expectKey("\x1b[3~", .delete, .{}, false);
    try expectKey("\x1b[5;5~", .page_up, .{ .ctrl = true }, false);
    try expectKey("\x1bOP", .f1, .{}, false);
    try expectKey("\x1b[24~", .f12, .{}, false);
}

test "arrows follow the cursor key mode and carry modifiers" {
    try expectKey("\x1b[A", .up, .{}, false);
    try expectKey("\x1bOA", .up, .{}, true);
    try expectKey("\x1b[1;5D", .left, .{ .ctrl = true }, true);
    try expectKey("\x1b[1;2H", .home, .{ .shift = true }, false);
}

test "Ctrl and Alt with letters; plain letters type text" {
    try expectKey("\x03", .char('c'), .{ .ctrl = true }, false);
    try expectKey("\x00", .char(' '), .{ .ctrl = true }, false);
    try expectKey("\x1bx", .char('x'), .{ .alt = true }, false);
    try expectKey("\x1bX", .char('x'), .{ .alt = true, .shift = true }, false);
    try expectKey("\x1b\x01", .char('a'), .{ .ctrl = true, .alt = true }, false);
    try expectKey("\x1b\r", .enter, .{ .alt = true }, false);
    try expectKey(null, .char('a'), .{}, false);
    try expectKey(null, .char('a'), .{ .shift = true }, false);
}
