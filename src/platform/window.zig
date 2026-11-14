//! Window lifecycle. Drawing goes through platform/renderer.zig.
const std = @import("std");
const c = @import("sdl.zig").c;

pub const Window = struct {
    handle: *c.SDL_Window,

    pub const Options = struct {
        title: [:0]const u8 = "8-Bit",
        width: c_int = 800,
        height: c_int = 600,
    };

    /// Initialises SDL video and creates the window.
    pub fn init(opts: Options) !Window {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInit;
        errdefer c.SDL_Quit();

        const handle = c.SDL_CreateWindow(opts.title, opts.width, opts.height, c.SDL_WINDOW_RESIZABLE) orelse {
            std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
            return error.Window;
        };
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Window) void {
        c.SDL_DestroyWindow(self.handle);
        c.SDL_Quit();
    }
};
