//! A bar of tabs. Each tab has a title and, after it, a close button, or a
//! dot while it has unsaved changes. When the tabs do not fit, the bar
//! scrolls so the active one is in view. Used by editor panes, the dock
//! bars, the pages of the git panel and the terminal.
const std = @import("std");
const Canvas = @import("../canvas.zig").Canvas;
const layout = @import("../layout.zig");
const Rect = layout.Rect;
const Metrics = layout.Metrics;
const Look = @import("../panel.zig").Look;
const Color = @import("../theme.zig").Color;

pub const Item = struct {
    title: []const u8,
    modified: bool = false,
    /// Has a close button.
    closable: bool = true,
};

pub const Hit = struct { index: usize, close: bool };

/// Cells of space at each end of a tab, and of its close button.
const pad = 1.5;
const button = 2;

fn width(item: Item, metrics: Metrics) f32 {
    const extra: f32 = if (item.closable) 2 * pad + button else 2 * pad;
    return metrics.labelWidth(item.title) + extra * metrics.cell;
}

/// One tab and the pixels it takes from the left of the bar.
const Place = struct { index: usize, x: f32, w: f32 };

/// Walks the tabs that are drawn, from the first one that keeps `active`
/// in view.
const Places = struct {
    items: []const Item,
    metrics: Metrics,
    index: usize,
    x: f32 = 0,
    width: f32,

    fn init(items: []const Item, metrics: Metrics, active: usize, w: f32) Places {
        var first = @min(active, items.len -| 1);
        var used: f32 = if (items.len > 0) width(items[first], metrics) else 0;
        while (first > 0 and used + width(items[first - 1], metrics) <= w) {
            first -= 1;
            used += width(items[first], metrics);
        }
        return .{ .items = items, .metrics = metrics, .index = first, .width = w };
    }

    fn next(self: *Places) ?Place {
        if (self.index >= self.items.len or self.x >= self.width) return null;
        const place: Place = .{ .index = self.index, .x = self.x, .w = width(self.items[self.index], self.metrics) };
        self.index += 1;
        self.x += place.w;
        return place;
    }
};

/// Where the close button of a tab is.
fn buttonX(place: Place, metrics: Metrics) f32 {
    return place.x + place.w - (pad + button) * metrics.cell;
}

/// The tab, and whether its close button, under a pixel.
pub fn hit(rect: Rect, metrics: Metrics, items: []const Item, active: usize, x: f32, y: f32) ?Hit {
    if (!rect.contains(x, y)) return null;
    const at = x - rect.x;
    var places = Places.init(items, metrics, active, rect.w);
    while (places.next()) |place| {
        if (at >= place.x + place.w) continue;
        const start = buttonX(place, metrics);
        return .{ .index = place.index, .close = items[place.index].closable and at >= start and at < start + button * metrics.cell };
    }
    return null;
}

/// The active tab is underlined, in the accent color when `focused`.
pub fn draw(canvas: Canvas, look: Look, rect: Rect, items: []const Item, active: usize, focused: bool, background: Color) void {
    const theme = look.theme;
    const metrics = look.metrics;
    canvas.fillRect(rect, background);
    canvas.fillRect(.{ .x = rect.x, .y = rect.y + rect.h - 1, .w = rect.w, .h = 1 }, theme.border);
    canvas.setClip(rect);
    defer canvas.setClip(null);
    const text_y = metrics.barText(rect.y);
    var places = Places.init(items, metrics, active, rect.w);
    while (places.next()) |place| {
        const item = items[place.index];
        const x = rect.x + place.x;
        const is_active = place.index == active;
        const tab: Rect = .{ .x = x, .y = rect.y, .w = place.w, .h = rect.h - 1 };
        if (look.hovered(tab)) canvas.fillRect(tab, theme.hover);
        if (is_active) {
            const line = @floor(metrics.cell / 4);
            canvas.fillRect(.{ .x = x, .y = rect.y + rect.h - line, .w = place.w, .h = line }, if (focused) theme.accent else theme.list_inactive);
        }
        canvas.drawLabel(x + pad * metrics.cell, text_y, item.title, if (is_active) theme.tab_active_text else theme.tab_text);
        if (!item.closable) continue;
        const button_x = rect.x + buttonX(place, metrics);
        if (item.modified) {
            const dot = @floor(metrics.cell * 0.75);
            canvas.fillRect(.{ .x = button_x + (button * metrics.cell - dot) / 2, .y = text_y + (metrics.row - dot) / 2, .w = dot, .h = dot }, theme.unsaved);
        } else {
            const cross = "\u{D7}";
            canvas.drawLabel(button_x + (button * metrics.cell - metrics.labelWidth(cross)) / 2, text_y, cross, theme.line_number);
        }
    }
}

const testing = std.testing;

test "clicks find the tab and its close button" {
    const metrics = Metrics.init(1);
    const items = [_]Item{ .{ .title = "a.zig" }, .{ .title = "bb.txt", .modified = true } };
    const rect: Rect = .{ .x = 100, .w = 400, .h = 24 };
    const first = width(items[0], metrics);
    try testing.expectEqual(metrics.labelWidth("a.zig") + 5 * 8, first);
    try testing.expectEqual(Hit{ .index = 0, .close = false }, hit(rect, metrics, &items, 0, 100 + 8, 5).?);
    // The button is the two cells before the last one and a half.
    try testing.expectEqual(Hit{ .index = 0, .close = true }, hit(rect, metrics, &items, 0, 100 + first - 13, 5).?);
    try testing.expectEqual(Hit{ .index = 0, .close = false }, hit(rect, metrics, &items, 0, 100 + first - 1, 5).?);
    try testing.expectEqual(Hit{ .index = 1, .close = false }, hit(rect, metrics, &items, 0, 100 + first + 1, 5).?);
    try testing.expectEqual(@as(?Hit, null), hit(rect, metrics, &items, 0, 100 + 390, 5));
    try testing.expectEqual(@as(?Hit, null), hit(rect, metrics, &items, 0, 50, 5));
}

test "a tab without a close button is narrower" {
    const metrics = Metrics.init(1);
    const items = [_]Item{ .{ .title = "Files", .closable = false }, .{ .title = "Git", .closable = false } };
    const rect: Rect = .{ .w = 400, .h = 24 };
    const first = width(items[0], metrics);
    try testing.expectEqual(metrics.labelWidth("Files") + 3 * 8, first);
    try testing.expectEqual(Hit{ .index = 0, .close = false }, hit(rect, metrics, &items, 0, first - 1, 5).?);
    try testing.expectEqual(Hit{ .index = 1, .close = false }, hit(rect, metrics, &items, 0, first, 5).?);
}

test "too many tabs scroll so the active one is in view" {
    const metrics = Metrics.init(1);
    const items = [_]Item{ .{ .title = "one" }, .{ .title = "two" }, .{ .title = "three" }, .{ .title = "four" } };
    const room = width(items[2], metrics) + width(items[3], metrics);
    var places = Places.init(&items, metrics, 3, room);
    try testing.expectEqual(@as(usize, 2), places.next().?.index);
    try testing.expectEqual(@as(usize, 3), places.next().?.index);
    try testing.expectEqual(@as(?Place, null), places.next());

    places = Places.init(&items, metrics, 0, room);
    try testing.expectEqual(@as(usize, 0), places.next().?.index);
}
