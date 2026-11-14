//! Converts SDL events into editor input events.
const c = @import("sdl.zig").c;

pub const InputEvent = enum { quit, other };

/// Blocks until an event arrives and returns it translated.
pub fn wait() ?InputEvent {
    var ev: c.SDL_Event = undefined;
    if (!c.SDL_WaitEvent(&ev)) return null;
    return switch (ev.type) {
        c.SDL_EVENT_QUIT => .quit,
        else => .other,
    };
}
