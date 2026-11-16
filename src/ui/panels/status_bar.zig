//! The bottom line: file name with an unsaved dot, or a message, on the
//! left; cursor position and line ending on the right.
const std = @import("std");
const Renderer = @import("../../platform/renderer.zig").Renderer;
const Status = @import("../../editor/editor.zig").Status;
const Layout = @import("../layout.zig").Layout;
const Theme = @import("../theme.zig").Theme;
const utf8 = @import("../../core/utf8.zig");

pub fn draw(renderer: *Renderer, theme: *const Theme, status: Status, layout: *const Layout) void {
    const bar = layout.status;
    const cell = layout.metrics.cell;
    const text_y = bar.y;
    renderer.fillRect(bar, theme.status_bar);

    var buffer: [64]u8 = undefined;
    const right = std.fmt.bufPrint(&buffer, "Ln {d}, Col {d}  {s}", .{ status.line, status.column, status.line_ending }) catch "";
    const total_cols: usize = @intFromFloat(bar.w / cell);
    // One cell of space at each edge and two between the sides.
    const left_cols = total_cols -| (right.len + 4);
    const right_x = bar.x + bar.w - @as(f32, @floatFromInt(right.len + 1)) * cell;

    if (status.message) |message| {
        // A message that needs the room takes the whole bar.
        const fits = (std.unicode.utf8CountCodepoints(message) catch message.len) <= left_cols;
        if (fits) renderer.drawText(right_x, text_y, right, theme.status_bar_text);
        renderer.drawText(bar.x + cell, text_y, utf8.prefix(message, if (fits) left_cols else total_cols -| 2), theme.status_bar_message);
        return;
    }
    if (total_cols >= right.len + 2) renderer.drawText(right_x, text_y, right, theme.status_bar_text);
    renderer.drawText(bar.x + cell, text_y, utf8.prefix(status.name, left_cols), theme.status_bar_text);
    if (status.modified) {
        const name_cols: f32 = @floatFromInt(std.unicode.utf8CountCodepoints(utf8.prefix(status.name, left_cols)) catch status.name.len);
        const dot = cell / 2;
        renderer.fillRect(.{
            .x = bar.x + (name_cols + 2) * cell,
            .y = bar.y + (bar.h - dot) / 2,
            .w = dot,
            .h = dot,
        }, theme.unsaved);
    }
}
