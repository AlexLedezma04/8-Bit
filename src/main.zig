const std = @import("std");
const c = @import("sdl");

pub fn main() !void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInit;
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("8-Bit", 800, 600, c.SDL_WINDOW_OPENGL) orelse {
        std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
        return error.Window;
    };
    defer c.SDL_DestroyWindow(window);

    const ctx = c.SDL_GL_CreateContext(window) orelse {
        std.debug.print("GL context failed: {s}\n", .{c.SDL_GetError()});
        return error.GlContext;
    };
    defer _ = c.SDL_GL_DestroyContext(ctx);
    std.debug.print("OpenGL ready\n", .{});

    var running = true;
    while (running) {
        var ev: c.SDL_Event = undefined;
        while (c.SDL_WaitEvent(&ev)) {
            if (ev.type == c.SDL_EVENT_QUIT) running = false;
            break;
        }
    }
}
