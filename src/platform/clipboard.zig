//! The system clipboard, as text.
const std = @import("std");
const c = @import("sdl.zig").c;

pub fn set(text: [:0]const u8) void {
    _ = c.SDL_SetClipboardText(text.ptr);
}

/// The clipboard text, or null when it is empty. The caller frees it.
pub fn get(allocator: std.mem.Allocator) ?[]u8 {
    const raw = c.SDL_GetClipboardText() orelse return null;
    defer c.SDL_free(raw);
    const text = std.mem.span(raw);
    if (text.len == 0) return null;
    return allocator.dupe(u8, text) catch null;
}
