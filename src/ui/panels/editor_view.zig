//! The editor area panel: every pane with its tab bar and the visible part
//! of its document (gutter, decorations, text, cursor). What is visible is
//! decided by `editor/view.zig`; this file only draws it and routes the mouse.
const std = @import("std");
const editor_zig = @import("../../editor/editor.zig");
const Editor = editor_zig.Editor;
const panes = @import("../../editor/panes.zig");
const Tab = panes.Tab;
const decoration = @import("../../editor/decoration.zig");
const Decoration = decoration.Decoration;
const layout = @import("../layout.zig");
const Rect = layout.Rect;
const Metrics = layout.Metrics;
const TextLayout = layout.TextLayout;
const Canvas = @import("../canvas.zig").Canvas;
const panel = @import("../panel.zig");
const Look = panel.Look;
const Handled = panel.Handled;
const tabs = @import("../widgets/tabs.zig");
const Color = @import("../theme.zig").Color;
const Event = @import("../../platform/event.zig").Event;

/// Rows scrolled per step of the mouse wheel.
const wheel_rows = 3;

pub const EditorView = struct {
    editor: *Editor,
    /// Filled again on every draw and event.
    placed: std.ArrayList(layout.Placed) = .empty,
    splitters: std.ArrayList(layout.Splitter) = .empty,
    items: std.ArrayList(tabs.Item) = .empty,
    /// What the left mouse button is doing since it went down.
    drag: union(enum) { none, select, split: *panes.Split } = .none,

    pub fn deinit(self: *EditorView) void {
        const allocator = self.editor.allocator;
        self.placed.deinit(allocator);
        self.splitters.deinit(allocator);
        self.items.deinit(allocator);
    }

    pub fn title(_: *EditorView) []const u8 {
        return "Editor";
    }

    fn place(self: *EditorView, rect: Rect) void {
        self.placed.clearRetainingCapacity();
        self.splitters.clearRetainingCapacity();
        layout.placePanes(self.editor.allocator, self.editor.root, rect, &self.placed, &self.splitters) catch {};
    }

    /// The text layout of a pane, for the tab it shows.
    fn textLayout(self: *const EditorView, rect: Rect, metrics: Metrics, tab: *const Tab) TextLayout {
        const lines: ?usize = if (self.editor.settings.line_numbers) tab.file.doc.buffer.lineCount() else null;
        return .init(rect.splitTop(metrics.bar())[1], metrics, lines, decoration.gutterTextWidth(tab.decorations.items));
    }

    fn tabItems(self: *EditorView, pane: *const panes.Pane) []const tabs.Item {
        self.items.clearRetainingCapacity();
        for (pane.tabs.items) |tab| {
            self.items.append(self.editor.allocator, .{ .title = tab.file.name(), .modified = tab.file.isModified() }) catch break;
        }
        return self.items.items;
    }

    pub fn draw(self: *EditorView, canvas: Canvas, look: Look, rect: Rect, focused: bool) void {
        self.place(rect);
        for (self.placed.items) |item| {
            const pane = item.node.pane();
            const active = item.node == self.editor.pane;
            tabs.draw(canvas, look, item.rect.splitTop(look.metrics.bar())[0], self.tabItems(pane), pane.active, focused and active);
            const tab = pane.tab();
            const text = self.textLayout(item.rect, look.metrics, tab);
            tab.view.cols = text.cols;
            tab.view.rows = text.rows;
            canvas.setClip(.{ .x = text.gutter.x, .y = text.gutter.y, .w = text.gutter.w + text.text.w, .h = text.text.h });
            drawTab(canvas, look, self.editor, tab, &text, focused and active);
            canvas.setClip(null);
        }
        for (self.splitters.items) |splitter| canvas.fillRect(splitter.line, look.theme.border);
    }

    pub fn handle(self: *EditorView, event: Event, metrics: Metrics, rect: Rect) Handled {
        self.place(rect);
        const editor = self.editor;
        switch (event) {
            .mouse_down => |mouse| {
                for (self.splitters.items) |splitter| {
                    const line = splitter.line;
                    const grip: Rect = .{ .x = line.x - layout.Frame.grip, .y = line.y - layout.Frame.grip, .w = line.w + 2 * layout.Frame.grip, .h = line.h + 2 * layout.Frame.grip };
                    if (grip.contains(mouse.x, mouse.y)) {
                        self.drag = .{ .split = splitter.split };
                        return .yes;
                    }
                }
                const item = self.paneAt(mouse.x, mouse.y) orelse return .yes;
                const pane = item.node.pane();
                const bar = item.rect.splitTop(metrics.bar())[0];
                if (bar.contains(mouse.x, mouse.y)) {
                    const hit = tabs.hit(bar, metrics, self.tabItems(pane), pane.active, mouse.x, mouse.y) orelse return .yes;
                    editor.switchTo(item.node, hit.index);
                    if (hit.close or mouse.button == .middle) return .{ .request = editor.closeTab(hit.index) };
                    return .yes;
                }
                if (mouse.button != .left) return .yes;
                if (item.node != editor.pane) editor.switchTo(item.node, pane.active);
                const cell = self.textLayout(item.rect, metrics, pane.tab()).cellAt(mouse.x, mouse.y);
                editor.mouseDown(cell.x, cell.y, mouse.clicks, mouse.mods.shift);
                self.drag = .select;
            },
            .mouse_move => |mouse| switch (self.drag) {
                .none => return .no,
                .split => |split| for (self.splitters.items) |splitter| {
                    if (splitter.split == split) split.ratio = layout.ratioAt(splitter, mouse.x, mouse.y);
                },
                .select => for (self.placed.items) |item| if (item.node == editor.pane) {
                    const cell = self.textLayout(item.rect, metrics, item.node.pane().tab()).cellAt(mouse.x, mouse.y);
                    editor.mouseDrag(cell.x, cell.y);
                },
            },
            .mouse_up => {
                const was = self.drag;
                self.drag = .none;
                return if (was == .none) .no else .yes;
            },
            .wheel => |wheel| {
                const item = self.paneAt(wheel.x, wheel.y) orelse return .yes;
                const pane = item.node.pane();
                if (item.rect.splitTop(metrics.bar())[0].contains(wheel.x, wheel.y)) {
                    if (wheel.dy != 0 and item.node == editor.pane) editor.cycleTab(if (wheel.dy > 0) -1 else 1);
                    return .yes;
                }
                const rows: isize = @intFromFloat(-wheel.dy * wheel_rows);
                const cols: isize = @intFromFloat(wheel.dx * wheel_rows);
                const tab = pane.tab();
                // Shift turns the wheel sideways.
                if (wheel.mods.shift) tab.view.scrollBy(&tab.file.doc, 0, rows) else tab.view.scrollBy(&tab.file.doc, rows, cols);
            },
            else => return .no,
        }
        return .yes;
    }

    fn paneAt(self: *const EditorView, x: f32, y: f32) ?layout.Placed {
        for (self.placed.items) |item| if (item.rect.contains(x, y)) return item;
        return null;
    }
};

/// A line and the part of its rows that is on screen.
const VisibleLine = struct {
    line: usize,
    /// First wrapped row of the line that is visible, and how many are.
    first_wrap: usize,
    rows: usize,
    /// Screen row of `first_wrap`.
    y: usize,
};

const Painter = struct {
    canvas: Canvas,
    look: Look,
    tab: *const Tab,
    cursor: @import("../../core/cursor.zig").Cursor,
    show_cursor: bool,
    layout: *const TextLayout,
    decorations: []const Decoration,

    fn drawLine(self: Painter, visible: VisibleLine) void {
        // Line backgrounds first, so marks on the text stay on top.
        for (self.decorations) |item| if (item.kind == .line_background) self.drawDecoration(item, visible);
        for (self.decorations) |item| if (item.kind != .line_background) self.drawDecoration(item, visible);
        if (visible.first_wrap == 0 and self.layout.number_cols > 0) self.drawLineNumber(visible);
        self.drawText(visible);
        if (self.show_cursor) self.drawCursor(visible);
    }

    fn drawDecoration(self: Painter, item: Decoration, visible: VisibleLine) void {
        const doc = &self.tab.file.doc;
        const line = doc.lineRange(visible.line);
        const text_end = doc.buffer.lineEnd(visible.line);
        if (item.range.start > text_end or item.range.end < line.start) return;
        switch (item.kind) {
            .text_background => |style| {
                if (item.range.end <= line.start) return;
                const from = doc.columnOf(@max(item.range.start, line.start));
                // One more cell when the line break is part of the range.
                const to = if (item.range.end > text_end) doc.columnOf(text_end) + 1 else doc.columnOf(item.range.end);
                self.fillColumns(visible, from, to, self.color(style));
            },
            .line_background => |style| {
                var rows = self.gutterRows(visible);
                rows.w += self.layout.text.w;
                self.canvas.fillRect(rows, self.color(style));
            },
            .gutter_marker => |style| {
                var bar = self.gutterRows(visible);
                bar.w = self.layout.metrics.cell / 2;
                self.canvas.fillRect(bar, self.color(style));
            },
            .gutter_text => |text| if (visible.first_wrap == 0) {
                const rect = self.gutterRows(visible);
                self.canvas.drawText(rect.x + self.layout.metrics.cell, rect.y, text, self.look.theme.line_number);
            },
        }
    }

    /// Fills the cells between two columns of a line, on each visible row.
    fn fillColumns(self: Painter, visible: VisibleLine, from: usize, to: usize, fill: Color) void {
        const view = &self.tab.view;
        for (0..visible.rows) |i| {
            const first = view.firstColumn(visible.first_wrap + i);
            const start = @max(from, first);
            const end = @min(to, first + view.cols);
            if (start >= end) continue;
            self.canvas.fillRect(self.layout.cellRect(start - first, visible.y + i, end - start), fill);
        }
    }

    fn gutterRows(self: Painter, visible: VisibleLine) Rect {
        var rect = self.layout.cellRect(0, visible.y, 0);
        rect.x = self.layout.gutter.x;
        rect.w = self.layout.gutter.w;
        rect.h *= @floatFromInt(visible.rows);
        return rect;
    }

    fn drawLineNumber(self: Painter, visible: VisibleLine) void {
        const doc = &self.tab.file.doc;
        const text_layout = self.layout;
        var digits: [20]u8 = undefined;
        const number = std.fmt.bufPrint(&digits, "{d}", .{visible.line + 1}) catch return;
        const column: f32 = @floatFromInt(1 + text_layout.gutter_text_cols + text_layout.number_cols - number.len);
        const current = visible.line == doc.buffer.lineOf(@min(self.cursor.pos, doc.buffer.len()));
        const rect = self.gutterRows(visible);
        const theme = self.look.theme;
        self.canvas.drawText(rect.x + column * text_layout.metrics.cell, rect.y, number, if (current) theme.line_number_current else theme.line_number);
    }

    /// Draws the characters of the visible rows, one draw call per row.
    /// Characters outside the rows are skipped without being drawn.
    fn drawText(self: Painter, visible: VisibleLine) void {
        const doc = &self.tab.file.doc;
        const view = &self.tab.view;
        const last_wrap = visible.first_wrap + visible.rows - 1;

        var row_text: [2048]u8 = undefined;
        var len: usize = 0;
        var filled: usize = 0;
        var wrap = visible.first_wrap;
        var cells = doc.cells(visible.line);
        while (cells.next()) |cell| {
            const cell_wrap = if (view.wrap) cell.column / @max(view.cols, 1) else 0;
            if (cell_wrap < visible.first_wrap) continue;
            if (cell_wrap > last_wrap) break;
            const first = view.firstColumn(cell_wrap);
            if (cell.column < first) continue;
            const x = cell.column - first;
            if (x >= view.cols) break;
            if (cell_wrap != wrap) {
                self.drawRowText(visible, wrap, row_text[0..len]);
                wrap = cell_wrap;
                len = 0;
                filled = 0;
            }
            if (cell.char.cp == '\t' or cell.char.cp == ' ') continue;
            const pad = x - filled;
            if (len + pad + cell.char.len > row_text.len) break;
            @memset(row_text[len..][0..pad], ' ');
            len += pad + doc.buffer.copy(cell.pos, row_text[len + pad ..][0..cell.char.len]).len;
            filled = x + 1;
        }
        self.drawRowText(visible, wrap, row_text[0..len]);
    }

    fn drawRowText(self: Painter, visible: VisibleLine, wrap: usize, text: []const u8) void {
        const rect = self.layout.cellRect(0, visible.y + wrap - visible.first_wrap, 0);
        self.canvas.drawText(rect.x, rect.y, text, self.look.theme.text);
    }

    fn drawCursor(self: Painter, visible: VisibleLine) void {
        const doc = &self.tab.file.doc;
        const view = &self.tab.view;
        const pos = self.cursor.pos;
        if (doc.buffer.lineOf(pos) != visible.line) return;
        const row = view.rowOf(doc, pos);
        if (row.wrap < visible.first_wrap or row.wrap >= visible.first_wrap + visible.rows) return;
        const column = doc.columnOf(pos);
        const first = view.firstColumn(row.wrap);
        if (column < first or column - first >= view.cols) return;
        var bar = self.layout.cellRect(column - first, visible.y + row.wrap - visible.first_wrap, 0);
        bar.w = @max(1, @floor(self.layout.metrics.cell / 8));
        self.canvas.fillRect(bar, self.look.theme.cursor);
    }

    fn color(self: Painter, style: decoration.Style) Color {
        const theme = self.look.theme;
        return switch (style) {
            .selection => theme.selection,
            .current_line => theme.current_line,
            .match => theme.search_match,
            .added => theme.git_added,
            .changed => theme.git_changed,
            .removed => theme.git_removed,
        };
    }
};

/// Draws only the lines of a tab that are on screen, so the size of the
/// file does not matter.
fn drawTab(canvas: Canvas, look: Look, editor: *const Editor, tab: *const Tab, text: *const TextLayout, focused: bool) void {
    const doc = &tab.file.doc;
    const view = &tab.view;
    canvas.fillRect(text.gutter, look.theme.gutter);

    const line_count = doc.buffer.lineCount();
    const top = view.advance(doc, view.top, 0);
    const last_line = @min(top.line + view.rows, line_count - 1);
    const painter: Painter = .{
        .canvas = canvas,
        .look = look,
        .tab = tab,
        .cursor = editor.cursorOf(tab),
        .show_cursor = focused,
        .layout = text,
        .decorations = decoration.upTo(tab.decorations.items, .{
            .start = doc.buffer.lineStart(top.line),
            .end = doc.buffer.lineEnd(last_line),
        }),
    };

    var line = top.line;
    var first_wrap = top.wrap;
    var y: usize = 0;
    while (y < view.rows and line < line_count) : (line += 1) {
        const rows = @min(view.rowsOf(doc, line) - first_wrap, view.rows - y);
        painter.drawLine(.{ .line = line, .first_wrap = first_wrap, .rows = rows, .y = y });
        y += rows;
        first_wrap = 0;
    }
}
