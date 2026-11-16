//! Plain input events. `input.zig` makes them from SDL events; nothing here
//! knows about SDL.

pub const Mods = packed struct(u3) {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
};

/// A key by what its keycap says, so shortcuts follow the keyboard layout.
/// Values below 128 are the ASCII character of the key, in lower case.
pub const Key = enum(u8) {
    backspace = 8,
    tab = '\t',
    enter = '\r',
    escape = 27,
    delete = 127,
    left = 128,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    insert,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    _,

    pub fn char(ascii: u8) Key {
        return @fromBackingInt(@intCast(ascii));
    }
};

pub const KeyPress = struct { key: Key, mods: Mods = .{} };

pub const MouseButton = enum { left, middle, right };

/// Positions are in window pixels.
pub const MouseDown = struct { x: f32, y: f32, button: MouseButton, clicks: u8, mods: Mods };
pub const MouseUp = struct { x: f32, y: f32, button: MouseButton };
pub const MouseMove = struct { x: f32, y: f32, left_down: bool };

/// Wheel steps; positive `dy` is away from the user.
pub const Wheel = struct { dx: f32, dy: f32, mods: Mods };

pub const Event = union(enum) {
    quit,
    /// The window was exposed or resized and must be drawn again.
    redraw,
    focus: bool,
    key: KeyPress,
    /// Typed text as UTF-8. Valid until the next event is read.
    text: []const u8,
    mouse_down: MouseDown,
    mouse_up: MouseUp,
    mouse_move: MouseMove,
    wheel: Wheel,
    /// Path of a file dropped on the window. Valid until the next event is read.
    drop_file: []const u8,
    /// A background thread posted to a mailbox.
    wake,
};
