//! The bottom line: the git branch on the left; the language of the file
//! and the button that shows or hides the terminal on the right.
const Status = @import("../../editor/editor.zig").Status;
const Canvas = @import("../canvas.zig").Canvas;
const layout = @import("../layout.zig");
const Rect = layout.Rect;
const Metrics = layout.Metrics;
const Look = @import("../panel.zig").Look;

const terminal_label = "Terminal";

/// Where the terminal button is in the bar.
pub fn terminalButton(metrics: Metrics, bar: Rect) Rect {
    const w = metrics.labelWidth(terminal_label) + 2 * metrics.cell;
    return .{ .x = bar.x + bar.w - w, .y = bar.y + 1, .w = w, .h = bar.h - 1 };
}

pub fn draw(canvas: Canvas, look: Look, status: Status, bar: Rect) void {
    const theme = look.theme;
    const metrics = look.metrics;
    canvas.fillRect(bar, theme.status_bar);
    canvas.fillRect(.{ .x = bar.x, .y = bar.y, .w = bar.w, .h = 1 }, theme.border);
    const y = metrics.center(bar.y, bar.h);
    const button = terminalButton(metrics, bar);
    if (status.terminal) canvas.fillRect(button, theme.list_inactive) else if (look.hovered(button)) canvas.fillRect(button, theme.hover);
    canvas.drawLabel(button.x + metrics.cell, y, terminal_label, if (status.terminal) theme.tab_active_text else theme.status_bar_text);
    canvas.drawLabel(button.x - metrics.cell - metrics.labelWidth(status.language), y, status.language, theme.status_bar_text);
    canvas.drawLabel(bar.x + metrics.cell, y, status.branch, theme.status_bar_text);
}
