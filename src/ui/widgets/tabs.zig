//! A bar of tabs. Each tab has a title and, after it, a close button, or a
//! dot while it has unsaved changes. When the tabs do not fit, the bar
//! scrolls so the active one is in view. Used by editor panes, later by the
//! sidebar switch and the terminal.
const std = @import("std");
const Canvas = @import("../canvas.zig").Canvas;
const layout = @import("../layout.zig");
const Rect = layout.Rect;
const Metrics = layout.Metrics;
const Look = @import("../panel.zig").Look;

pub const Item = struct { title: []const u8, modified: bool = false };

pub const Hit = struct { index: usize, close: bool };

/// A space, the title, a space, the close button, a space.
fn cols(item: Item) usize {
    return (std.unicode.utf8CountCodepoints(item.title) catch item.title.len) + 4;
}

/// One tab and the cells it takes.
const Place = struct { index: usize, x: usize, cols: usize };

/// Walks the tabs that are drawn, from the first one that keeps `active`
/// in view.
const Places = struct {
    items: []const Item,
    index: usize,
    x: usize = 0,
    width: usize,

    fn init(items: []const Item, active: usize, width: usize) Places {
        var first = @min(active, items.len -| 1);
        var used: usize = if (items.len > 0) cols(items[first]) else 0;
        while (first > 0 and used + cols(items[first - 1]) <= width) {
            first -= 1;
            used += cols(items[first]);
        }
        return .{ .items = items, .index = first, .width = width };
    }

    fn next(self: *Places) ?Place {
        if (self.index >= self.items.len or self.x >= self.width) return null;
        const place: Place = .{ .index = self.index, .x = self.x, .cols = cols(self.items[self.index]) };
        self.index += 1;
        self.x += place.cols;
        return place;
    }
};

/// The tab, and whether its close button, under a pixel.
pub fn hit(rect: Rect, metrics: Metrics, items: []const Item, active: usize, x: f32, y: f32) ?Hit {
    if (!rect.contains(x, y)) return null;
    const cell: usize = @intFromFloat((x - rect.x) / metrics.cell);
    var places = Places.init(items, active, metrics.cols(rect.w));
    while (places.next()) |place| {
        if (cell >= place.x + place.cols) continue;
        return .{ .index = place.index, .close = cell + 2 == place.x + place.cols };
    }
    return null;
}

/// `focused` underlines the active tab in the accent color.
pub fn draw(canvas: Canvas, look: Look, rect: Rect, items: []const Item, active: usize, focused: bool) void {
    const theme = look.theme;
    const metrics = look.metrics;
    canvas.fillRect(rect, theme.tab);
    canvas.fillRect(.{ .x = rect.x, .y = rect.y + rect.h - 1, .w = rect.w, .h = 1 }, theme.border);
    canvas.setClip(rect);
    defer canvas.setClip(null);
    const text_y = metrics.barText(rect.y);
    var places = Places.init(items, active, metrics.cols(rect.w));
    while (places.next()) |place| {
        const item = items[place.index];
        const x = rect.x + @as(f32, @floatFromInt(place.x)) * metrics.cell;
        const w = @as(f32, @floatFromInt(place.cols)) * metrics.cell;
        const is_active = place.index == active;
        if (is_active) {
            canvas.fillRect(.{ .x = x, .y = rect.y, .w = w, .h = rect.h }, theme.tab_active);
            const line = @max(2, @floor(metrics.cell / 4));
            canvas.fillRect(.{ .x = x, .y = rect.y + rect.h - line, .w = w, .h = line }, if (focused) theme.accent else theme.border);
        }
        canvas.drawText(x + metrics.cell, text_y, item.title, if (is_active) theme.tab_active_text else theme.tab_text);
        const mark_x = x + w - 2 * metrics.cell;
        if (item.modified) {
            const dot = @floor(metrics.cell / 2);
            canvas.fillRect(.{ .x = mark_x + (metrics.cell - dot) / 2, .y = text_y + (metrics.row - dot) / 2, .w = dot, .h = dot }, theme.unsaved);
        } else {
            canvas.drawText(mark_x, text_y, "\u{D7}", theme.line_number);
        }
    }
}

const testing = std.testing;

test "clicks find the tab and its close button" {
    const metrics = Metrics.init(1);
    const items = [_]Item{ .{ .title = "a.zig" }, .{ .title = "bb.txt", .modified = true } };
    const rect: Rect = .{ .x = 100, .w = 400, .h = 24 };
    // "a.zig" takes 9 cells: 0..8, its close button is cell 7.
    try testing.expectEqual(Hit{ .index = 0, .close = false }, hit(rect, metrics, &items, 0, 100 + 8, 5).?);
    try testing.expectEqual(Hit{ .index = 0, .close = true }, hit(rect, metrics, &items, 0, 100 + 7 * 8 + 1, 5).?);
    try testing.expectEqual(Hit{ .index = 1, .close = false }, hit(rect, metrics, &items, 0, 100 + 9 * 8, 5).?);
    try testing.expectEqual(@as(?Hit, null), hit(rect, metrics, &items, 0, 100 + 30 * 8, 5));
    try testing.expectEqual(@as(?Hit, null), hit(rect, metrics, &items, 0, 50, 5));
}

test "too many tabs scroll so the active one is in view" {
    const items = [_]Item{ .{ .title = "one" }, .{ .title = "two" }, .{ .title = "three" }, .{ .title = "four" } };
    // 7 + 7 + 9 + 8 cells; 17 cells fit two short ones.
    var places = Places.init(&items, 3, 17);
    try testing.expectEqual(@as(usize, 2), places.next().?.index);
    try testing.expectEqual(Place{ .index = 3, .x = 9, .cols = 8 }, places.next().?);
    try testing.expectEqual(@as(?Place, null), places.next());

    places = Places.init(&items, 0, 17);
    try testing.expectEqual(@as(usize, 0), places.next().?.index);
}
