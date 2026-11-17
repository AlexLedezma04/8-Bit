//! A context menu at the mouse. The mouse or Up and Down pick an item, a
//! click or Enter runs it, Esc or a click outside closes the menu. The
//! panel that opens it gets the index of the chosen item.
const std = @import("std");
const Canvas = @import("../canvas.zig").Canvas;
const layout = @import("../layout.zig");
const Rect = layout.Rect;
const Metrics = layout.Metrics;
const Look = @import("../panel.zig").Look;
const event = @import("../../platform/event.zig");
const Request = @import("../../editor/editor.zig").Request;
const utf8 = @import("../../core/utf8.zig");

pub const Item = struct {
    label: []const u8,
    shortcut: []const u8 = "",
    enabled: bool = true,
};

/// Who gets the chosen item: a `T` with `choose(index) ?Request`.
pub const Target = struct {
    ptr: *anyopaque,
    choose: *const fn (*anyopaque, usize) ?Request,

    pub fn of(comptime T: type, target: *T) Target {
        const gen = struct {
            fn choose(ptr: *anyopaque, index: usize) ?Request {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.choose(index);
            }
        };
        return .{ .ptr = target, .choose = gen.choose };
    }
};

pub const Outcome = union(enum) {
    open,
    closed,
    chosen: ?Request,
};

pub const Menu = struct {
    buffer: [max_items]Item = undefined,
    len: usize = 0,
    /// Null while closed.
    target: ?Target = null,
    /// The mouse, in window pixels, where it opened.
    x: f32 = 0,
    y: f32 = 0,
    hover: ?usize = null,

    const max_items = 8;
    /// Cells of space around the labels, and between label and shortcut.
    const pad = 2;
    const gap = 4;

    pub fn open(self: *Menu, items: []const Item, x: f32, y: f32, target: Target) void {
        self.len = @min(items.len, max_items);
        @memcpy(self.buffer[0..self.len], items[0..self.len]);
        self.x = x;
        self.y = y;
        self.target = target;
        self.hover = null;
    }

    pub fn isOpen(self: *const Menu) bool {
        return self.target != null;
    }

    pub fn close(self: *Menu) void {
        self.target = null;
    }

    fn shown(self: *const Menu) []const Item {
        return self.buffer[0..self.len];
    }

    /// Where it is drawn: at the mouse, moved in to stay inside `window`.
    pub fn bounds(self: *const Menu, metrics: Metrics, window: Rect) Rect {
        var label: usize = 0;
        var shortcut: usize = 0;
        for (self.shown()) |item| {
            label = @max(label, utf8.count(item.label));
            shortcut = @max(shortcut, utf8.count(item.shortcut));
        }
        const cols = pad + label + (if (shortcut > 0) gap + shortcut else 0) + pad;
        const w = @as(f32, @floatFromInt(cols)) * metrics.cell;
        const h = @as(f32, @floatFromInt(self.len)) * metrics.row + metrics.row / 2;
        return .{
            .x = @max(window.x, @min(self.x, window.x + window.w - w)),
            .y = @max(window.y, @min(self.y, window.y + window.h - h)),
            .w = w,
            .h = h,
        };
    }

    /// The item under a pixel.
    fn itemAt(self: *const Menu, metrics: Metrics, window: Rect, x: f32, y: f32) ?usize {
        const rect = self.bounds(metrics, window);
        if (!rect.contains(x, y) or y < rect.y + metrics.row / 4) return null;
        const index: usize = @intFromFloat((y - rect.y - metrics.row / 4) / metrics.row);
        return if (index < self.len) index else null;
    }

    pub fn draw(self: *const Menu, canvas: Canvas, look: Look, window: Rect) void {
        if (!self.isOpen()) return;
        const theme = look.theme;
        const metrics = look.metrics;
        const rect = self.bounds(metrics, window);
        canvas.fillRect(.{ .x = rect.x - 1, .y = rect.y - 1, .w = rect.w + 2, .h = rect.h + 2 }, theme.border);
        canvas.fillRect(rect, theme.menu);
        var y = rect.y + metrics.row / 4;
        for (self.shown(), 0..) |item, i| {
            if (self.hover == i and item.enabled) canvas.fillRect(.{ .x = rect.x + 2, .y = y, .w = rect.w - 4, .h = metrics.row }, theme.list_selection);
            canvas.drawText(rect.x + pad * metrics.cell, y, item.label, if (item.enabled) theme.text else theme.line_number);
            const shortcut_x = rect.x + rect.w - @as(f32, @floatFromInt(pad + utf8.count(item.shortcut))) * metrics.cell;
            canvas.drawText(shortcut_x, y, item.shortcut, theme.line_number);
            y += metrics.row;
        }
    }

    /// Runs the item if it can, and closes.
    fn choose(self: *Menu, index: ?usize) Outcome {
        const found = index orelse return .open;
        if (!self.buffer[found].enabled) return .open;
        const target = self.target.?;
        self.close();
        return .{ .chosen = target.choose(target.ptr, found) };
    }

    /// Any key is the menu's while it is open.
    pub fn key(self: *Menu, press: event.KeyPress) Outcome {
        switch (press.key) {
            .escape => {
                self.close();
                return .closed;
            },
            .enter => return self.choose(self.hover),
            .up, .down => {
                const step: usize = if (press.key == .down) 1 else self.len - 1;
                var next = if (self.hover) |at| (at + step) % self.len else if (press.key == .down) 0 else self.len - 1;
                // Skips disabled items; at least one is enabled or nothing moves.
                for (0..self.len) |_| {
                    if (self.buffer[next].enabled) break;
                    next = (next + step) % self.len;
                }
                self.hover = next;
            },
            else => {},
        }
        return .open;
    }

    pub fn mouseMove(self: *Menu, metrics: Metrics, window: Rect, x: f32, y: f32) void {
        self.hover = self.itemAt(metrics, window, x, y);
    }

    /// A click on an item runs it; a click outside closes the menu.
    pub fn click(self: *Menu, metrics: Metrics, window: Rect, x: f32, y: f32) Outcome {
        if (!self.bounds(metrics, window).contains(x, y)) {
            self.close();
            return .closed;
        }
        return self.choose(self.itemAt(metrics, window, x, y));
    }
};

const testing = std.testing;

const Picker = struct {
    chosen: ?usize = null,
    fn choose(self: *Picker, index: usize) ?Request {
        self.chosen = index;
        return null;
    }
};

const screen: Rect = .{ .w = 800, .h = 600 };
const sample = [_]Item{ .{ .label = "Copy", .shortcut = "Ctrl+C", .enabled = false }, .{ .label = "Paste", .shortcut = "Ctrl+V" } };

test "the menu stays inside the window and finds items under the mouse" {
    var picker: Picker = .{};
    var menu: Menu = .{};
    const metrics = Metrics.init(1);
    menu.open(&sample, 790, 595, .of(Picker, &picker));
    // 2 + 5 + 4 + 6 + 2 cells wide, two rows and a half row high.
    const rect = menu.bounds(metrics, screen);
    try testing.expectEqual(Rect{ .x = 800 - 19 * 8, .y = 600 - 40, .w = 19 * 8, .h = 40 }, rect);
    try testing.expectEqual(@as(?usize, 1), menu.itemAt(metrics, screen, rect.x + 5, rect.y + 4 + 16));
    try testing.expectEqual(@as(?usize, null), menu.itemAt(metrics, screen, rect.x - 1, rect.y + 10));
}

test "clicks run enabled items; Esc and clicks outside close" {
    var picker: Picker = .{};
    var menu: Menu = .{};
    const metrics = Metrics.init(1);
    menu.open(&sample, 100, 100, .of(Picker, &picker));
    try testing.expectEqual(Outcome.open, menu.click(metrics, screen, 110, 104 + 2));
    try testing.expectEqual(@as(?usize, null), picker.chosen);
    try testing.expect(menu.click(metrics, screen, 110, 104 + 16 + 2) == .chosen);
    try testing.expectEqual(@as(?usize, 1), picker.chosen);
    try testing.expect(!menu.isOpen());

    menu.open(&sample, 100, 100, .of(Picker, &picker));
    try testing.expectEqual(Outcome.closed, menu.click(metrics, screen, 10, 10));
    menu.open(&sample, 100, 100, .of(Picker, &picker));
    try testing.expectEqual(Outcome.closed, menu.key(.{ .key = .escape }));
}

test "Up and Down skip disabled items; Enter runs the one picked" {
    var picker: Picker = .{};
    var menu: Menu = .{};
    menu.open(&sample, 0, 0, .of(Picker, &picker));
    _ = menu.key(.{ .key = .down });
    try testing.expectEqual(@as(?usize, 1), menu.hover);
    _ = menu.key(.{ .key = .up });
    try testing.expectEqual(@as(?usize, 1), menu.hover);
    try testing.expect(menu.key(.{ .key = .enter }) == .chosen);
    try testing.expectEqual(@as(?usize, 1), picker.chosen);
}
