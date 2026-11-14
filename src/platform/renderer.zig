//! 2D drawing on top of SDL_Renderer. Takes UI colours, exposes no SDL types.
const std = @import("std");
const c = @import("sdl.zig").c;
const Window = @import("window.zig").Window;
const Color = @import("../ui/theme.zig").Color;

pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

pub const Renderer = struct {
    handle: *c.SDL_Renderer,

    pub fn init(window: *const Window) !Renderer {
        const handle = c.SDL_CreateRenderer(window.handle, null) orelse {
            std.debug.print("SDL_CreateRenderer failed: {s}\n", .{c.SDL_GetError()});
            return error.Renderer;
        };
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Renderer) void {
        c.SDL_DestroyRenderer(self.handle);
    }

    fn setColor(self: *Renderer, col: Color) void {
        _ = c.SDL_SetRenderDrawColor(self.handle, col.r, col.g, col.b, col.a);
    }

    /// Fills the whole target with `col`.
    pub fn clear(self: *Renderer, col: Color) void {
        self.setColor(col);
        _ = c.SDL_RenderClear(self.handle);
    }

    pub fn fillRect(self: *Renderer, r: Rect, col: Color) void {
        self.setColor(col);
        const fr: c.SDL_FRect = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
        _ = c.SDL_RenderFillRect(self.handle, &fr);
    }

    /// Restricts drawing to `r`; null removes the clip.
    pub fn setClip(self: *Renderer, r: ?Rect) void {
        if (r) |rr| {
            const ir: c.SDL_Rect = .{
                .x = @intFromFloat(rr.x),
                .y = @intFromFloat(rr.y),
                .w = @intFromFloat(rr.w),
                .h = @intFromFloat(rr.h),
            };
            _ = c.SDL_SetRenderClipRect(self.handle, &ir);
        } else {
            _ = c.SDL_SetRenderClipRect(self.handle, null);
        }
    }

    pub fn present(self: *Renderer) void {
        _ = c.SDL_RenderPresent(self.handle);
    }
};
