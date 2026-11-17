//! A scrollable list of rows: text, color, indent, a one-character icon and
//! a mark at the right end. Only the visible rows are asked for and drawn,
//! so the number of rows does not matter. Used by the file tree, messages,
//! search results and the git panel.
const std = @import("std");
const Canvas = @import("../canvas.zig").Canvas;
const layout = @import("../layout.zig");
const Rect = layout.Rect;
const Metrics = layout.Metrics;
const Look = @import("../panel.zig").Look;
const Color = @import("../theme.zig").Color;
const event_zig = @import("../../platform/event.zig");
const KeyPress = event_zig.KeyPress;
const Event = event_zig.Event;
const Scrollbar = @import("scrollbar.zig").Scrollbar;

pub const Row = struct {
    text: []const u8,
    color: Color,
    /// Dimmed text after `text`, like the path of a folder.
    detail: []const u8 = "",
    /// Levels of two cells each.
    indent: usize = 0,
    /// Drawn in the code font, like the arrows of folders.
    icon: u21 = ' ',
    /// A letter at the right end, like the git status of a file.
    mark: ?Mark = null,

    pub const Mark = struct { char: u21, color: Color };
};

pub const Action = enum { moved, activate };

pub const List = struct {
    /// First visible row.
    top: usize = 0,
    selected: usize = 0,
    /// Where the scrollbar thumb is held while it is dragged.
    grabbed: ?f32 = null,

    fn scrollbar(self: *const List, rect: Rect, metrics: Metrics, count: usize) Scrollbar {
        const rows = rowsIn(rect, metrics);
        return .{ .track = Scrollbar.trackOf(rect, metrics), .first = self.top, .last = count -| rows, .shown = rows };
    }

    /// Presses, drags and releases of the scrollbar. True when it used the event.
    pub fn scrollbarEvent(self: *List, event: Event, rect: Rect, metrics: Metrics, count: usize) bool {
        const bar = self.scrollbar(rect, metrics, count);
        switch (event) {
            .mouse_down => |mouse| {
                if (!bar.visible() or !bar.track.contains(mouse.x, mouse.y)) return false;
                self.grabbed = bar.grab(mouse.y);
                self.top = bar.firstAt(mouse.y, self.grabbed.?);
            },
            .mouse_move => |mouse| self.top = bar.firstAt(mouse.y, self.grabbed orelse return false),
            .mouse_up => if (self.grabbed == null) return false else {
                self.grabbed = null;
            },
            else => return false,
        }
        return true;
    }

    /// Rows that fit in `rect`.
    pub fn rowsIn(rect: Rect, metrics: Metrics) usize {
        return @intFromFloat(@max(0, rect.h) / metrics.item());
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

    /// The row at pixel `y`, if there is one.
    pub fn rowAt(self: *const List, y: f32, rect: Rect, metrics: Metrics, count: usize) ?usize {
        if (y < rect.y) return null;
        const row = self.top + @as(usize, @intFromFloat((y - rect.y) / metrics.item()));
        return if (row < count) row else null;
    }

    /// A click at pixel `y` selects a row; a double click activates it.
    pub fn click(self: *List, y: f32, rect: Rect, metrics: Metrics, count: usize, clicks: u8) ?Action {
        self.selected = self.rowAt(y, rect, metrics, count) orelse return null;
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
        var top = rect.y;
        for (self.top..@min(count, self.top + rows)) |index| {
            const line: Rect = .{ .x = rect.x, .y = top, .w = rect.w, .h = metrics.item() };
            const fill = if (index == self.selected) (if (focused) look.theme.list_selection else look.theme.list_inactive) else if (look.hovered(line)) look.theme.hover else null;
            if (fill) |color| canvas.fillRect(line, color);
            const row: Row = source.row(index);
            const x = rect.x + @as(f32, @floatFromInt(1 + 2 * row.indent)) * metrics.cell;
            const y = metrics.center(top, line.h);
            var bytes: [4]u8 = undefined;
            if (row.icon != ' ') canvas.drawText(x, y, encode(row.icon, &bytes), look.theme.line_number);
            canvas.drawLabel(x + 2 * metrics.cell, y, row.text, row.color);
            if (row.detail.len > 0) {
                const detail_x = x + 3 * metrics.cell + metrics.labelWidth(row.text);
                canvas.drawLabel(detail_x, y, row.detail, look.theme.line_number);
            }
            if (row.mark) |mark| canvas.drawLabel(rect.x + rect.w - 2 * metrics.cell, y, encode(mark.char, &bytes), mark.color);
            top += line.h;
        }
        self.scrollbar(rect, metrics, count).draw(canvas, look);
    }
};

fn encode(char: u21, bytes: *[4]u8) []const u8 {
    return bytes[0 .. std.unicode.utf8Encode(char, bytes) catch 0];
}

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
    const rect: Rect = .{ .y = 100, .w = 200, .h = 240 };
    try testing.expectEqual(@as(?Action, .moved), list.click(100 + 49, rect, metrics, 50, 1));
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
    list.draw(recorder.canvas(), .{ .theme = &dark, .metrics = .init(1) }, .{ .w = 100, .h = 240 }, 100_000, &source, true);
    try testing.expectEqual(@as(usize, 10), source.asked);
    // One cell of margin, two of indent, two for the icon.
    try testing.expectEqual(@as(f32, 5 * 8), recorder.find("row 99981").?.x);
    // The selected row and the scrollbar thumb.
    try testing.expectEqual(@as(usize, 2), recorder.fills.items.len);
}
