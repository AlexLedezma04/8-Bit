//! 2D drawing on top of SDL_Renderer. Takes UI colours, exposes no SDL types.
const std = @import("std");
const c = @import("sdl.zig").c;
const Window = @import("window.zig").Window;
const Color = @import("../ui/theme.zig").Color;
const Rect = @import("../ui/layout.zig").Rect;
const fonts = @import("../font/fonts.zig");
const Atlas = @import("../font/atlas.zig").Atlas;
const Image = @import("png.zig").Image;
const canvas_zig = @import("../ui/canvas.zig");
const Canvas = canvas_zig.Canvas;
const Font = canvas_zig.Font;

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
    /// The glyphs at `zoom`, and their texture.
    atlas: Atlas,
    font: *c.SDL_Texture,
    logo: *c.SDL_Texture,
    zoom: u8 = 1,

    const allocator = std.heap.c_allocator;

    pub fn init(window: *const Window, logo: Image) !Renderer {
        const handle = c.SDL_CreateRenderer(window.handle, null) orelse return sdlError("SDL_CreateRenderer");
        errdefer c.SDL_DestroyRenderer(handle);
        _ = c.SDL_SetRenderVSync(handle, 1);
        var atlas: Atlas = try .init(allocator, 1);
        errdefer atlas.deinit(allocator);
        const font = try createFontTexture(handle, &atlas);
        errdefer c.SDL_DestroyTexture(font);
        return .{ .handle = handle, .atlas = atlas, .font = font, .logo = try createTexture(handle, logo.width, logo.height, logo.pixels, c.SDL_SCALEMODE_LINEAR) };
    }

    /// Draws the glyphs again for a new zoom, so text stays sharp.
    pub fn setZoom(self: *Renderer, zoom: u8) void {
        if (zoom == self.zoom) return;
        var atlas: Atlas = Atlas.init(allocator, zoom) catch return;
        const texture = createFontTexture(self.handle, &atlas) catch return atlas.deinit(allocator);
        c.SDL_DestroyTexture(self.font);
        self.atlas.deinit(allocator);
        self.atlas = atlas;
        self.font = texture;
        self.zoom = zoom;
    }

    pub fn canvas(self: *Renderer) Canvas {
        return .of(Renderer, self);
    }

    pub fn deinit(self: *Renderer) void {
        c.SDL_DestroyTexture(self.logo);
        c.SDL_DestroyTexture(self.font);
        self.atlas.deinit(allocator);
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
    pub fn drawText(self: *Renderer, x: f32, y: f32, text: []const u8, col: Color, font: Font) void {
        const tint: c.SDL_FColor = .{
            .r = @as(f32, @floatFromInt(col.r)) / 255,
            .g = @as(f32, @floatFromInt(col.g)) / 255,
            .b = @as(f32, @floatFromInt(col.b)) / 255,
            .a = @as(f32, @floatFromInt(col.a)) / 255,
        };
        const atlas_w: f32 = @floatFromInt(self.atlas.width);
        const atlas_h: f32 = @floatFromInt(self.atlas.height);
        var quads: [batch_size][4]c.SDL_Vertex = undefined;
        var count: usize = 0;
        var pen: fonts.Pen = .init(font, self.zoom, text);
        while (pen.next()) |placed| {
            const glyph = self.atlas.glyph(font, placed.cp);
            if (glyph.w == 0) continue;
            if (count == batch_size) {
                self.drawQuads(quads[0..count]);
                count = 0;
            }
            const left = @round(x) + placed.x + @as(f32, @floatFromInt(glyph.left));
            const top = @round(y) + @as(f32, @floatFromInt(glyph.top));
            const w: f32 = @floatFromInt(glyph.w);
            const h: f32 = @floatFromInt(glyph.h);
            const gx: f32 = @floatFromInt(glyph.x);
            const gy: f32 = @floatFromInt(glyph.y);
            for (&quads[count], quad_corners) |*vertex, corner| vertex.* = .{
                .position = .{ .x = left + corner.x * w, .y = top + corner.y * h },
                .color = tint,
                .tex_coord = .{ .x = (gx + corner.x * w) / atlas_w, .y = (gy + corner.y * h) / atlas_h },
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

    pub fn drawLogo(self: *Renderer, r: Rect, col: Color) void {
        _ = c.SDL_SetTextureColorMod(self.logo, col.r, col.g, col.b);
        const fr: c.SDL_FRect = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
        _ = c.SDL_RenderTexture(self.handle, self.logo, null, &fr);
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

/// The glyph atlas as a texture. Glyphs are drawn at their own size, so
/// nearest-pixel sampling keeps them sharp.
fn createFontTexture(handle: *c.SDL_Renderer, atlas: *const Atlas) !*c.SDL_Texture {
    return createTexture(handle, atlas.width, atlas.height, atlas.pixels, c.SDL_SCALEMODE_NEAREST);
}

/// A texture of RGBA pixels, blended over what is drawn.
fn createTexture(handle: *c.SDL_Renderer, w: usize, h: usize, pixels: []const u8, scale_mode: c.SDL_ScaleMode) !*c.SDL_Texture {
    const texture = c.SDL_CreateTexture(handle, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STATIC, @intCast(w), @intCast(h)) orelse return sdlError("SDL_CreateTexture");
    errdefer c.SDL_DestroyTexture(texture);
    const ok = c.SDL_UpdateTexture(texture, null, pixels.ptr, @intCast(w * 4)) and
        c.SDL_SetTextureScaleMode(texture, scale_mode) and
        c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_BLEND);
    if (!ok) return sdlError("texture setup");
    return texture;
}
