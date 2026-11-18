//! Where the parts of the window are: sidebar, editor panes, bottom panel,
//! status bar, and the gutter and text of each pane. Pure math, no drawing.
//! Every size comes from the cell size, so zooming scales everything.
const std = @import("std");
const fonts = @import("../font/fonts.zig");
const panes = @import("../editor/panes.zig");

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(self: Rect, x: f32, y: f32) bool {
        return x >= self.x and x < self.x + self.w and y >= self.y and y < self.y + self.h;
    }

    /// The top `h` pixels, and the rest below.
    pub fn splitTop(self: Rect, h: f32) [2]Rect {
        const top = @min(h, self.h);
        return .{
            .{ .x = self.x, .y = self.y, .w = self.w, .h = top },
            .{ .x = self.x, .y = self.y + top, .w = self.w, .h = self.h - top },
        };
    }
};

pub const Metrics = struct {
    /// Width of one character on screen.
    cell: f32,
    /// Height of a row of text. The font has its own space between lines.
    row: f32,

    pub fn init(zoom: u8) Metrics {
        const scale: f32 = @floatFromInt(zoom);
        return .{ .cell = fonts.cell_width * scale, .row = fonts.row_height * scale };
    }

    fn zoomLevel(self: Metrics) u8 {
        return @intFromFloat(self.cell / fonts.cell_width);
    }

    /// Width of a text in the UI font.
    pub fn labelWidth(self: Metrics, text: []const u8) f32 {
        return fonts.width(.ui, text, self.zoomLevel());
    }

    /// Height of a tab bar or a panel title.
    pub fn bar(self: Metrics) f32 {
        return @floor(self.row * 2.5);
    }

    /// Height of a list row, a menu item or the status bar.
    pub fn item(self: Metrics) f32 {
        return self.row + @floor(self.row / 2);
    }

    /// Top of a row of text centered in `h` pixels from `top`.
    pub fn center(self: Metrics, top: f32, h: f32) f32 {
        return top + @floor((h - self.row) / 2);
    }

    /// Top of text that is centered in a bar starting at `top`.
    pub fn barText(self: Metrics, top: f32) f32 {
        return self.center(top, self.bar());
    }

    /// Width of the text cursor.
    pub fn caret(self: Metrics) f32 {
        return @floor(self.cell / 4);
    }

    /// Whole cells that fit in `w` pixels.
    pub fn cols(self: Metrics, w: f32) usize {
        return @intFromFloat(@max(0, w) / self.cell);
    }

    /// Whole rows of text that fit in `h` pixels.
    pub fn rows(self: Metrics, h: f32) usize {
        return @intFromFloat(@max(0, h) / self.row);
    }
};

/// The parts of the window. A hidden dock is null.
pub const Frame = struct {
    sidebar: ?Rect,
    editor: Rect,
    bottom: ?Rect,
    status: Rect,

    /// Space the editor area always keeps, in cells and rows.
    const min_editor_cols = 12;
    const min_editor_rows = 4;
    /// Pixels on each side of a split line where a drag can start.
    pub const grip = 4;
    /// A dock edge can be grabbed a little on the dock's side and more on
    /// the other, so scrollbars next to it stay free.
    const dock_grip = .{ 2, 6 };

    /// `sidebar` is a width in cells, `bottom` a height in rows.
    pub fn init(width: f32, height: f32, metrics: Metrics, sidebar: ?u16, bottom: ?u16) Frame {
        const status_h = @min(metrics.item(), height);
        var main: Rect = .{ .w = width, .h = height - status_h };
        var frame: Frame = .{ .sidebar = null, .editor = main, .bottom = null, .status = .{ .y = main.h, .w = width, .h = status_h } };
        if (sidebar) |cols| {
            const w = @max(0, @min(@as(f32, @floatFromInt(cols)) * metrics.cell, width - min_editor_cols * metrics.cell));
            frame.sidebar = .{ .w = w, .h = main.h };
            main.x = w + 1;
            main.w = @max(0, width - w - 1);
        }
        if (bottom) |rows| {
            const h = @max(0, @min(@as(f32, @floatFromInt(rows)) * metrics.row, main.h - min_editor_rows * metrics.row));
            frame.bottom = .{ .x = main.x, .y = main.h - h, .w = main.w, .h = h };
            main.h = @max(0, main.h - h - 1);
        }
        frame.editor = main;
        return frame;
    }

    pub const Edge = enum { sidebar, bottom };

    /// The dock edge under a pixel, for resizing: the sidebar's reaches
    /// into the editor, the bottom panel's into the terminal tabs.
    pub fn edgeAt(self: Frame, x: f32, y: f32) ?Edge {
        if (self.sidebar) |side| {
            const edge = side.x + side.w;
            if (x >= edge - dock_grip[0] and x <= edge + dock_grip[1] and y < side.h) return .sidebar;
        }
        if (self.bottom) |bottom| {
            if (y >= bottom.y - dock_grip[0] and y <= bottom.y + dock_grip[1] and x >= bottom.x) return .bottom;
        }
        return null;
    }

    /// Dock size for an edge dragged to a pixel: cells or rows.
    pub fn sizeAt(self: Frame, edge: Edge, metrics: Metrics, x: f32, y: f32) u16 {
        const size = switch (edge) {
            .sidebar => x / metrics.cell,
            .bottom => (self.status.y - y) / metrics.row,
        };
        return @intFromFloat(std.math.clamp(@round(size), 2, 500));
    }
};

/// A pane and where it is.
pub const Placed = struct { node: *panes.Node, rect: Rect };

/// The line between the two halves of a split, and the space they share.
pub const Splitter = struct { split: *panes.Split, area: Rect, line: Rect };

/// Places the panes of the tree in `rect`, with a one-pixel line between
/// halves.
pub fn placePanes(
    allocator: std.mem.Allocator,
    node: *panes.Node,
    rect: Rect,
    placed: *std.ArrayList(Placed),
    splitters: *std.ArrayList(Splitter),
) !void {
    switch (node.kind) {
        .pane => try placed.append(allocator, .{ .node = node, .rect = rect }),
        .split => |*split| {
            var first = rect;
            var second = rect;
            var line = rect;
            switch (split.axis) {
                .right => {
                    first.w = @floor(@max(0, rect.w - 1) * split.ratio);
                    line = .{ .x = rect.x + first.w, .y = rect.y, .w = 1, .h = rect.h };
                    second.x = line.x + 1;
                    second.w = @max(0, rect.w - first.w - 1);
                },
                .down => {
                    first.h = @floor(@max(0, rect.h - 1) * split.ratio);
                    line = .{ .x = rect.x, .y = rect.y + first.h, .w = rect.w, .h = 1 };
                    second.y = line.y + 1;
                    second.h = @max(0, rect.h - first.h - 1);
                },
            }
            try splitters.append(allocator, .{ .split = split, .area = rect, .line = line });
            try placePanes(allocator, split.first, first, placed, splitters);
            try placePanes(allocator, split.second, second, placed, splitters);
        },
    }
}

/// The share of a split's area before a pixel, kept away from the ends.
pub fn ratioAt(splitter: Splitter, x: f32, y: f32) f32 {
    const area = splitter.area;
    const share = switch (splitter.split.axis) {
        .right => (x - area.x) / @max(1, area.w),
        .down => (y - area.y) / @max(1, area.h),
    };
    return std.math.clamp(share, 0.1, 0.9);
}

/// A cell of the text area. Negative or too large when outside of it.
pub const Cell = struct { x: isize, y: isize };

/// The gutter and text of one pane.
pub const TextLayout = struct {
    metrics: Metrics,
    gutter: Rect,
    text: Rect,
    /// Cells of the gutter: one for markers, the gutter text, the line
    /// number, and one of space before the text.
    gutter_text_cols: usize,
    number_cols: usize,
    /// Whole cells that fit in the text area.
    cols: usize,
    rows: usize,

    const min_number_cols = 2;

    /// Without a `line_count`, there are no line numbers.
    pub fn init(area: Rect, metrics: Metrics, line_count: ?usize, gutter_text_cols: usize) TextLayout {
        const number_cols = if (line_count) |count| @max(min_number_cols, std.math.log10_int(count) + 1) else 0;
        const gutter_cols: f32 = @floatFromInt(1 + gutter_text_cols + number_cols + 1);
        const gutter_w = @min(gutter_cols * metrics.cell, area.w);
        const text: Rect = .{ .x = area.x + gutter_w, .y = area.y, .w = area.w - gutter_w, .h = area.h };
        return .{
            .metrics = metrics,
            .gutter = .{ .x = area.x, .y = area.y, .w = gutter_w, .h = area.h },
            .text = text,
            .gutter_text_cols = gutter_text_cols,
            .number_cols = number_cols,
            .cols = metrics.cols(text.w),
            .rows = metrics.rows(text.h),
        };
    }

    /// The text cell under a window pixel.
    pub fn cellAt(self: TextLayout, x: f32, y: f32) Cell {
        return .{
            .x = @intFromFloat(@floor((x - self.text.x) / self.metrics.cell)),
            .y = @intFromFloat(@floor((y - self.text.y) / self.metrics.row)),
        };
    }

    /// Top-left pixel of a text cell.
    pub fn cellRect(self: TextLayout, column: usize, row: usize, columns: usize) Rect {
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
    try testing.expectEqual(Metrics{ .cell = 8, .row = 16 }, Metrics.init(1));
    try testing.expectEqual(Metrics{ .cell = 16, .row = 32 }, Metrics.init(2));
    try testing.expectEqual(@as(f32, 40), Metrics.init(1).bar());
    try testing.expectEqual(@as(f32, 24), Metrics.init(1).item());
    try testing.expectEqual(@as(f32, 112), Metrics.init(1).barText(100));
}

test "the window: sidebar, editor, bottom panel and status bar" {
    const metrics = Metrics.init(1);
    const plain = Frame.init(800, 600, metrics, null, null);
    try testing.expectEqual(Rect{ .w = 800, .h = 576 }, plain.editor);
    try testing.expectEqual(Rect{ .y = 576, .w = 800, .h = 24 }, plain.status);

    const full = Frame.init(800, 600, metrics, 30, 10);
    try testing.expectEqual(Rect{ .w = 240, .h = 576 }, full.sidebar.?);
    try testing.expectEqual(Rect{ .x = 241, .y = 416, .w = 559, .h = 160 }, full.bottom.?);
    try testing.expectEqual(Rect{ .x = 241, .w = 559, .h = 415 }, full.editor);

    // Docks never squeeze the editor away.
    const big = Frame.init(800, 600, metrics, 500, 500);
    try testing.expectEqual(@as(f32, 800 - 12 * 8), big.sidebar.?.w);
    try testing.expect(big.editor.h >= 4 * 16 - 1);
}

test "dock edges can be found and dragged" {
    const metrics = Metrics.init(1);
    const frame = Frame.init(800, 600, metrics, 30, 10);
    try testing.expectEqual(@as(?Frame.Edge, .sidebar), frame.edgeAt(242, 100));
    try testing.expectEqual(@as(?Frame.Edge, .bottom), frame.edgeAt(400, 414));
    try testing.expectEqual(@as(?Frame.Edge, null), frame.edgeAt(400, 300));
    // Two pixels into the sidebar, six into the editor; the same into the
    // editor and the terminal tabs for the bottom edge.
    try testing.expectEqual(@as(?Frame.Edge, .sidebar), frame.edgeAt(238, 100));
    try testing.expectEqual(@as(?Frame.Edge, null), frame.edgeAt(237, 100));
    try testing.expectEqual(@as(?Frame.Edge, .sidebar), frame.edgeAt(246, 100));
    try testing.expectEqual(@as(?Frame.Edge, null), frame.edgeAt(247, 100));
    try testing.expectEqual(@as(?Frame.Edge, .bottom), frame.edgeAt(400, 422));
    try testing.expectEqual(@as(?Frame.Edge, null), frame.edgeAt(400, 413));
    try testing.expectEqual(@as(u16, 40), frame.sizeAt(.sidebar, metrics, 320, 0));
    try testing.expectEqual(@as(u16, 20), frame.sizeAt(.bottom, metrics, 0, 576 - 320));
}

test "panes are placed by the split tree" {
    const root = try panes.Node.create(testing.allocator);
    defer root.destroy(testing.allocator);
    const right = try root.split(testing.allocator, .right);
    _ = try right.split(testing.allocator, .down);

    var placed: std.ArrayList(Placed) = .empty;
    defer placed.deinit(testing.allocator);
    var splitters: std.ArrayList(Splitter) = .empty;
    defer splitters.deinit(testing.allocator);
    try placePanes(testing.allocator, root, .{ .w = 201, .h = 101 }, &placed, &splitters);

    try testing.expectEqual(@as(usize, 3), placed.items.len);
    try testing.expectEqual(Rect{ .w = 100, .h = 101 }, placed.items[0].rect);
    try testing.expectEqual(Rect{ .x = 101, .w = 100, .h = 50 }, placed.items[1].rect);
    try testing.expectEqual(Rect{ .x = 101, .y = 51, .w = 100, .h = 50 }, placed.items[2].rect);
    try testing.expectEqual(@as(usize, 2), splitters.items.len);
    try testing.expectEqual(@as(f32, 0.25), ratioAt(splitters.items[0], 50.25, 0));
    try testing.expectEqual(@as(f32, 0.9), ratioAt(splitters.items[1], 0, 1000));
}

test "a pane: gutter that fits the line numbers, and text" {
    const layout = TextLayout.init(.{ .x = 10, .y = 20, .w = 800, .h = 600 }, .init(1), 120, 0);
    // Gutter: marker + 3 digits + space = 5 cells.
    try testing.expectEqual(Rect{ .x = 10, .y = 20, .w = 40, .h = 600 }, layout.gutter);
    try testing.expectEqual(Rect{ .x = 50, .y = 20, .w = 760, .h = 600 }, layout.text);
    try testing.expectEqual(@as(usize, 95), layout.cols);
    try testing.expectEqual(@as(usize, 37), layout.rows);
    try testing.expectEqual(@as(usize, 7), TextLayout.init(.{ .w = 800 }, .init(1), 1_000_000, 0).number_cols);
    try testing.expectEqual(@as(f32, 8 * 2), TextLayout.init(.{ .w = 800 }, .init(1), null, 0).gutter.w);
}

test "a tiny pane gives no cells instead of negative sizes" {
    const layout = TextLayout.init(.{ .w = 10, .h = 4 }, .init(2), 1, 0);
    try testing.expectEqual(@as(usize, 0), layout.cols);
    try testing.expectEqual(@as(usize, 0), layout.rows);
    try testing.expectEqual(@as(f32, 0), layout.text.w);
}

test "pixels map to text cells and back" {
    const layout = TextLayout.init(.{ .w = 800, .h = 600 }, .init(1), 1, 0);
    try testing.expectEqual(Cell{ .x = 0, .y = 0 }, layout.cellAt(32, 0));
    try testing.expectEqual(Cell{ .x = 2, .y = 1 }, layout.cellAt(32 + 20, 17));
    try testing.expectEqual(Cell{ .x = -1, .y = -1 }, layout.cellAt(31, -1));
    try testing.expectEqual(Rect{ .x = 48, .y = 16, .w = 24, .h = 16 }, layout.cellRect(2, 1, 3));
}
