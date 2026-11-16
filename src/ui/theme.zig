//! Every color the UI uses, with the default dark theme as field defaults.
//! No other file holds color values; themes only fill in this struct.
const std = @import("std");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn rgb(hex: u24) Color {
        return .{ .r = @truncate(hex >> 16), .g = @truncate(hex >> 8), .b = @truncate(hex) };
    }
};

const rgb = Color.rgb;

pub const Theme = struct {
    background: Color = rgb(0x101018),
    text: Color = rgb(0xd0d0d0),
    cursor: Color = rgb(0xf0c040),
    selection: Color = rgb(0x2c3a5c),

    gutter: Color = rgb(0x14141e),
    line_number: Color = rgb(0x5a5a70),
    line_number_current: Color = rgb(0xd0d0d0),

    status_bar: Color = rgb(0x20202e),
    status_bar_text: Color = rgb(0xa0a0b4),

    tab: Color = rgb(0x181824),
    tab_active: Color = rgb(0x101018),
    tab_text: Color = rgb(0x8080a0),
    tab_active_text: Color = rgb(0xd0d0d0),

    list_selection: Color = rgb(0x2a2a40),

    git_added: Color = rgb(0x60c060),
    git_changed: Color = rgb(0x60a0e0),
    git_removed: Color = rgb(0xe06060),

    syntax: Syntax = .{},
};

pub const Syntax = struct {
    comment: Color = rgb(0x6a7a6a),
    keyword: Color = rgb(0xd080d0),
    string: Color = rgb(0x90c070),
    number: Color = rgb(0xe0a060),
    constant: Color = rgb(0xe0a060),
    type: Color = rgb(0x60c0c0),
    function: Color = rgb(0x70a0f0),
    operator: Color = rgb(0xb0b0c0),
    punctuation: Color = rgb(0x9090a0),
};

test "rgb splits a hex color" {
    try std.testing.expectEqual(Color{ .r = 0x12, .g = 0x34, .b = 0x56, .a = 255 }, rgb(0x123456));
}
