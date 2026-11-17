//! The editor area while no file is open, centered: the logo and what to do
//! next. Without a folder it is the welcome screen, with the recent folders
//! newest first; a click or Enter opens one, its × or Delete removes it.
const std = @import("std");
const Editor = @import("../../editor/editor.zig").Editor;
const commands = @import("../../editor/commands.zig");
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

const Action = struct { label: []const u8, shortcut: []const u8, command: commands.Command };

const welcome_actions = [_]Action{
    .{ .label = "Open Folder...", .shortcut = "Ctrl+Shift+O", .command = .open_folder },
    .{ .label = "Open File...", .shortcut = "Ctrl+O", .command = .open },
};

const folder_actions = [_]Action{
    .{ .label = "New File", .shortcut = "Ctrl+N", .command = .new_file },
    .{ .label = "Open File...", .shortcut = "Ctrl+O", .command = .open },
    .{ .label = "Find in Folder", .shortcut = "Ctrl+Shift+F", .command = .find_in_project },
    .{ .label = "Close Folder", .shortcut = "Ctrl+Shift+W", .command = .close_folder },
};

const max_actions = @max(welcome_actions.len, folder_actions.len);

/// Where each part is: the logo, the actions and the recent folders, as
/// one block in the middle of the area.
const Parts = struct {
    logo: Rect,
    actions: [max_actions]Rect,
    heading: Rect,
    list: Rect,

    const max_cols = 60;
    const logo_rows = 5;
    const max_recent_rows = 8;

    fn of(rect: Rect, metrics: Metrics, actions: usize, recent: usize) Parts {
        const w = @min(rect.w - 4 * metrics.cell, max_cols * metrics.cell);
        const logo = logo_rows * metrics.row;
        const list_h = @as(f32, @floatFromInt(@min(recent, max_recent_rows))) * metrics.item();
        const recent_h = if (recent > 0) metrics.row + metrics.item() + list_h else 0;
        const total = logo + metrics.row + @as(f32, @floatFromInt(actions)) * metrics.item() + recent_h;
        const x = rect.x + @floor((rect.w - w) / 2);
        var y = rect.y + @max(0, @floor((rect.h - total) / 2));

        var parts: Parts = undefined;
        parts.logo = .{ .x = x + @floor((w - logo) / 2), .y = y, .w = logo, .h = logo };
        y += logo + metrics.row;
        for (&parts.actions, 0..) |*action, i| {
            action.* = .{ .x = x, .y = y, .w = w, .h = metrics.item() };
            if (i < actions) y += metrics.item();
        }
        y += metrics.row;
        parts.heading = .{ .x = x, .y = y, .w = w, .h = metrics.item() };
        parts.list = .{ .x = x, .y = y + metrics.item(), .w = w, .h = list_h };
        return parts;
    }
};

pub const Welcome = struct {
    editor: *Editor,
    list: List = .{},

    pub fn title(_: *Welcome) []const u8 {
        return "Welcome";
    }

    fn actions(self: *const Welcome) []const Action {
        return if (self.editor.folder == null) &welcome_actions else &folder_actions;
    }

    /// Recent folders show only on the welcome screen.
    fn count(self: *const Welcome) usize {
        return if (self.editor.folder == null) self.editor.recent.items.len else 0;
    }

    fn parts(self: *const Welcome, rect: Rect, metrics: Metrics) Parts {
        return .of(rect, metrics, self.actions().len, self.count());
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
        const at = self.parts(rect, metrics);
        const rows = List.rowsIn(at.list, metrics);
        if (self.list.scrollbarEvent(event, at.list, metrics, self.count())) return .yes;
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
                for (at.actions[0..self.actions().len], self.actions()) |line, action| {
                    if (line.contains(mouse.x, mouse.y)) return .{ .request = commands.run(self.editor, action.command) };
                }
                if (!at.list.contains(mouse.x, mouse.y)) return .yes;
                const index = self.list.rowAt(mouse.y, at.list, metrics, self.count()) orelse return .yes;
                self.list.selected = index;
                const on_remove = mouse.x >= at.list.x + at.list.w - 3 * metrics.cell;
                if (on_remove) self.editor.forgetRecent(index) else self.openRecent(index);
            },
            .wheel => |wheel| self.list.scroll(@intFromFloat(-wheel.dy), self.count(), rows),
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
        const metrics = look.metrics;
        const at = self.parts(rect, metrics);
        canvas.drawLogo(at.logo, theme.line_number_current);
        for (at.actions[0..self.actions().len], self.actions()) |line, action| {
            if (look.hovered(line)) canvas.fillRect(line, theme.hover);
            const y = metrics.center(line.y, line.h);
            canvas.drawLabel(line.x + metrics.cell, y, action.label, theme.accent);
            canvas.drawLabel(line.x + line.w - metrics.cell - metrics.labelWidth(action.shortcut), y, action.shortcut, theme.line_number);
        }
        if (self.count() == 0) return;
        canvas.drawLabel(at.heading.x + metrics.cell, metrics.center(at.heading.y, at.heading.h), "Recent folders", theme.line_number);
        self.list.draw(canvas, look, at.list, self.count(), Rows{ .editor = self.editor, .theme = theme }, focused);
    }
};
