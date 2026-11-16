//! Converts SDL events into editor input events.
const c = @import("sdl.zig").c;

pub const InputEvent = enum {
    quit,
    /// The window must be drawn again.
    redraw,
    other,
};

/// Sleeps until an event arrives.
pub fn wait() InputEvent {
    var ev: c.SDL_Event = undefined;
    return if (c.SDL_WaitEvent(&ev)) translate(ev) else .quit;
}

/// Returns an event that is already waiting, without sleeping.
pub fn poll() ?InputEvent {
    var ev: c.SDL_Event = undefined;
    return if (c.SDL_PollEvent(&ev)) translate(ev) else null;
}

fn translate(ev: c.SDL_Event) InputEvent {
    return switch (ev.type) {
        c.SDL_EVENT_QUIT => .quit,
        c.SDL_EVENT_WINDOW_EXPOSED,
        c.SDL_EVENT_WINDOW_RESIZED,
        c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED,
        => .redraw,
        else => .other,
    };
}
