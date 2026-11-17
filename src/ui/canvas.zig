//! What panels and widgets draw on. `platform/renderer.zig` implements it;
//! tests use `Recorder`, which remembers what was drawn.
const std = @import("std");
const Rect = @import("layout.zig").Rect;
const Color = @import("theme.zig").Color;
pub const Font = @import("../font/fonts.zig").Kind;

pub const Canvas = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        fillRect: *const fn (*anyopaque, Rect, Color) void,
        drawText: *const fn (*anyopaque, f32, f32, []const u8, Color, Font) void,
        setClip: *const fn (*anyopaque, ?Rect) void,
        drawLogo: *const fn (*anyopaque, Rect, Color) void,
    };

    /// A canvas for `T`, which has these methods.
    pub fn of(comptime T: type, target: *T) Canvas {
        const gen = struct {
            fn fillRect(ptr: *anyopaque, rect: Rect, color: Color) void {
                cast(ptr).fillRect(rect, color);
            }
            fn drawText(ptr: *anyopaque, x: f32, y: f32, text: []const u8, color: Color, font: Font) void {
                cast(ptr).drawText(x, y, text, color, font);
            }
            fn setClip(ptr: *anyopaque, rect: ?Rect) void {
                cast(ptr).setClip(rect);
            }
            fn drawLogo(ptr: *anyopaque, rect: Rect, color: Color) void {
                cast(ptr).drawLogo(rect, color);
            }
            fn cast(ptr: *anyopaque) *T {
                return @ptrCast(@alignCast(ptr));
            }
            const table: VTable = .{ .fillRect = @This().fillRect, .drawText = @This().drawText, .setClip = @This().setClip, .drawLogo = @This().drawLogo };
        };
        return .{ .ptr = target, .vtable = &gen.table };
    }

    pub fn fillRect(self: Canvas, rect: Rect, color: Color) void {
        self.vtable.fillRect(self.ptr, rect, color);
    }

    /// One line of code text with its top-left corner at `x`, `y`.
    pub fn drawText(self: Canvas, x: f32, y: f32, text: []const u8, color: Color) void {
        self.vtable.drawText(self.ptr, x, y, text, color, .code);
    }

    /// One line in the UI font; `Metrics.labelWidth` measures it.
    pub fn drawLabel(self: Canvas, x: f32, y: f32, text: []const u8, color: Color) void {
        self.vtable.drawText(self.ptr, x, y, text, color, .ui);
    }

    /// The app logo scaled into `rect`, tinted with `color`.
    pub fn drawLogo(self: Canvas, rect: Rect, color: Color) void {
        self.vtable.drawLogo(self.ptr, rect, color);
    }

    /// Drawing outside `rect` is dropped; null draws everywhere again.
    pub fn setClip(self: Canvas, rect: ?Rect) void {
        self.vtable.setClip(self.ptr, rect);
    }
};

/// Keeps every text drawn, for tests.
pub const Recorder = struct {
    allocator: std.mem.Allocator,
    texts: std.ArrayList(Text) = .empty,
    fills: usize = 0,
    logos: usize = 0,

    pub const Text = struct { x: f32, y: f32, text: []u8, color: Color, font: Font };

    pub fn deinit(self: *Recorder) void {
        self.clear();
        self.texts.deinit(self.allocator);
    }

    pub fn clear(self: *Recorder) void {
        for (self.texts.items) |item| self.allocator.free(item.text);
        self.texts.clearRetainingCapacity();
        self.fills = 0;
        self.logos = 0;
    }

    pub fn canvas(self: *Recorder) Canvas {
        return .of(Recorder, self);
    }

    /// The first text drawn that contains `part`.
    pub fn find(self: *const Recorder, part: []const u8) ?Text {
        for (self.texts.items) |item| if (std.mem.indexOf(u8, item.text, part) != null) return item;
        return null;
    }

    pub fn fillRect(self: *Recorder, _: Rect, _: Color) void {
        self.fills += 1;
    }

    pub fn drawText(self: *Recorder, x: f32, y: f32, text: []const u8, color: Color, font: Font) void {
        const copy = self.allocator.dupe(u8, text) catch return;
        self.texts.append(self.allocator, .{ .x = x, .y = y, .text = copy, .color = color, .font = font }) catch self.allocator.free(copy);
    }

    pub fn setClip(_: *Recorder, _: ?Rect) void {}

    pub fn drawLogo(self: *Recorder, _: Rect, _: Color) void {
        self.logos += 1;
    }
};

test "a recorder keeps the text drawn on it" {
    var recorder: Recorder = .{ .allocator = std.testing.allocator };
    defer recorder.deinit();
    const canvas = recorder.canvas();
    canvas.fillRect(.{}, .rgb(0));
    canvas.drawText(3, 4, "hello", .rgb(0xffffff));
    canvas.drawLabel(5, 6, "label", .rgb(0xffffff));
    try std.testing.expectEqual(@as(usize, 1), recorder.fills);
    try std.testing.expectEqual(@as(f32, 3), recorder.find("ell").?.x);
    try std.testing.expectEqual(Font.code, recorder.find("ell").?.font);
    try std.testing.expectEqual(Font.ui, recorder.find("abe").?.font);
    try std.testing.expectEqual(@as(?Recorder.Text, null), recorder.find("bye"));
}
