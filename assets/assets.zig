//! Built-in data files, compiled into the exe. Names have no `.zon`.
const std = @import("std");

pub const files: std.StaticStringMap([:0]const u8) = .initComptime(.{
    .{ "settings", @embedFile("settings.zon") },
    .{ "keymap", @embedFile("keymap.zon") },
    .{ "themes/dark", @embedFile("themes/dark.zon") },
    .{ "themes/light", @embedFile("themes/light.zon") },
});
