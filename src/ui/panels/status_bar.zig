//! The bottom line: file name with an unsaved dot, or a message, on the
//! left; cursor position and line ending on the right.
const std = @import("std");
const Status = @import("../../editor/editor.zig").Status;
const Canvas = @import("../canvas.zig").Canvas;
const Rect = @import("../layout.zig").Rect;
const Look = @import("../panel.zig").Look;
const utf8 = @import("../../core/utf8.zig");

pub fn draw(canvas: Canvas, look: Look, status: Status, bar: Rect) void {
    const theme = look.theme;
    const cell = look.metrics.cell;
    canvas.fillRect(bar, theme.status_bar);
    canvas.fillRect(.{ .x = bar.x, .y = bar.y, .w = bar.w, .h = 1 }, theme.border);

    var buffer: [64]u8 = undefined;
    const right = std.fmt.bufPrint(&buffer, "Ln {d}, Col {d}  {s}  {s}", .{ status.line, status.column, status.line_ending, status.language }) catch "";
    const total_cols = look.metrics.cols(bar.w);
    // One cell of space at each edge and two between the sides.
    const left_cols = total_cols -| (right.len + 4);
    const right_x = bar.x + bar.w - @as(f32, @floatFromInt(right.len + 1)) * cell;

    if (status.message) |message| {
        // A message that needs the room takes the whole bar.
        const fits = (std.unicode.utf8CountCodepoints(message) catch message.len) <= left_cols;
        if (fits) canvas.drawText(right_x, bar.y, right, theme.status_bar_text);
        canvas.drawText(bar.x + cell, bar.y, utf8.prefix(message, if (fits) left_cols else total_cols -| 2), theme.status_bar_message);
        return;
    }
    if (total_cols >= right.len + 2) canvas.drawText(right_x, bar.y, right, theme.status_bar_text);
    canvas.drawText(bar.x + cell, bar.y, utf8.prefix(status.name, left_cols), theme.status_bar_text);
    if (status.modified) {
        const name_cols: f32 = @floatFromInt(std.unicode.utf8CountCodepoints(utf8.prefix(status.name, left_cols)) catch status.name.len);
        const dot = @floor(cell / 2);
        canvas.fillRect(.{
            .x = bar.x + (name_cols + 2) * cell,
            .y = bar.y + @floor((bar.h - dot) / 2),
            .w = dot,
            .h = dot,
        }, theme.unsaved);
    }
}
