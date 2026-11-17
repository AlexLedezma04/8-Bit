//! The bottom line: the git branch on the left, the language of the file
//! on the right.
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
    const cols = look.metrics.cols(bar.w) -| 2;
    const language = utf8.prefix(status.language, cols);
    const language_cols = utf8.count(language);
    canvas.drawText(bar.x + bar.w - @as(f32, @floatFromInt(language_cols + 1)) * cell, bar.y, language, theme.status_bar_text);
    canvas.drawText(bar.x + cell, bar.y, utf8.prefix(status.branch, cols -| (language_cols + 2)), theme.status_bar_text);
}
