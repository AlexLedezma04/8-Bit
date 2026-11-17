//! A small picture of a whole file at the right of its text: the words of
//! each line as bars, its changes at the left edge and the part on screen.
//! A file too long to fit is squeezed: some lines are skipped, changes never.
const std = @import("std");
const Canvas = @import("../canvas.zig").Canvas;
const layout = @import("../layout.zig");
const Rect = layout.Rect;
const Metrics = layout.Metrics;
const Look = @import("../panel.zig").Look;
const Document = @import("../../core/edit.zig").Document;
const Decoration = @import("../../editor/decoration.zig").Decoration;

pub const Minimap = struct {
    rect: Rect,
    lines: usize,
    /// One pixel of the font: a character is one wide, a line two high.
    pixel: f32,
    /// Pixels per line.
    scale: f32,

    pub fn width(metrics: Metrics) f32 {
        return 10 * metrics.cell;
    }

    pub fn init(rect: Rect, metrics: Metrics, lines: usize) Minimap {
        const pixel = metrics.cell / 8;
        return .{ .rect = rect, .lines = lines, .pixel = pixel, .scale = @min(2 * pixel, rect.h / @as(f32, @floatFromInt(lines))) };
    }

    /// The line drawn at a window pixel row.
    pub fn lineAt(self: Minimap, y: f32) usize {
        const line: usize = @intFromFloat(@max(0, (y - self.rect.y) / self.scale));
        return @min(line, self.lines - 1);
    }

    fn yOf(self: Minimap, line: usize) f32 {
        return self.rect.y + @as(f32, @floatFromInt(line)) * self.scale;
    }

    /// `top` and `rows` are the lines on screen.
    pub fn draw(self: Minimap, canvas: Canvas, look: Look, doc: *const Document, changes: []const Decoration, top: usize, rows: usize) void {
        const theme = look.theme;
        const row = 2 * self.pixel;
        canvas.fillRect(.{ .x = self.rect.x, .y = self.yOf(top), .w = self.rect.w, .h = @max(row, @as(f32, @floatFromInt(rows)) * self.scale) }, theme.current_line);
        for (changes) |mark| {
            const style = mark.changeStyle() orelse continue;
            const y = self.yOf(doc.buffer.lineOf(mark.range.start));
            const end = self.yOf(doc.buffer.lineOf(mark.range.end) + 1);
            canvas.fillRect(.{ .x = self.rect.x, .y = y, .w = row, .h = @max(row, end - y) }, theme.styleColor(style));
        }
        var slot: f32 = 0;
        while (slot * row < self.rect.h) : (slot += 1) {
            const line: usize = @intFromFloat(slot * row / self.scale);
            if (line >= self.lines) break;
            self.drawLine(canvas, look, doc, line, self.rect.y + slot * row);
        }
    }

    /// Each run of characters that are not blank is one bar.
    fn drawLine(self: Minimap, canvas: Canvas, look: Look, doc: *const Document, line: usize, y: f32) void {
        const left = self.rect.x + 4 * self.pixel;
        const max_cols: usize = @intFromFloat(@max(0, self.rect.x + self.rect.w - left) / self.pixel);
        var start: ?usize = null;
        var cells = doc.cells(line);
        while (cells.next()) |cell| {
            if (cell.column >= max_cols) break;
            const blank = cell.char.cp == ' ' or cell.char.cp == '\t';
            if (!blank and start == null) start = cell.column;
            if (!blank) continue;
            const from = start orelse continue;
            canvas.fillRect(self.bar(left, y, from, cell.column), look.theme.line_number);
            start = null;
        }
        const from = start orelse return;
        canvas.fillRect(self.bar(left, y, from, @min(max_cols, doc.columnOf(doc.buffer.lineEnd(line)))), look.theme.line_number);
    }

    fn bar(self: Minimap, left: f32, y: f32, from: usize, to: usize) Rect {
        return .{ .x = left + @as(f32, @floatFromInt(from)) * self.pixel, .y = y, .w = @as(f32, @floatFromInt(to - from)) * self.pixel, .h = self.pixel };
    }
};

const testing = std.testing;

test "lines take two pixels, fewer when the file does not fit" {
    const rect: Rect = .{ .x = 700, .y = 40, .w = 80, .h = 400 };
    const short = Minimap.init(rect, .init(1), 10);
    try testing.expectEqual(@as(f32, 2), short.scale);
    try testing.expectEqual(@as(usize, 3), short.lineAt(40 + 7));
    try testing.expectEqual(@as(usize, 9), short.lineAt(400));
    try testing.expectEqual(@as(usize, 0), short.lineAt(0));
    const long = Minimap.init(rect, .init(2), 1000);
    try testing.expectEqual(@as(f32, 0.4), long.scale);
    try testing.expectEqual(@as(usize, 999), long.lineAt(40 + 400));
}
