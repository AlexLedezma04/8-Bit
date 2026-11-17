//! The terminal panel of the bottom dock: a tab per terminal, and the screen
//! of the one shown, drawn with `drawText` like the editor. Keys go to the
//! shell except the few that work everywhere. Drag selects, Ctrl+Shift+C
//! copies, Ctrl+Shift+V pastes, the wheel scrolls back, Ctrl+Tab switches.
const std = @import("std");
const editor_zig = @import("../../editor/editor.zig");
const Editor = editor_zig.Editor;
const Request = editor_zig.Request;
const Terminal = @import("../../editor/terminals.zig").Terminal;
const Command = @import("../../editor/commands.zig").Command;
const keymap = @import("../../editor/keymap.zig");
const grid_zig = @import("../../terminal/grid.zig");
const Grid = grid_zig.Grid;
const Cell = grid_zig.Cell;
const layout = @import("../layout.zig");
const Rect = layout.Rect;
const Metrics = layout.Metrics;
const Canvas = @import("../canvas.zig").Canvas;
const panel = @import("../panel.zig");
const Look = panel.Look;
const Handled = panel.Handled;
const tabs = @import("../widgets/tabs.zig");
const List = @import("../widgets/list.zig").List;
const theme_zig = @import("../theme.zig");
const Theme = theme_zig.Theme;
const Color = theme_zig.Color;
const event = @import("../../platform/event.zig");
const Event = event.Event;

/// A cell of the lines that can be shown: scrollback, then screen.
const Point = struct { line: usize, col: usize };

pub const TerminalPanel = struct {
    editor: *Editor,
    items: std.ArrayList(tabs.Item) = .empty,
    /// The terminal that the scroll and the selection belong to.
    shown_id: u32 = 0,
    /// Rows scrolled back from the bottom.
    offset: usize = 0,
    /// Where a drag started and where it is.
    anchor: ?Point = null,
    head: Point = .{ .line = 0, .col = 0 },
    selecting: bool = false,

    pub fn deinit(self: *TerminalPanel) void {
        self.items.deinit(self.editor.allocator);
    }

    pub fn title(_: *TerminalPanel) []const u8 {
        return "Terminal";
    }

    /// The terminal shown. Another one than before starts at the bottom,
    /// with nothing selected.
    fn current(self: *TerminalPanel) ?*Terminal {
        const shown = self.editor.terminals.current() orelse return null;
        if (shown.id != self.shown_id) {
            self.shown_id = shown.id;
            self.typed();
            self.selecting = false;
        }
        return shown;
    }

    /// The tab bar, and the screen below it.
    fn split(rect: Rect, metrics: Metrics) [2]Rect {
        return rect.splitTop(tabs.height(metrics, .compact));
    }

    fn tabItems(self: *TerminalPanel) []const tabs.Item {
        self.items.clearRetainingCapacity();
        for (self.editor.terminals.list.items) |item| {
            self.items.append(self.editor.allocator, .{ .title = item.name() }) catch break;
        }
        return self.items.items;
    }

    /// Keys that keep their command while a terminal has focus.
    fn passes(command: Command) bool {
        return switch (command) {
            .toggle_terminal, .new_terminal, .focus_sidebar, .show_files, .show_git, .next_pane, .prev_pane, .zoom_in, .zoom_out, .zoom_reset, .quit => true,
            else => false,
        };
    }

    pub fn handle(self: *TerminalPanel, ev: Event, metrics: Metrics, rect: Rect) Handled {
        const bar, const area = split(rect, metrics);
        const shown = self.current() orelse return .no;
        const session = &shown.session;
        switch (ev) {
            .key => |press| {
                const mods = press.mods;
                if (mods.ctrl and mods.shift and !mods.alt) switch (press.key) {
                    .char('c') => return .{ .request = self.copy(&session.grid) },
                    .char('v') => return .{ .request = .paste },
                    else => {},
                };
                if (keymap.lookup(self.editor.bindings, press.key, mods)) |command| switch (command) {
                    .next_tab, .prev_tab => {
                        self.editor.terminals.cycle(if (command == .next_tab) 1 else -1);
                        return .yes;
                    },
                    else => if (passes(command)) return .no,
                };
                if (session.ended) {
                    if (press.key == .enter) self.editor.closeTerminal(self.editor.terminals.active);
                    return .yes;
                }
                // A key that types text comes back as text.
                if (!session.key(press)) return .no;
                self.typed();
            },
            .text => |text| if (!session.ended) {
                session.typeText(text);
                self.typed();
            },
            .mouse_down => |mouse| {
                if (tabs.hit(bar, metrics, .compact, self.tabItems(), self.editor.terminals.active, mouse.x, mouse.y)) |hit| {
                    if (hit.close) self.editor.closeTerminal(hit.index) else self.editor.terminals.active = hit.index;
                    return .yes;
                }
                if (mouse.button != .left) return .yes;
                self.anchor = self.pointAt(&session.grid, area, metrics, mouse.x, mouse.y);
                self.head = self.anchor.?;
                self.selecting = true;
            },
            .mouse_move => |mouse| {
                if (!self.selecting or !mouse.left_down) return .no;
                self.head = self.pointAt(&session.grid, area, metrics, mouse.x, mouse.y);
            },
            .mouse_up => {
                self.selecting = false;
                if (self.anchor) |anchor| if (std.meta.eql(anchor, self.head)) {
                    self.anchor = null;
                };
            },
            .wheel => |wheel| {
                const rows: isize = @intFromFloat(wheel.dy);
                const offset = @as(isize, @intCast(self.offset)) + rows;
                self.offset = @intCast(std.math.clamp(offset, 0, @as(isize, @intCast(session.grid.scrollbackCount()))));
            },
            else => return .no,
        }
        return .yes;
    }

    /// Typing shows the bottom again and ends a selection.
    fn typed(self: *TerminalPanel) void {
        self.offset = 0;
        self.anchor = null;
    }

    /// Text arrives after a `paste` request.
    pub fn paste(self: *TerminalPanel, text: []const u8) void {
        const shown = self.current() orelse return;
        if (shown.session.ended) return;
        shown.session.paste(text);
        self.typed();
    }

    /// The first line drawn at the top of the screen.
    fn firstLine(self: *const TerminalPanel, grid: *const Grid) usize {
        return grid.lineCount() - grid.rows - @min(self.offset, grid.scrollbackCount());
    }

    fn pointAt(self: *const TerminalPanel, grid: *const Grid, area: Rect, metrics: Metrics, x: f32, y: f32) Point {
        const col: usize = @intFromFloat(@max(0, x - area.x) / metrics.cell);
        const row: usize = @intFromFloat(@max(0, y - area.y) / metrics.row);
        return .{
            .line = @min(self.firstLine(grid) + row, grid.lineCount() - 1),
            .col = @min(col, grid.cols),
        };
    }

    /// The selection from its first cell up to, not including, its end.
    fn selection(self: *const TerminalPanel) ?[2]Point {
        const anchor = self.anchor orelse return null;
        const before = anchor.line < self.head.line or (anchor.line == self.head.line and anchor.col <= self.head.col);
        return if (before) .{ anchor, self.head } else .{ self.head, anchor };
    }

    fn selected(range: [2]Point, line: usize, col: usize) bool {
        const after_start = line > range[0].line or (line == range[0].line and col >= range[0].col);
        const before_end = line < range[1].line or (line == range[1].line and col < range[1].col);
        return after_start and before_end;
    }

    /// The selected text, one line per row, for the clipboard.
    fn copy(self: *TerminalPanel, grid: *const Grid) ?Request {
        const range = self.selection() orelse return null;
        const allocator = self.editor.allocator;
        const text = &self.editor.clipboard;
        text.clearRetainingCapacity();
        for (range[0].line..range[1].line + 1) |index| {
            const cells = grid.line(index);
            const first = if (index == range[0].line) @min(range[0].col, cells.len) else 0;
            const end = if (index == range[1].line) @min(range[1].col, cells.len) else cells.len;
            const start = text.items.len;
            for (cells[first..@max(first, end)]) |cell| {
                var buffer: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cell.char, &buffer) catch 1;
                text.appendSlice(allocator, buffer[0..len]) catch return null;
            }
            text.shrinkRetainingCapacity(start + std.mem.trimEnd(u8, text.items[start..], " ").len);
            if (index != range[1].line) text.append(allocator, '\n') catch return null;
        }
        text.append(allocator, 0) catch return null;
        return .{ .copy = text.items[0 .. text.items.len - 1 :0] };
    }

    pub fn draw(self: *TerminalPanel, canvas: Canvas, look: Look, rect: Rect, focused: bool) void {
        const metrics = look.metrics;
        const bar, const area = split(rect, metrics);
        const shown = self.current() orelse {
            canvas.drawLabel(rect.x + metrics.cell, rect.y + metrics.row / 2, "No terminal: Ctrl+` starts one", look.theme.line_number);
            return;
        };
        tabs.draw(canvas, look, bar, .compact, self.tabItems(), self.editor.terminals.active, focused);
        const session = &shown.session;
        const cols: u16 = @intCast(std.math.clamp(metrics.cols(area.w), 2, 1000));
        const rows: u16 = @intCast(std.math.clamp(List.rowsIn(area, metrics), 2, 1000));
        session.resize(cols, rows);
        const grid = &session.grid;
        const first = self.firstLine(grid);
        const painter: Painter = .{ .canvas = canvas, .look = look, .area = area, .selection = self.selection() };
        for (0..grid.rows) |row| painter.line(grid.line(first + row), first + row, row);
        const bottom = first + grid.rows == grid.lineCount();
        if (focused and bottom and grid.cursor_visible) painter.cursor(grid);
    }
};

/// Draws the cells of a screen.
const Painter = struct {
    canvas: Canvas,
    look: Look,
    area: Rect,
    selection: ?[2]Point,

    fn cellRect(self: Painter, col: usize, row: usize, cols: usize) Rect {
        const metrics = self.look.metrics;
        return .{
            .x = self.area.x + @as(f32, @floatFromInt(col)) * metrics.cell,
            .y = self.area.y + @as(f32, @floatFromInt(row)) * metrics.row,
            .w = @as(f32, @floatFromInt(cols)) * metrics.cell,
            .h = metrics.row,
        };
    }

    const Colors = struct { fg: Color, bg: Color, underline: bool };

    fn colorsOf(self: Painter, cell: Cell, chosen: bool) Colors {
        const theme = self.look.theme;
        const style = cell.style;
        var fg = self.color(style.fg, theme.text, style.bold);
        var bg = self.color(style.bg, theme.background, false);
        if (style.inverse) std.mem.swap(Color, &fg, &bg);
        if (chosen) bg = theme.selection;
        return .{ .fg = fg, .bg = bg, .underline = style.underline };
    }

    /// Bold makes the first 8 colors bright, as most terminals do.
    fn color(self: Painter, value: grid_zig.Color, default: Color, bold: bool) Color {
        const ansi = &self.look.theme.terminal;
        return switch (value.kind) {
            .default => default,
            .rgb => .rgb(value.value),
            .index => switch (value.value) {
                0...7 => ansi.get(@intCast(value.value + @as(u24, if (bold) 8 else 0))),
                8...15 => ansi.get(@intCast(value.value)),
                // The 6x6x6 color cube, then 24 grays.
                16...231 => blk: {
                    const n = value.value - 16;
                    break :blk .{ .r = cube(n / 36), .g = cube(n / 6 % 6), .b = cube(n % 6) };
                },
                else => blk: {
                    const gray: u8 = @intCast(8 + (value.value - 232) * 10);
                    break :blk .{ .r = gray, .g = gray, .b = gray };
                },
            },
        };
    }

    fn cube(step: u24) u8 {
        return if (step == 0) 0 else @intCast(55 + step * 40);
    }

    /// One line, as runs of cells with the same colors.
    fn line(self: Painter, cells: []const Cell, index: usize, row: usize) void {
        var buffer: [512]u8 = undefined;
        var start: usize = 0;
        while (start < cells.len) {
            const colors = self.colorsOf(cells[start], self.isSelected(index, start));
            var end = start;
            var len: usize = 0;
            while (end < cells.len and len + 4 <= buffer.len) : (end += 1) {
                if (!std.meta.eql(self.colorsOf(cells[end], self.isSelected(index, end)), colors)) break;
                len += std.unicode.utf8Encode(cells[end].char, buffer[len..]) catch 0;
            }
            const rect = self.cellRect(start, row, end - start);
            if (!std.meta.eql(colors.bg, self.look.theme.background)) self.canvas.fillRect(rect, colors.bg);
            const text = std.mem.trimEnd(u8, buffer[0..len], " ");
            if (text.len > 0) self.canvas.drawText(rect.x, rect.y, text, colors.fg);
            if (colors.underline) self.canvas.fillRect(.{ .x = rect.x, .y = rect.y + rect.h - 1, .w = rect.w, .h = 1 }, colors.fg);
            start = end;
        }
    }

    fn isSelected(self: Painter, index: usize, col: usize) bool {
        const range = self.selection orelse return false;
        return TerminalPanel.selected(range, index, col);
    }

    /// A block over the cell, with its character in the background color.
    fn cursor(self: Painter, grid: *const Grid) void {
        const at = grid.cursor;
        const rect = self.cellRect(at.x, at.y, 1);
        self.canvas.fillRect(rect, self.look.theme.cursor);
        const cell = grid.lines[at.y][at.x];
        var buffer: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cell.char, &buffer) catch return;
        if (cell.char != ' ') self.canvas.drawText(rect.x, rect.y, buffer[0..len], self.look.theme.background);
    }
};
