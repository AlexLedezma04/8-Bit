//! A scrollbar at the right or bottom edge of a file or a list, shown when
//! not everything fits. Dragging the thumb scrolls; a click on the track
//! moves the thumb there first.
const std = @import("std");
const Canvas = @import("../canvas.zig").Canvas;
const layout = @import("../layout.zig");
const Rect = layout.Rect;
const Metrics = layout.Metrics;
const Look = @import("../panel.zig").Look;

pub const Axis = enum { vertical, horizontal };

pub const Scrollbar = struct {
    track: Rect,
    axis: Axis = .vertical,
    /// The first row (or column) shown, and the largest it can be.
    first: usize,
    last: usize,
    /// Rows (or columns) on screen.
    shown: usize,

    /// How thick a scrollbar is.
    pub fn width(metrics: Metrics) f32 {
        return metrics.cell;
    }

    /// The strip at the right edge of `rect`.
    pub fn rightOf(rect: Rect, metrics: Metrics) Rect {
        const w = width(metrics);
        return .{ .x = rect.x + rect.w - w, .y = rect.y, .w = w, .h = rect.h };
    }

    pub fn visible(self: Scrollbar) bool {
        return self.last > 0 and self.length() > 0;
    }

    /// Where the track starts and how long it is, along the axis.
    fn start(self: Scrollbar) f32 {
        return if (self.axis == .vertical) self.track.y else self.track.x;
    }

    fn length(self: Scrollbar) f32 {
        return if (self.axis == .vertical) self.track.h else self.track.w;
    }

    fn thickness(self: Scrollbar) f32 {
        return if (self.axis == .vertical) self.track.w else self.track.h;
    }

    /// The thumb's start and length along the axis.
    fn span(self: Scrollbar) [2]f32 {
        const total: f32 = @floatFromInt(self.last + self.shown);
        const len = @min(self.length(), @max(2 * self.thickness(), self.length() * @as(f32, @floatFromInt(self.shown)) / total));
        const share = @as(f32, @floatFromInt(@min(self.first, self.last))) / @as(f32, @floatFromInt(@max(self.last, 1)));
        return .{ self.start() + @round((self.length() - len) * share), len };
    }

    pub fn thumb(self: Scrollbar) Rect {
        const at, const len = self.span();
        var rect = self.track;
        if (self.axis == .vertical) {
            rect.y = at;
            rect.h = len;
        } else {
            rect.x = at;
            rect.w = len;
        }
        return rect;
    }

    /// The mouse position along the axis.
    pub fn along(self: Scrollbar, x: f32, y: f32) f32 {
        return if (self.axis == .vertical) y else x;
    }

    /// Where a press at `at` grabs the thumb: the point under the mouse, or
    /// its middle when the press is on the track.
    pub fn grab(self: Scrollbar, at: f32) f32 {
        const thumb_at, const len = self.span();
        return if (at >= thumb_at and at < thumb_at + len) at - thumb_at else len / 2;
    }

    /// The first row that puts the grabbed point of the thumb at `at`.
    pub fn firstAt(self: Scrollbar, at: f32, grabbed: f32) usize {
        const room = self.length() - self.span()[1];
        if (room <= 0) return 0;
        const share = std.math.clamp((at - grabbed - self.start()) / room, 0, 1);
        return @intFromFloat(@round(share * @as(f32, @floatFromInt(self.last))));
    }

    pub fn draw(self: Scrollbar, canvas: Canvas, look: Look) void {
        if (!self.visible()) return;
        var t = self.thumb();
        const inset = @floor(self.thickness() / 4);
        if (self.axis == .vertical) {
            t.x += inset;
            t.w -= 2 * inset;
        } else {
            t.y += inset;
            t.h -= 2 * inset;
        }
        canvas.fillRect(t, if (look.hovered(self.track)) look.theme.line_number else look.theme.list_inactive);
    }
};

const testing = std.testing;

test "the thumb shows the part on screen and where it is" {
    const track: Rect = .{ .x = 100, .y = 0, .w = 8, .h = 400 };
    const top: Scrollbar = .{ .track = track, .first = 0, .last = 300, .shown = 100 };
    try testing.expectEqual(Rect{ .x = 100, .y = 0, .w = 8, .h = 100 }, top.thumb());
    const bottom: Scrollbar = .{ .track = track, .first = 300, .last = 300, .shown = 100 };
    try testing.expectEqual(@as(f32, 300), bottom.thumb().y);
    // A huge file still has a thumb that can be grabbed.
    const huge: Scrollbar = .{ .track = track, .first = 0, .last = 1_000_000, .shown = 40 };
    try testing.expectEqual(@as(f32, 16), huge.thumb().h);
    try testing.expect(!(Scrollbar{ .track = track, .first = 0, .last = 0, .shown = 40 }).visible());
}

test "dragging maps the thumb back to a row" {
    const bar: Scrollbar = .{ .track = .{ .w = 8, .h = 400 }, .first = 0, .last = 300, .shown = 100 };
    try testing.expectEqual(@as(f32, 30), bar.grab(30));
    try testing.expectEqual(@as(usize, 150), bar.firstAt(150 + 30, 30));
    try testing.expectEqual(@as(usize, 300), bar.firstAt(9999, 30));
    try testing.expectEqual(@as(usize, 0), bar.firstAt(-50, 30));
    // A press on the track grabs the middle, so the thumb centers there.
    try testing.expectEqual(@as(f32, 50), bar.grab(350));
    try testing.expectEqual(@as(usize, 300), bar.firstAt(350, 50));
}

test "a horizontal scrollbar works along x" {
    const bar: Scrollbar = .{ .track = .{ .x = 10, .y = 500, .w = 400, .h = 8 }, .axis = .horizontal, .first = 100, .last = 100, .shown = 300 };
    try testing.expectEqual(Rect{ .x = 10 + 100, .y = 500, .w = 300, .h = 8 }, bar.thumb());
    try testing.expectEqual(@as(f32, 410), bar.along(410, 0));
    try testing.expectEqual(@as(usize, 0), bar.firstAt(10 + 5, 5));
}
