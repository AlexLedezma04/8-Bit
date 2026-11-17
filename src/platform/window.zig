//! Window lifecycle. Drawing goes through platform/renderer.zig.
const std = @import("std");
const c = @import("sdl.zig").c;
const Image = @import("png.zig").Image;

pub const Window = struct {
    handle: *c.SDL_Window,
    /// The title that is set now, so an unchanged title costs nothing.
    title: [128]u8 = undefined,
    title_len: usize = 0,

    pub const Options = struct {
        title: [:0]const u8 = "8-Bit",
        width: c_int = 800,
        height: c_int = 600,
    };

    /// Initialises SDL video and creates the window, ready for typed text.
    pub fn init(opts: Options) !Window {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInit;
        errdefer c.SDL_Quit();

        const flags = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
        const handle = c.SDL_CreateWindow(opts.title, opts.width, opts.height, flags) orelse {
            std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
            return error.Window;
        };
        // Text input events carry what AltGr and input methods produce.
        _ = c.SDL_StartTextInput(handle);
        return .{ .handle = handle };
    }

    pub fn setIcon(self: *Window, image: Image) void {
        const surface = c.SDL_CreateSurfaceFrom(@intCast(image.width), @intCast(image.height), c.SDL_PIXELFORMAT_RGBA32, image.pixels.ptr, @intCast(image.width * 4)) orelse return;
        defer c.SDL_DestroySurface(surface);
        _ = c.SDL_SetWindowIcon(self.handle, surface);
    }

    pub fn deinit(self: *Window) void {
        c.SDL_DestroyWindow(self.handle);
        c.SDL_Quit();
    }

    pub fn setTitle(self: *Window, title: []const u8) void {
        if (std.mem.eql(u8, title, self.title[0..self.title_len])) return;
        var text: [self.title.len + 1]u8 = undefined;
        const len = @min(title.len, self.title.len);
        @memcpy(text[0..len], title[0..len]);
        text[len] = 0;
        _ = c.SDL_SetWindowTitle(self.handle, &text);
        @memcpy(self.title[0..len], title[0..len]);
        self.title_len = len;
    }

    /// Drawing pixels per unit of mouse position.
    pub fn pixelDensity(self: *const Window) f32 {
        const density = c.SDL_GetWindowPixelDensity(self.handle);
        return if (density > 0) density else 1;
    }

    /// How much the system wants content enlarged: 1 on a normal screen,
    /// 2 on a typical high-DPI screen.
    pub fn displayScale(self: *const Window) f32 {
        const scale = c.SDL_GetWindowDisplayScale(self.handle);
        return if (scale > 0) scale else 1;
    }
};
