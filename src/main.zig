const c = @import("sdl");

pub fn main() !void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInit;
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("8-Bit", 800, 600, c.SDL_WINDOW_OPENGL) orelse return error.Window;
    defer c.SDL_DestroyWindow(window);

    var running = true;
    while (running) {
        var ev: c.SDL_Event = undefined;
        while (c.SDL_WaitEvent(&ev)) {
            if (ev.type == c.SDL_EVENT_QUIT) running = false;
            break;
        }
    }
}
