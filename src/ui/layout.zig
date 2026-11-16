//! Where the parts of the window are: gutter, text area, status bar.
//! Every size comes from the cell size, so zooming scales everything.
const std = @import("std");
const font_cell = @import("../font/bitmap_font.zig").cell;

pub const Rect = struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };

pub const Metrics = struct {
    /// Width and height of one character on screen.
    cell: f32,
    /// Height of a row of text: the character plus a little air.
    row: f32,

    /// `zoom` is screen pixels per font pixel.
    pub fn init(zoom: u8) Metrics {
        const cell: f32 = @floatFromInt(font_cell * @as(usize, zoom));
        return .{ .cell = cell, .row = cell + cell / 4 };
    }

    /// Top of a character that is centered in a row starting at `row_top`.
    pub fn textTop(self: Metrics, row_top: f32) f32 {
        return row_top + (self.row - self.cell) / 2;
    }
};

/// A cell of the text area. Negative or too large when outside of it.
pub const Cell = struct { x: isize, y: isize };

pub const Layout = struct {
    metrics: Metrics,
    gutter: Rect,
    text: Rect,
    status: Rect,
    /// Cells of the gutter: one for markers, the gutter text, the line
    /// number, and one of space before the text.
    gutter_text_cols: usize,
    number_cols: usize,
    /// Whole cells that fit in the text area.
    cols: usize,
    rows: usize,

    const min_number_cols = 2;

    pub fn init(width: f32, height: f32, metrics: Metrics, line_count: usize, gutter_text_cols: usize) Layout {
        const number_cols = @max(min_number_cols, std.math.log10_int(line_count) + 1);
        const gutter_cols: f32 = @floatFromInt(1 + gutter_text_cols + number_cols + 1);
        const gutter_w = @min(gutter_cols * metrics.cell, width);
        const status_h = @min(metrics.row, height);
        const text: Rect = .{ .x = gutter_w, .w = width - gutter_w, .h = height - status_h };
        return .{
            .metrics = metrics,
            .gutter = .{ .w = gutter_w, .h = text.h },
            .text = text,
            .status = .{ .y = text.h, .w = width, .h = status_h },
            .gutter_text_cols = gutter_text_cols,
            .number_cols = number_cols,
            .cols = @intFromFloat(text.w / metrics.cell),
            .rows = @intFromFloat(text.h / metrics.row),
        };
    }

    /// The text cell under a window pixel.
    pub fn cellAt(self: Layout, x: f32, y: f32) Cell {
        return .{
            .x = @intFromFloat(@floor((x - self.text.x) / self.metrics.cell)),
            .y = @intFromFloat(@floor((y - self.text.y) / self.metrics.row)),
        };
    }

    /// Top-left pixel of a text cell.
    pub fn cellRect(self: Layout, column: usize, row: usize, columns: usize) Rect {
        return .{
            .x = self.text.x + @as(f32, @floatFromInt(column)) * self.metrics.cell,
            .y = self.text.y + @as(f32, @floatFromInt(row)) * self.metrics.row,
            .w = @as(f32, @floatFromInt(columns)) * self.metrics.cell,
            .h = self.metrics.row,
        };
    }
};

const testing = std.testing;

test "metrics scale with the zoom" {
    try testing.expectEqual(Metrics{ .cell = 8, .row = 10 }, Metrics.init(1));
    try testing.expectEqual(Metrics{ .cell = 16, .row = 20 }, Metrics.init(2));
    try testing.expectEqual(@as(f32, 102), Metrics.init(2).textTop(100));
}

test "the window is split into gutter, text and status bar" {
    const layout = Layout.init(800, 600, .init(2), 120, 0);
    // Gutter: marker + 3 digits + space = 5 cells.
    try testing.expectEqual(Rect{ .w = 80, .h = 580 }, layout.gutter);
    try testing.expectEqual(Rect{ .x = 80, .w = 720, .h = 580 }, layout.text);
    try testing.expectEqual(Rect{ .y = 580, .w = 800, .h = 20 }, layout.status);
    try testing.expectEqual(@as(usize, 45), layout.cols);
    try testing.expectEqual(@as(usize, 29), layout.rows);
}

test "the gutter fits the largest line number and the gutter text" {
    try testing.expectEqual(@as(usize, 2), Layout.init(800, 600, .init(1), 1, 0).number_cols);
    try testing.expectEqual(@as(usize, 2), Layout.init(800, 600, .init(1), 99, 0).number_cols);
    try testing.expectEqual(@as(usize, 3), Layout.init(800, 600, .init(1), 100, 0).number_cols);
    try testing.expectEqual(@as(usize, 7), Layout.init(800, 600, .init(1), 1_000_000, 0).number_cols);
    try testing.expectEqual(@as(f32, 8 * 12), Layout.init(800, 600, .init(1), 1, 8).gutter.w);
}

test "a tiny window gives no cells instead of negative sizes" {
    const layout = Layout.init(10, 4, .init(2), 1, 0);
    try testing.expectEqual(@as(usize, 0), layout.cols);
    try testing.expectEqual(@as(usize, 0), layout.rows);
    try testing.expectEqual(@as(f32, 0), layout.text.w);
}

test "pixels map to text cells and back" {
    const layout = Layout.init(800, 600, .init(2), 1, 0);
    try testing.expectEqual(Cell{ .x = 0, .y = 0 }, layout.cellAt(64, 0));
    try testing.expectEqual(Cell{ .x = 2, .y = 1 }, layout.cellAt(64 + 40, 39));
    try testing.expectEqual(Cell{ .x = -1, .y = -1 }, layout.cellAt(63, -1));
    try testing.expectEqual(Rect{ .x = 96, .y = 20, .w = 48, .h = 20 }, layout.cellRect(2, 1, 3));
}
