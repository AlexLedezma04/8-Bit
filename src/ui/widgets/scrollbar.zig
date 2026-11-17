//! A vertical scrollbar at the right edge of a file or a list, shown when
//! not everything fits. Dragging the thumb scrolls; a click on the track
//! moves the thumb there first.
const std = @import("std");
const Canvas = @import("../canvas.zig").Canvas;
const layout = @import("../layout.zig");
const Rect = layout.Rect;
const Metrics = layout.Metrics;
const Look = @import("../panel.zig").Look;

pub const Scrollbar = struct {
    track: Rect,
    /// The first row shown, and the largest it can be.
    first: usize,
    last: usize,
    /// Rows on screen.
    shown: usize,

    pub fn width(metrics: Metrics) f32 {
        return metrics.cell;
    }

    /// The strip at the right edge of `rect`.
    pub fn trackOf(rect: Rect, metrics: Metrics) Rect {
        const w = width(metrics);
        return .{ .x = rect.x + rect.w - w, .y = rect.y, .w = w, .h = rect.h };
    }

    pub fn visible(self: Scrollbar) bool {
        return self.last > 0 and self.track.h > 0;
    }

    pub fn thumb(self: Scrollbar) Rect {
        const total: f32 = @floatFromInt(self.last + self.shown);
        const h = @min(self.track.h, @max(2 * self.track.w, self.track.h * @as(f32, @floatFromInt(self.shown)) / total));
        const share = @as(f32, @floatFromInt(@min(self.first, self.last))) / @as(f32, @floatFromInt(@max(self.last, 1)));
        return .{ .x = self.track.x, .y = self.track.y + @round((self.track.h - h) * share), .w = self.track.w, .h = h };
    }

    /// Where a press grabs the thumb: the point under the mouse, or its
    /// middle when the press is on the track.
    pub fn grab(self: Scrollbar, y: f32) f32 {
        const t = self.thumb();
        return if (y >= t.y and y < t.y + t.h) y - t.y else t.h / 2;
    }

    /// The first row that puts the grabbed point of the thumb at `y`.
    pub fn firstAt(self: Scrollbar, y: f32, grabbed: f32) usize {
        const t = self.thumb();
        const room = self.track.h - t.h;
        if (room <= 0) return 0;
        const share = std.math.clamp((y - grabbed - self.track.y) / room, 0, 1);
        return @intFromFloat(@round(share * @as(f32, @floatFromInt(self.last))));
    }

    pub fn draw(self: Scrollbar, canvas: Canvas, look: Look) void {
        if (!self.visible()) return;
        const t = self.thumb();
        const inset = @floor(t.w / 4);
        const color = if (look.hovered(self.track)) look.theme.line_number else look.theme.list_inactive;
        canvas.fillRect(.{ .x = t.x + inset, .y = t.y, .w = t.w - 2 * inset, .h = t.h }, color);
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
