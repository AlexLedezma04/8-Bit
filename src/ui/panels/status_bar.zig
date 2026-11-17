//! The bottom line: the git branch on the left; the language of the file
//! and the button that shows or hides the terminal on the right.
const Status = @import("../../editor/editor.zig").Status;
const Canvas = @import("../canvas.zig").Canvas;
const layout = @import("../layout.zig");
const Rect = layout.Rect;
const Metrics = layout.Metrics;
const Color = @import("../theme.zig").Color;
const Look = @import("../panel.zig").Look;

/// Where the terminal button is in the bar.
pub fn terminalButton(metrics: Metrics, bar: Rect) Rect {
    const w = 4 * metrics.cell;
    return .{ .x = bar.x + bar.w - w, .y = bar.y + 1, .w = w, .h = bar.h - 1 };
}

/// A terminal window with a prompt in it, `>_`, in icon pixels.
const icon_w = 14;
const icon_h = 12;
const prompt = [_][4]u8{
    // x, y, w, h
    .{ 3, 3, 2, 1 }, .{ 4, 4, 2, 1 }, .{ 5, 5, 2, 1 }, .{ 4, 6, 2, 1 }, .{ 3, 7, 2, 1 },
    .{ 8, 7, 3, 1 },
};

fn drawIcon(canvas: Canvas, metrics: Metrics, button: Rect, color: Color) void {
    // One icon pixel is one font pixel: 1 at zoom 1.
    const px = metrics.cell / 8;
    const w = icon_w * px;
    const h = icon_h * px;
    const x = button.x + @floor((button.w - w) / 2);
    const y = button.y + @floor((button.h - h) / 2);
    for ([_]Rect{
        .{ .x = x, .y = y, .w = w, .h = px },
        .{ .x = x, .y = y + h - px, .w = w, .h = px },
        .{ .x = x, .y = y, .w = px, .h = h },
        .{ .x = x + w - px, .y = y, .w = px, .h = h },
    }) |side| canvas.fillRect(side, color);
    for (prompt) |part| canvas.fillRect(.{
        .x = x + @as(f32, @floatFromInt(part[0])) * px,
        .y = y + @as(f32, @floatFromInt(part[1])) * px,
        .w = @as(f32, @floatFromInt(part[2])) * px,
        .h = @as(f32, @floatFromInt(part[3])) * px,
    }, color);
}

pub fn draw(canvas: Canvas, look: Look, status: Status, bar: Rect) void {
    const theme = look.theme;
    const metrics = look.metrics;
    canvas.fillRect(bar, theme.status_bar);
    canvas.fillRect(.{ .x = bar.x, .y = bar.y, .w = bar.w, .h = 1 }, theme.border);
    const y = metrics.center(bar.y, bar.h);
    const button = terminalButton(metrics, bar);
    if (status.terminal) canvas.fillRect(button, theme.list_inactive) else if (look.hovered(button)) canvas.fillRect(button, theme.hover);
    drawIcon(canvas, metrics, button, if (status.terminal) theme.tab_active_text else theme.status_bar_text);
    canvas.drawLabel(button.x - metrics.cell - metrics.labelWidth(status.language), y, status.language, theme.status_bar_text);
    canvas.drawLabel(bar.x + metrics.cell, y, status.branch, theme.status_bar_text);
}
