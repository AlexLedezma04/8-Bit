//! 2D drawing on top of SDL_Renderer. Takes UI colours, exposes no SDL types.
const std = @import("std");
const c = @import("sdl.zig").c;
const Window = @import("window.zig").Window;
const Color = @import("../ui/theme.zig").Color;
const Rect = @import("../ui/layout.zig").Rect;
const bitmap_font = @import("../font/bitmap_font.zig");

/// Glyphs sent to SDL in one call.
const batch_size = 128;

const quad_corners = [4]c.SDL_FPoint{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 0, .y = 1 } };

/// Two triangles per quad, for a full batch.
const quad_indices = blk: {
    var indices: [batch_size * 6]c_int = undefined;
    for (0..batch_size) |quad| {
        for ([_]c_int{ 0, 1, 2, 0, 2, 3 }, 0..) |corner, i| indices[quad * 6 + i] = quad * 4 + corner;
    }
    break :blk indices;
};

pub const Renderer = struct {
    handle: *c.SDL_Renderer,
    font: *c.SDL_Texture,
    /// Screen pixels per font pixel.
    scale: f32 = 2,

    pub fn init(window: *const Window) !Renderer {
        const handle = c.SDL_CreateRenderer(window.handle, null) orelse return sdlError("SDL_CreateRenderer");
        errdefer c.SDL_DestroyRenderer(handle);
        _ = c.SDL_SetRenderVSync(handle, 1);
        return .{ .handle = handle, .font = try createFontTexture(handle) };
    }

    pub fn deinit(self: *Renderer) void {
        c.SDL_DestroyTexture(self.font);
        c.SDL_DestroyRenderer(self.handle);
    }

    /// Size of the drawing area in pixels.
    pub fn outputSize(self: *const Renderer) struct { w: f32, h: f32 } {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetRenderOutputSize(self.handle, &w, &h);
        return .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
    }

    /// Draws one line of text with its top-left corner at `x`, `y`.
    /// All text on screen goes through here.
    pub fn drawText(self: *Renderer, x: f32, y: f32, text: []const u8, col: Color) void {
        const w = bitmap_font.width * self.scale;
        const h = bitmap_font.height * self.scale;
        const tint: c.SDL_FColor = .{
            .r = @as(f32, @floatFromInt(col.r)) / 255,
            .g = @as(f32, @floatFromInt(col.g)) / 255,
            .b = @as(f32, @floatFromInt(col.b)) / 255,
            .a = @as(f32, @floatFromInt(col.a)) / 255,
        };
        var quads: [batch_size][4]c.SDL_Vertex = undefined;
        var count: usize = 0;
        var glyphs: bitmap_font.GlyphIterator = .{ .text = text };
        while (glyphs.next()) |glyph| {
            if (count == batch_size) {
                self.drawQuads(quads[0..count]);
                count = 0;
            }
            const left = x + @as(f32, @floatFromInt(glyph.column)) * w;
            const atlas_x: f32 = @floatFromInt(glyph.atlas_x);
            const atlas_y: f32 = @floatFromInt(glyph.atlas_y);
            for (&quads[count], quad_corners) |*vertex, corner| vertex.* = .{
                .position = .{ .x = left + corner.x * w, .y = y + corner.y * h },
                .color = tint,
                .tex_coord = .{
                    .x = (atlas_x + corner.x * bitmap_font.width) / bitmap_font.atlas_width,
                    .y = (atlas_y + corner.y * bitmap_font.height) / bitmap_font.atlas_height,
                },
            };
            count += 1;
        }
        self.drawQuads(quads[0..count]);
    }

    fn drawQuads(self: *Renderer, quads: []const [4]c.SDL_Vertex) void {
        if (quads.len == 0) return;
        _ = c.SDL_RenderGeometry(self.handle, self.font, @ptrCast(quads.ptr), @intCast(quads.len * 4), &quad_indices, @intCast(quads.len * 6));
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

fn sdlError(comptime call: []const u8) error{Renderer} {
    std.debug.print(call ++ " failed: {s}\n", .{c.SDL_GetError()});
    return error.Renderer;
}

/// The glyph atlas as a texture. Nearest-pixel scaling keeps it sharp.
fn createFontTexture(handle: *c.SDL_Renderer) !*c.SDL_Texture {
    const texture = c.SDL_CreateTexture(handle, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STATIC, bitmap_font.atlas_width, bitmap_font.atlas_height) orelse return sdlError("SDL_CreateTexture");
    errdefer c.SDL_DestroyTexture(texture);
    var pixels: [bitmap_font.atlas_bytes]u8 = undefined;
    bitmap_font.drawAtlas(&pixels);
    const ok = c.SDL_UpdateTexture(texture, null, &pixels, bitmap_font.atlas_width * 4) and
        c.SDL_SetTextureScaleMode(texture, c.SDL_SCALEMODE_NEAREST) and
        c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_BLEND);
    if (!ok) return sdlError("font texture setup");
    return texture;
}
