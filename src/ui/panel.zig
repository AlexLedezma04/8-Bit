//! The one interface every panel follows, so the workbench can draw panels
//! and route events to them without knowing what they are.
const Canvas = @import("canvas.zig").Canvas;
const layout = @import("layout.zig");
const Rect = layout.Rect;
const Metrics = layout.Metrics;
const Theme = @import("theme.zig").Theme;
const Event = @import("../platform/event.zig").Event;
const Request = @import("../editor/editor.zig").Request;

/// What drawing needs besides the canvas.
pub const Look = struct { theme: *const Theme, metrics: Metrics };

pub const Handled = struct {
    /// False lets the workbench try the global key bindings.
    used: bool = true,
    request: ?Request = null,

    pub const no: Handled = .{ .used = false };
    pub const yes: Handled = .{};
};

pub const Panel = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        title: *const fn (*anyopaque) []const u8,
        draw: *const fn (*anyopaque, Canvas, Look, Rect, bool) void,
        handle: *const fn (*anyopaque, Event, Metrics, Rect) Handled,
    };

    /// A panel for `T`, which has `title`, `draw` and `handle` methods.
    pub fn of(comptime T: type, target: *T) Panel {
        const gen = struct {
            fn title(ptr: *anyopaque) []const u8 {
                return cast(ptr).title();
            }
            fn draw(ptr: *anyopaque, canvas: Canvas, look: Look, rect: Rect, focused: bool) void {
                cast(ptr).draw(canvas, look, rect, focused);
            }
            fn handle(ptr: *anyopaque, event: Event, metrics: Metrics, rect: Rect) Handled {
                return cast(ptr).handle(event, metrics, rect);
            }
            fn cast(ptr: *anyopaque) *T {
                return @ptrCast(@alignCast(ptr));
            }
            const table: VTable = .{ .title = @This().title, .draw = @This().draw, .handle = @This().handle };
        };
        return .{ .ptr = target, .vtable = &gen.table };
    }

    pub fn title(self: Panel) []const u8 {
        return self.vtable.title(self.ptr);
    }

    /// `focused` panels show their selection and cursor in full color.
    pub fn draw(self: Panel, canvas: Canvas, look: Look, rect: Rect, focused: bool) void {
        self.vtable.draw(self.ptr, canvas, look, rect, focused);
    }

    /// Mouse positions in `event` are window pixels.
    pub fn handle(self: Panel, event: Event, metrics: Metrics, rect: Rect) Handled {
        return self.vtable.handle(self.ptr, event, metrics, rect);
    }
};
