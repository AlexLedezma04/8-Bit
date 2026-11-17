//! A bar of tabs. Each tab has a title and, after it, a close button, or a
//! dot while it has unsaved changes. File tabs are as wide as their title
//! and scroll so the active one is in view; dock tabs share the whole bar.
//! Used by editor panes, the dock bars, the pages of the git panel and the
//! terminal.
const std = @import("std");
const Canvas = @import("../canvas.zig").Canvas;
const layout = @import("../layout.zig");
const Rect = layout.Rect;
const Metrics = layout.Metrics;
const Look = @import("../panel.zig").Look;

pub const Item = struct {
    title: []const u8,
    modified: bool = false,
    /// A preview, drawn dimmer until it is kept.
    preview: bool = false,
    /// Has a close button.
    closable: bool = true,
};

pub const Hit = struct { index: usize, close: bool };

pub const Style = enum {
    /// As wide as the title; the active one has the panel color.
    files,
    /// Like `files`, with less space, in a bar one list row high.
    compact,
    /// The bar shared out; the active one is underlined.
    dock,
};

/// Cells of space at each end of a tab, and of its close button.
fn padOf(style: Style) f32 {
    return if (style == .compact) 0.75 else 1.5;
}
const button = 2;

fn width(item: Item, metrics: Metrics, style: Style) f32 {
    const pad = padOf(style);
    const extra: f32 = if (item.closable) 2 * pad + button else 2 * pad;
    return metrics.labelWidth(item.title) + extra * metrics.cell;
}

/// Height of a bar of tabs in this style.
pub fn height(metrics: Metrics, style: Style) f32 {
    return if (style == .compact) metrics.item() else metrics.bar();
}

/// One tab and the pixels it takes from the left of the bar.
const Place = struct { index: usize, x: f32, w: f32 };

/// Walks the tabs that are drawn, from the first one that keeps `active`
/// in view.
const Places = struct {
    items: []const Item,
    metrics: Metrics,
    style: Style,
    index: usize,
    x: f32 = 0,
    width: f32,

    fn init(items: []const Item, metrics: Metrics, style: Style, active: usize, w: f32) Places {
        if (style == .dock) return .{ .items = items, .metrics = metrics, .style = style, .index = 0, .width = w };
        var first = @min(active, items.len -| 1);
        var used: f32 = if (items.len > 0) width(items[first], metrics, style) else 0;
        while (first > 0 and used + width(items[first - 1], metrics, style) <= w) {
            first -= 1;
            used += width(items[first], metrics, style);
        }
        return .{ .items = items, .metrics = metrics, .style = style, .index = first, .width = w };
    }

    fn widthOf(self: *const Places, item: Item) f32 {
        return switch (self.style) {
            .files, .compact => width(item, self.metrics, self.style),
            .dock => @floor(self.width / @as(f32, @floatFromInt(self.items.len))),
        };
    }

    fn next(self: *Places) ?Place {
        if (self.index >= self.items.len or self.x >= self.width) return null;
        const place: Place = .{ .index = self.index, .x = self.x, .w = self.widthOf(self.items[self.index]) };
        self.index += 1;
        self.x += place.w;
        return place;
    }
};

/// Pixels from the left of the bar to the end of the last tab drawn.
pub fn end(rect: Rect, metrics: Metrics, style: Style, items: []const Item, active: usize) f32 {
    var places = Places.init(items, metrics, style, active, rect.w);
    var x: f32 = 0;
    while (places.next()) |place| x = place.x + place.w;
    return @min(x, rect.w);
}

/// Where the close button of a tab is.
fn buttonX(place: Place, metrics: Metrics, style: Style) f32 {
    return place.x + place.w - (padOf(style) + button) * metrics.cell;
}

/// The tab, and whether its close button, under a pixel.
pub fn hit(rect: Rect, metrics: Metrics, style: Style, items: []const Item, active: usize, x: f32, y: f32) ?Hit {
    if (!rect.contains(x, y)) return null;
    const at = x - rect.x;
    var places = Places.init(items, metrics, style, active, rect.w);
    while (places.next()) |place| {
        if (at >= place.x + place.w) continue;
        const start = buttonX(place, metrics, style);
        return .{ .index = place.index, .close = items[place.index].closable and at >= start and at < start + button * metrics.cell };
    }
    return null;
}

/// A dock's active tab is underlined, in the accent color when `focused`.
pub fn draw(canvas: Canvas, look: Look, rect: Rect, style: Style, items: []const Item, active: usize, focused: bool) void {
    const theme = look.theme;
    const metrics = look.metrics;
    canvas.fillRect(rect, if (style == .dock) theme.panel else theme.background);
    canvas.fillRect(.{ .x = rect.x, .y = rect.y + rect.h - 1, .w = rect.w, .h = 1 }, theme.border);
    canvas.setClip(rect);
    defer canvas.setClip(null);
    const text_y = metrics.center(rect.y, rect.h);
    var places = Places.init(items, metrics, style, active, rect.w);
    while (places.next()) |place| {
        const item = items[place.index];
        const x = rect.x + place.x;
        const is_active = place.index == active;
        const tab: Rect = .{ .x = x, .y = rect.y, .w = place.w, .h = rect.h - 1 };
        if (is_active and style != .dock) canvas.fillRect(tab, theme.panel) else if (look.hovered(tab)) canvas.fillRect(tab, theme.hover);
        if (is_active and style == .dock) {
            const line = @floor(metrics.cell / 4);
            canvas.fillRect(.{ .x = x, .y = rect.y + rect.h - line, .w = place.w, .h = line }, if (focused) theme.accent else theme.list_inactive);
        }
        const title_x = if (style == .dock) x + @floor((place.w - metrics.labelWidth(item.title)) / 2) else x + padOf(style) * metrics.cell;
        const color = if (item.preview) theme.line_number_current else if (is_active) theme.tab_active_text else theme.tab_text;
        canvas.drawLabel(title_x, text_y, item.title, color);
        if (!item.closable) continue;
        const button_x = rect.x + buttonX(place, metrics, style);
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
    const first = width(items[0], metrics, .files);
    try testing.expectEqual(metrics.labelWidth("a.zig") + 5 * 8, first);
    try testing.expectEqual(Hit{ .index = 0, .close = false }, hit(rect, metrics, .files, &items, 0, 100 + 8, 5).?);
    // The button is the two cells before the last one and a half.
    try testing.expectEqual(Hit{ .index = 0, .close = true }, hit(rect, metrics, .files, &items, 0, 100 + first - 13, 5).?);
    try testing.expectEqual(Hit{ .index = 0, .close = false }, hit(rect, metrics, .files, &items, 0, 100 + first - 1, 5).?);
    try testing.expectEqual(Hit{ .index = 1, .close = false }, hit(rect, metrics, .files, &items, 0, 100 + first + 1, 5).?);
    try testing.expectEqual(@as(?Hit, null), hit(rect, metrics, .files, &items, 0, 100 + 390, 5));
    try testing.expectEqual(@as(?Hit, null), hit(rect, metrics, .files, &items, 0, 50, 5));
}

test "dock tabs share the whole bar" {
    const metrics = Metrics.init(1);
    const items = [_]Item{ .{ .title = "Files", .closable = false }, .{ .title = "Git", .closable = false } };
    const rect: Rect = .{ .w = 240, .h = 40 };
    try testing.expectEqual(Hit{ .index = 0, .close = false }, hit(rect, metrics, .dock, &items, 0, 119, 5).?);
    try testing.expectEqual(Hit{ .index = 1, .close = false }, hit(rect, metrics, .dock, &items, 0, 120, 5).?);
    try testing.expectEqual(Hit{ .index = 1, .close = false }, hit(rect, metrics, .dock, &items, 0, 239, 5).?);
}

test "compact tabs are lower and narrower" {
    const metrics = Metrics.init(1);
    const item: Item = .{ .title = "Terminal 1" };
    try testing.expectEqual(@as(f32, 24), height(metrics, .compact));
    try testing.expectEqual(@as(f32, 40), height(metrics, .files));
    try testing.expectEqual(width(item, metrics, .files) - 12, width(item, metrics, .compact));
}

test "too many tabs scroll so the active one is in view" {
    const metrics = Metrics.init(1);
    const items = [_]Item{ .{ .title = "one" }, .{ .title = "two" }, .{ .title = "three" }, .{ .title = "four" } };
    const room = width(items[2], metrics, .files) + width(items[3], metrics, .files);
    var places = Places.init(&items, metrics, .files, 3, room);
    try testing.expectEqual(@as(usize, 2), places.next().?.index);
    try testing.expectEqual(@as(usize, 3), places.next().?.index);
    try testing.expectEqual(@as(?Place, null), places.next());

    places = Places.init(&items, metrics, .files, 0, room);
    try testing.expectEqual(@as(usize, 0), places.next().?.index);
}
