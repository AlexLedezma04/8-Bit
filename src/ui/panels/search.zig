//! The bottom panel with the hits of find in project, filled while the
//! search runs. Enter or a double click opens the place; Esc stops a search.
const std = @import("std");
const Editor = @import("../../editor/editor.zig").Editor;
const Hit = @import("../../editor/project_search.zig").Hit;
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

pub const Search = struct {
    editor: *Editor,
    list: List = .{},
    /// The search the list shows; a new one starts at the top.
    id: u32 = 0,

    pub fn title(_: *Search) []const u8 {
        return "Search";
    }

    /// The summary takes the first row; the hits are below it.
    fn hitsRect(rect: Rect, metrics: Metrics) Rect {
        return rect.splitTop(metrics.row)[1];
    }

    fn sync(self: *Search) void {
        if (self.id == self.editor.project.id) return;
        self.id = self.editor.project.id;
        self.list = .{};
    }

    pub fn handle(self: *Search, event: Event, metrics: Metrics, rect: Rect) Handled {
        self.sync();
        const project = &self.editor.project;
        const hits = project.hits.items;
        const area = hitsRect(rect, metrics);
        const rows = List.rowsIn(area, metrics);
        const action = switch (event) {
            .key => |press| blk: {
                if (press.key == .escape and project.running) {
                    project.stop();
                    return .yes;
                }
                break :blk self.list.key(press, hits.len, rows) orelse return .no;
            },
            .mouse_down => |mouse| self.list.click(mouse.y, area, metrics, hits.len, mouse.clicks),
            .wheel => |wheel| blk: {
                self.list.scroll(@intFromFloat(-wheel.dy * 3), hits.len, rows);
                break :blk null;
            },
            else => return .no,
        };
        if (action == .activate and hits.len > 0) self.editor.openHit(hits[self.list.selected]);
        return .yes;
    }

    const Rows = struct {
        hits: []const Hit,
        color: Color,

        pub fn row(self: Rows, index: usize) list_zig.Row {
            return .{ .text = self.hits[index].text, .color = self.color };
        }
    };

    pub fn draw(self: *Search, canvas: Canvas, look: Look, rect: Rect, focused: bool) void {
        self.sync();
        const project = &self.editor.project;
        var buffer: [128]u8 = undefined;
        canvas.drawText(rect.x + look.metrics.cell, rect.y, project.summary(&buffer), look.theme.line_number_current);
        const hits = project.hits.items;
        self.list.draw(canvas, look, hitsRect(rect, look.metrics), hits.len, Rows{ .hits = hits, .color = look.theme.text }, focused);
    }
};
