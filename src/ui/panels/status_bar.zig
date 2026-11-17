//! The bottom line: the git branch on the left, the language of the file
//! on the right.
const Status = @import("../../editor/editor.zig").Status;
const Canvas = @import("../canvas.zig").Canvas;
const Rect = @import("../layout.zig").Rect;
const Look = @import("../panel.zig").Look;

pub fn draw(canvas: Canvas, look: Look, status: Status, bar: Rect) void {
    const theme = look.theme;
    const metrics = look.metrics;
    canvas.fillRect(bar, theme.status_bar);
    canvas.fillRect(.{ .x = bar.x, .y = bar.y, .w = bar.w, .h = 1 }, theme.border);
    const y = metrics.center(bar.y, bar.h);
    canvas.drawLabel(bar.x + bar.w - metrics.cell - metrics.labelWidth(status.language), y, status.language, theme.status_bar_text);
    canvas.drawLabel(bar.x + metrics.cell, y, status.branch, theme.status_bar_text);
}
