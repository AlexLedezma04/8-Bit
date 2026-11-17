//! The editor area while nothing is open: the logo, how to open a folder
//! or a file, and the recent folders, newest first. A click or Enter opens one; its ×
//! or Delete removes it from the list.
const std = @import("std");
const Editor = @import("../../editor/editor.zig").Editor;
const fs = @import("../../platform/fs.zig");
const layout = @import("../layout.zig");
const Rect = layout.Rect;
const Metrics = layout.Metrics;
const Canvas = @import("../canvas.zig").Canvas;
const panel = @import("../panel.zig");
const Look = panel.Look;
const Handled = panel.Handled;
const list_zig = @import("../widgets/list.zig");
const List = list_zig.List;
const Theme = @import("../theme.zig").Theme;
const Event = @import("../../platform/event.zig").Event;

const Action = struct { label: []const u8, shortcut: []const u8, pick: @import("../../editor/editor.zig").Pick };

const actions = [_]Action{
    .{ .label = "Open Folder...", .shortcut = "Ctrl+Shift+O", .pick = .open_folder },
    .{ .label = "Open File...", .shortcut = "Ctrl+O", .pick = .open_file },
};

/// Where each part is, from the top of the area down: the logo with the
/// name beside it, the actions, and the recent folders.
const Parts = struct {
    logo: Rect,
    title: Rect,
    actions: [actions.len]Rect,
    heading: Rect,
    list: Rect,

    const max_cols = 72;

    fn of(rect: Rect, metrics: Metrics) Parts {
        const w = @min(rect.w - 4 * metrics.cell, max_cols * metrics.cell);
        const x = rect.x + @floor((rect.w - w) / 2);
        var parts: Parts = undefined;
        parts.logo = .{ .x = x, .y = rect.y + 2 * metrics.row, .w = 4 * metrics.row, .h = 4 * metrics.row };
        parts.title = .{ .x = x + parts.logo.w + metrics.cell, .y = metrics.center(parts.logo.y, parts.logo.h), .w = w, .h = metrics.row };
        var row: Rect = .{ .x = x, .y = parts.logo.y + parts.logo.h + metrics.row, .w = w, .h = metrics.item() };
        for (&parts.actions) |*action| {
            action.* = row;
            row.y += row.h;
        }
        row.y += metrics.row;
        parts.heading = row;
        row.y += row.h;
        parts.list = .{ .x = row.x, .y = row.y, .w = w, .h = @max(0, rect.y + rect.h - row.y - metrics.row) };
        return parts;
    }
};

pub const Welcome = struct {
    editor: *Editor,
    list: List = .{},

    pub fn title(_: *Welcome) []const u8 {
        return "Welcome";
    }

    fn count(self: *const Welcome) usize {
        return self.editor.recent.items.len;
    }

    /// A folder that is gone is removed from the list instead.
    fn openRecent(self: *Welcome, index: usize) void {
        const editor = self.editor;
        const path = editor.recent.items[index];
        if (!fs.isDir(editor.io, path)) {
            editor.notify("Folder not found: {s}", .{path});
            return editor.forgetRecent(index);
        }
        editor.openFolder(path);
    }

    pub fn handle(self: *Welcome, event: Event, metrics: Metrics, rect: Rect) Handled {
        const parts = Parts.of(rect, metrics);
        const rows = List.rowsIn(parts.list, metrics);
        switch (event) {
            .key => |press| {
                if (press.mods.ctrl or press.mods.alt) return .no;
                switch (press.key) {
                    .delete => if (self.list.selected < self.count()) self.editor.forgetRecent(self.list.selected),
                    .escape, .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => return .no,
                    // Plain keys are the welcome screen's; they do not type.
                    else => if (self.list.key(press, self.count(), rows) == .activate and self.count() > 0) self.openRecent(self.list.selected),
                }
            },
            .mouse_down => |mouse| {
                if (mouse.button != .left) return .yes;
                for (parts.actions, actions) |line, action| {
                    if (line.contains(mouse.x, mouse.y)) return .{ .request = .{ .pick = action.pick } };
                }
                if (!parts.list.contains(mouse.x, mouse.y)) return .yes;
                const index = self.list.rowAt(mouse.y, parts.list, metrics, self.count()) orelse return .yes;
                self.list.selected = index;
                const on_remove = mouse.x >= parts.list.x + parts.list.w - 3 * metrics.cell;
                if (on_remove) self.editor.forgetRecent(index) else self.openRecent(index);
            },
            .wheel => |wheel| self.list.scroll(@intFromFloat(-wheel.dy * 3), self.count(), rows),
            else => return .no,
        }
        return .yes;
    }

    const Rows = struct {
        editor: *const Editor,
        theme: *const Theme,

        pub fn row(self: Rows, index: usize) list_zig.Row {
            const path = self.editor.recent.items[index];
            return .{
                .text = std.fs.path.basename(path),
                .detail = std.fs.path.dirname(path) orelse "",
                .color = self.theme.text,
                .mark = .{ .char = 0xD7, .color = self.theme.line_number },
            };
        }
    };

    pub fn draw(self: *Welcome, canvas: Canvas, look: Look, rect: Rect, focused: bool) void {
        const theme = look.theme;
        const parts = Parts.of(rect, look.metrics);
        canvas.drawLogo(parts.logo, theme.tab_active_text);
        canvas.drawLabel(parts.title.x, parts.title.y, "8-Bit", theme.tab_active_text);
        for (parts.actions, actions) |line, action| {
            if (look.hovered(line)) canvas.fillRect(line, theme.hover);
            const y = look.metrics.center(line.y, line.h);
            canvas.drawLabel(line.x + look.metrics.cell, y, action.label, theme.accent);
            canvas.drawLabel(line.x + line.w - look.metrics.cell - look.metrics.labelWidth(action.shortcut), y, action.shortcut, theme.line_number);
        }
        canvas.drawLabel(parts.heading.x + look.metrics.cell, look.metrics.center(parts.heading.y, parts.heading.h), if (self.count() > 0) "Recent folders" else "No recent folders", theme.line_number);
        self.list.draw(canvas, look, parts.list, self.count(), Rows{ .editor = self.editor, .theme = theme }, focused);
    }
};
