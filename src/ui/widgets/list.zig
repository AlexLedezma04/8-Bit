//! A scrollable list of rows: text, color, indent and a one-character icon.
//! Only the visible rows are asked for and drawn, so the number of rows
//! does not matter. Used by the file tree, messages and later search and git.
const std = @import("std");
const Canvas = @import("../canvas.zig").Canvas;
const layout = @import("../layout.zig");
const Rect = layout.Rect;
const Metrics = layout.Metrics;
const Look = @import("../panel.zig").Look;
const Color = @import("../theme.zig").Color;
const KeyPress = @import("../../platform/event.zig").KeyPress;

pub const Row = struct {
    text: []const u8,
    color: Color,
    /// Levels of two cells each.
    indent: usize = 0,
    icon: u8 = ' ',
};

pub const Action = enum { moved, activate };

pub const List = struct {
    /// First visible row.
    top: usize = 0,
    selected: usize = 0,

    /// Rows that fit in `rect`.
    pub fn rowsIn(rect: Rect, metrics: Metrics) usize {
        return @intFromFloat(@max(0, rect.h) / metrics.row);
    }

    /// Up, Down, Page Up, Page Down, Home and End move; Enter activates.
    /// Null for any other key.
    pub fn key(self: *List, press: KeyPress, count: usize, rows: usize) ?Action {
        if (press.mods.ctrl or press.mods.alt) return null;
        const page = @max(rows, 2) - 1;
        const last = count -| 1;
        self.selected = switch (press.key) {
            .up => self.selected -| 1,
            .down => @min(self.selected + 1, last),
            .page_up => self.selected -| page,
            .page_down => @min(self.selected + page, last),
            .home => 0,
            .end => last,
            .enter => return .activate,
            else => return null,
        };
        self.reveal(rows);
        return .moved;
    }

    /// A click at pixel `y` selects a row; a double click activates it.
    pub fn click(self: *List, y: f32, rect: Rect, metrics: Metrics, count: usize, clicks: u8) ?Action {
        const row = self.top + @as(usize, @intFromFloat(@max(0, y - rect.y) / metrics.row));
        if (row >= count) return null;
        self.selected = row;
        return if (clicks >= 2) .activate else .moved;
    }

    pub fn scroll(self: *List, delta: isize, count: usize, rows: usize) void {
        const max_top = count -| rows;
        const top: isize = @as(isize, @intCast(self.top)) + delta;
        self.top = @min(@as(usize, @intCast(@max(0, top))), max_top);
    }

    /// Keeps the selection in range and on screen.
    pub fn reveal(self: *List, rows: usize) void {
        if (rows == 0) return;
        if (self.selected < self.top) self.top = self.selected;
        if (self.selected >= self.top + rows) self.top = self.selected + 1 - rows;
    }

    /// Draws the visible rows. `source.row(i)` gives row `i` of `count`.
    pub fn draw(self: *List, canvas: Canvas, look: Look, rect: Rect, count: usize, source: anytype, focused: bool) void {
        const metrics = look.metrics;
        const rows = rowsIn(rect, metrics);
        self.selected = @min(self.selected, count -| 1);
        self.top = @min(self.top, count -| rows);
        var y = rect.y;
        for (self.top..@min(count, self.top + rows)) |index| {
            if (index == self.selected and count > 0) {
                const fill = if (focused) look.theme.list_selection else look.theme.current_line;
                canvas.fillRect(.{ .x = rect.x, .y = y, .w = rect.w, .h = metrics.row }, fill);
            }
            const row: Row = source.row(index);
            const x = rect.x + @as(f32, @floatFromInt(1 + 2 * row.indent)) * metrics.cell;
            if (row.icon != ' ') canvas.drawText(x, y, &.{row.icon}, look.theme.line_number);
            canvas.drawText(x + 2 * metrics.cell, y, row.text, row.color);
            y += metrics.row;
        }
    }
};

const testing = std.testing;

test "keys move the selection and keep it on screen" {
    var list: List = .{};
    try testing.expectEqual(@as(?Action, .moved), list.key(.{ .key = .down }, 100, 10));
    try testing.expectEqual(@as(usize, 1), list.selected);
    _ = list.key(.{ .key = .page_down }, 100, 10);
    try testing.expectEqual(@as(usize, 10), list.selected);
    try testing.expectEqual(@as(usize, 1), list.top);
    _ = list.key(.{ .key = .end }, 100, 10);
    try testing.expectEqual(@as(usize, 99), list.selected);
    try testing.expectEqual(@as(usize, 90), list.top);
    _ = list.key(.{ .key = .down }, 100, 10);
    try testing.expectEqual(@as(usize, 99), list.selected);
    _ = list.key(.{ .key = .home }, 100, 10);
    try testing.expectEqual(@as(usize, 0), list.top);
    try testing.expectEqual(@as(?Action, .activate), list.key(.{ .key = .enter }, 100, 10));
    try testing.expectEqual(@as(?Action, null), list.key(.{ .key = .char('a') }, 100, 10));
    try testing.expectEqual(@as(?Action, null), list.key(.{ .key = .down, .mods = .{ .ctrl = true } }, 100, 10));
}

test "clicks select, double clicks activate, the wheel scrolls" {
    var list: List = .{ .top = 5 };
    const metrics = Metrics.init(1);
    const rect: Rect = .{ .y = 100, .w = 200, .h = 160 };
    try testing.expectEqual(@as(?Action, .moved), list.click(100 + 33, rect, metrics, 50, 1));
    try testing.expectEqual(@as(usize, 7), list.selected);
    try testing.expectEqual(@as(?Action, .activate), list.click(100, rect, metrics, 50, 2));
    try testing.expectEqual(@as(?Action, null), list.click(159, rect, metrics, 6, 1));
    list.scroll(100, 50, 10);
    try testing.expectEqual(@as(usize, 40), list.top);
    list.scroll(-100, 50, 10);
    try testing.expectEqual(@as(usize, 0), list.top);
}

test "only the visible rows of a huge list are drawn" {
    const Recorder = @import("../canvas.zig").Recorder;
    const Source = struct {
        asked: usize = 0,
        buffer: [16]u8 = undefined,
        fn row(self: *@This(), index: usize) Row {
            self.asked += 1;
            return .{ .text = std.fmt.bufPrint(&self.buffer, "row {d}", .{index}) catch "", .color = .rgb(0), .indent = 1 };
        }
    };
    var recorder: Recorder = .{ .allocator = testing.allocator };
    defer recorder.deinit();
    const theme = @import("../theme.zig");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const dark = @import("../../editor/config.zig").builtin(theme.Theme, testing.allocator, arena.allocator(), "themes/dark");

    var list: List = .{ .selected = 99_990 };
    list.reveal(10);
    var source: Source = .{};
    list.draw(recorder.canvas(), .{ .theme = &dark, .metrics = .init(1) }, .{ .w = 100, .h = 160 }, 100_000, &source, true);
    try testing.expectEqual(@as(usize, 10), source.asked);
    // One cell of margin, two of indent, two for the icon.
    try testing.expectEqual(@as(f32, 5 * 8), recorder.find("row 99981").?.x);
    try testing.expectEqual(@as(usize, 1), recorder.fills);
}
