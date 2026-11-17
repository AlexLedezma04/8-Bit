//! Built-in data files, compiled into the exe. Names have no `.zon`.
//! Every file of grammars/ is added by the build.
const std = @import("std");

pub const files: std.StaticStringMap([:0]const u8) = .initComptime(.{
    .{ "settings", @embedFile("settings.zon") },
    .{ "keymap", @embedFile("keymap.zon") },
    .{ "state", @embedFile("state.zon") },
    .{ "themes/dark", @embedFile("themes/dark.zon") },
    .{ "themes/light", @embedFile("themes/light.zon") },
} ++ @import("grammars").files);

/// The fonts: JetBrains Mono for code, Inter for the UI. OFL, see fonts/.
pub const code_font = @embedFile("fonts/JetBrainsMono-Regular.ttf");
pub const ui_font = @embedFile("fonts/Inter-Regular.ttf");

/// The app logo: light bars on a transparent background.
pub const logo = @embedFile("icons/b-logo-light-512.png");
