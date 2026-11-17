//! The bottom panel with every message `notify` showed, newest last.
const std = @import("std");
const Editor = @import("../../editor/editor.zig").Editor;
const layout = @import("../layout.zig");
const Rect = layout.Rect;
const Metrics = layout.Metrics;
const Canvas = @import("../canvas.zig").Canvas;
const panel = @import("../panel.zig");
const Look = panel.Look;
const Handled = panel.Handled;
const list_zig = @import("../widgets/list.zig");
const List = list_zig.List;
const Color = @import("../theme.zig").Color;
const Event = @import("../../platform/event.zig").Event;

pub const Messages = struct {
    editor: *Editor,
    list: List = .{},
    /// Messages seen at the last draw; a new one is selected and shown.
    seen: usize = 0,

    pub fn title(_: *Messages) []const u8 {
        return "Messages";
    }

    pub fn handle(self: *Messages, event: Event, metrics: Metrics, rect: Rect) Handled {
        const count = self.editor.log.items.len;
        const rows = List.rowsIn(rect, metrics);
        if (self.list.scrollbarEvent(event, rect, metrics, count)) return .yes;
        switch (event) {
            .key => |press| _ = self.list.key(press, count, rows) orelse return .no,
            .mouse_down => |mouse| _ = self.list.click(mouse.y, rect, metrics, count, mouse.clicks),
            .wheel => |wheel| self.list.scroll(@intFromFloat(-wheel.dy), count, rows),
            else => return .no,
        }
        return .yes;
    }

    const Rows = struct {
        log: []const []u8,
        color: Color,

        pub fn row(self: Rows, index: usize) list_zig.Row {
            return .{ .text = self.log[index], .color = self.color };
        }
    };

    pub fn draw(self: *Messages, canvas: Canvas, look: Look, rect: Rect, focused: bool) void {
        const log = self.editor.log.items;
        if (log.len != self.seen) {
            self.seen = log.len;
            self.list.selected = log.len -| 1;
            self.list.reveal(List.rowsIn(rect, look.metrics));
        }
        self.list.draw(canvas, look, rect, log.len, Rows{ .log = log, .color = look.theme.text }, focused);
    }
};
