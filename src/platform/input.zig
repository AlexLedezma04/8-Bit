//! Turns SDL events into plain editor events. No SDL type leaves this file.
const std = @import("std");
const c = @import("sdl.zig").c;
const event = @import("event.zig");
const Event = event.Event;
const Key = event.Key;
const Mods = event.Mods;

/// Keys that are not an ASCII character. Those map to themselves.
const named_keys = [_]struct { sdl: c.SDL_Keycode, key: Key }{
    .{ .sdl = c.SDLK_LEFT, .key = .left },
    .{ .sdl = c.SDLK_RIGHT, .key = .right },
    .{ .sdl = c.SDLK_UP, .key = .up },
    .{ .sdl = c.SDLK_DOWN, .key = .down },
    .{ .sdl = c.SDLK_HOME, .key = .home },
    .{ .sdl = c.SDLK_END, .key = .end },
    .{ .sdl = c.SDLK_PAGEUP, .key = .page_up },
    .{ .sdl = c.SDLK_PAGEDOWN, .key = .page_down },
    .{ .sdl = c.SDLK_INSERT, .key = .insert },
    .{ .sdl = c.SDLK_KP_ENTER, .key = .enter },
    .{ .sdl = c.SDLK_KP_PLUS, .key = .char('+') },
    .{ .sdl = c.SDLK_KP_MINUS, .key = .char('-') },
    .{ .sdl = c.SDLK_KP_0, .key = .char('0') },
    .{ .sdl = c.SDLK_F1, .key = .f1 },
    .{ .sdl = c.SDLK_F2, .key = .f2 },
    .{ .sdl = c.SDLK_F3, .key = .f3 },
    .{ .sdl = c.SDLK_F4, .key = .f4 },
    .{ .sdl = c.SDLK_F5, .key = .f5 },
    .{ .sdl = c.SDLK_F6, .key = .f6 },
    .{ .sdl = c.SDLK_F7, .key = .f7 },
    .{ .sdl = c.SDLK_F8, .key = .f8 },
    .{ .sdl = c.SDLK_F9, .key = .f9 },
    .{ .sdl = c.SDLK_F10, .key = .f10 },
    .{ .sdl = c.SDLK_F11, .key = .f11 },
    .{ .sdl = c.SDLK_F12, .key = .f12 },
};

const mouse_buttons = [_]struct { sdl: u8, button: event.MouseButton }{
    .{ .sdl = c.SDL_BUTTON_LEFT, .button = .left },
    .{ .sdl = c.SDL_BUTTON_MIDDLE, .button = .middle },
    .{ .sdl = c.SDL_BUTTON_RIGHT, .button = .right },
};

/// Sleeps until an event arrives, or until `timeout_ms` is over (null).
pub fn wait(timeout_ms: ?u64) ?Event {
    var ev: c.SDL_Event = undefined;
    while (true) {
        const got = if (timeout_ms) |ms|
            c.SDL_WaitEventTimeout(&ev, @intCast(@min(ms, std.math.maxInt(i32))))
        else
            c.SDL_WaitEvent(&ev);
        if (!got) return if (timeout_ms == null) .quit else null;
        if (translate(ev)) |translated| return translated;
    }
}

/// Returns an event that is already waiting, without sleeping.
pub fn poll() ?Event {
    var ev: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&ev)) {
        if (translate(ev)) |translated| return translated;
    }
    return null;
}

/// Makes `wait` return a `wake` event. Safe to call from any thread.
pub fn wake() void {
    var ev = std.mem.zeroes(c.SDL_Event);
    ev.type = c.SDL_EVENT_USER;
    _ = c.SDL_PushEvent(&ev);
}

/// Milliseconds since the program started.
pub fn now() u64 {
    return c.SDL_GetTicks();
}

fn translate(ev: c.SDL_Event) ?Event {
    return switch (ev.type) {
        c.SDL_EVENT_QUIT => .quit,
        c.SDL_EVENT_WINDOW_EXPOSED,
        c.SDL_EVENT_WINDOW_RESIZED,
        c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED,
        c.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED,
        => .redraw,
        c.SDL_EVENT_WINDOW_FOCUS_GAINED => .{ .focus = true },
        c.SDL_EVENT_WINDOW_FOCUS_LOST => .{ .focus = false },
        c.SDL_EVENT_KEY_DOWN => .{ .key = .{
            .key = keyOf(ev.key.key) orelse return null,
            .mods = modsOf(ev.key.mod),
        } },
        c.SDL_EVENT_TEXT_INPUT => .{ .text = std.mem.span(ev.text.text) },
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => .{ .mouse_down = .{
            .x = ev.button.x,
            .y = ev.button.y,
            .button = buttonOf(ev.button.button) orelse return null,
            .clicks = ev.button.clicks,
            .mods = modsOf(c.SDL_GetModState()),
        } },
        c.SDL_EVENT_MOUSE_BUTTON_UP => .{ .mouse_up = .{
            .x = ev.button.x,
            .y = ev.button.y,
            .button = buttonOf(ev.button.button) orelse return null,
        } },
        c.SDL_EVENT_MOUSE_MOTION => .{ .mouse_move = .{
            .x = ev.motion.x,
            .y = ev.motion.y,
            .left_down = ev.motion.state & c.SDL_BUTTON_LMASK != 0,
        } },
        c.SDL_EVENT_MOUSE_WHEEL => .{ .wheel = .{
            .dx = ev.wheel.x,
            .dy = ev.wheel.y,
            .mods = modsOf(c.SDL_GetModState()),
        } },
        c.SDL_EVENT_DROP_FILE => .{ .drop_file = std.mem.span(ev.drop.data) },
        c.SDL_EVENT_USER => .wake,
        else => null,
    };
}

fn keyOf(code: c.SDL_Keycode) ?Key {
    if (code > 0 and code < 128) return .char(@intCast(code));
    for (named_keys) |named| {
        if (named.sdl == code) return named.key;
    }
    return null;
}

fn buttonOf(sdl: u8) ?event.MouseButton {
    for (mouse_buttons) |entry| {
        if (entry.sdl == sdl) return entry.button;
    }
    return null;
}

fn modsOf(mod: c.SDL_Keymod) Mods {
    return .{
        .ctrl = mod & c.SDL_KMOD_CTRL != 0,
        .shift = mod & c.SDL_KMOD_SHIFT != 0,
        .alt = mod & c.SDL_KMOD_ALT != 0,
    };
}
