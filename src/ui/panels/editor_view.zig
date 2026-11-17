//! The editor area panel: every pane with its tab bar and the visible part
//! of its document (gutter, decorations, text, cursor). What is visible is
//! decided by `editor/view.zig`; this file only draws it and routes typed
//! text and the mouse. A right click opens Copy, Cut and Paste; a click in
//! the gutter of a changed line opens what can be done with the change.
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
const menu_zig = @import("../widgets/menu.zig");
const scrollbar_zig = @import("../widgets/scrollbar.zig");
const Scrollbar = scrollbar_zig.Scrollbar;
const Minimap = @import("../widgets/minimap.zig").Minimap;
const commands = @import("../../editor/commands.zig");
const Color = @import("../theme.zig").Color;
const Event = @import("../../platform/event.zig").Event;
const syntax = @import("../../syntax/syntax.zig");
const Style = @import("../../syntax/grammar.zig").Style;
const diff = @import("../../git/diff.zig");

pub const EditorView = struct {
    editor: *Editor,
    menu: *menu_zig.Menu,
    /// Filled again on every draw and event.
    placed: std.ArrayList(layout.Placed) = .empty,
    splitters: std.ArrayList(layout.Splitter) = .empty,
    items: std.ArrayList(tabs.Item) = .empty,
    /// The styled spans of the line being drawn.
    spans: std.ArrayList(syntax.Span) = .empty,
    /// What the left mouse button is doing since it went down.
    /// `scroll` holds which scrollbar, and where its thumb was grabbed.
    drag: union(enum) { none, select, split: *panes.Split, scroll: struct { axis: scrollbar_zig.Axis, grabbed: f32 }, minimap } = .none,
    /// The commands of the open menu, by item.
    actions: []const commands.Command = &.{},

    pub fn deinit(self: *EditorView) void {
        const allocator = self.editor.allocator;
        self.placed.deinit(allocator);
        self.splitters.deinit(allocator);
        self.items.deinit(allocator);
        self.spans.deinit(allocator);
    }

    pub fn title(_: *EditorView) []const u8 {
        return "Editor";
    }

    fn place(self: *EditorView, rect: Rect) void {
        self.placed.clearRetainingCapacity();
        self.splitters.clearRetainingCapacity();
        layout.placePanes(self.editor.allocator, self.editor.root, rect, &self.placed, &self.splitters) catch {};
    }

    /// Where a pane's text goes, gutter and all: inside the minimap and the
    /// scrollbars.
    fn textArea(rect: Rect, metrics: Metrics) Rect {
        var area = rect.splitTop(metrics.bar())[1];
        area.w = @max(0, area.w - Scrollbar.width(metrics) - Minimap.width(metrics));
        area.h = @max(0, area.h - Scrollbar.width(metrics));
        return area;
    }

    /// The text layout of a pane, for the tab it shows: the right half of
    /// the text area beside the text at HEAD.
    fn textLayout(self: *const EditorView, rect: Rect, metrics: Metrics, tab: *const Tab) TextLayout {
        const lines: ?usize = if (self.editor.settings.line_numbers) tab.file.doc.buffer.lineCount() else null;
        var area = textArea(rect, metrics);
        if (tab.compare) {
            const half = @floor(area.w / 2);
            area.x += half;
            area.w -= half;
        }
        return .init(area, metrics, lines, decoration.gutterTextWidth(tab.decorations.items));
    }

    /// The text at HEAD, left of the text of a tab that compares.
    fn beforeRect(self: *const EditorView, rect: Rect, metrics: Metrics, tab: *const Tab) ?Rect {
        if (!tab.compare) return null;
        const area = textArea(rect, metrics);
        const text = self.textLayout(rect, metrics, tab);
        return .{ .x = area.x, .y = area.y, .w = text.gutter.x - area.x - 1, .h = text.text.h };
    }

    /// The scrollbars of a pane: lines at the right, columns of the widest
    /// line on screen below the text. Without wrap only.
    fn scrollbars(self: *const EditorView, rect: Rect, metrics: Metrics, tab: *const Tab) [2]Scrollbar {
        const text = self.textLayout(rect, metrics, tab).text;
        const view = &tab.view;
        const doc = &tab.file.doc;
        const lines = doc.buffer.lineCount();
        var widest: usize = 0;
        for (view.top.line..@min(lines, view.top.line + view.rows)) |line| widest = @max(widest, doc.columnOf(doc.buffer.lineEnd(line)));
        const right = Scrollbar.rightOf(rect.splitTop(metrics.bar())[1], metrics);
        return .{
            .{ .track = .{ .x = right.x, .y = right.y, .w = right.w, .h = text.h }, .first = view.top.line, .last = lines - 1, .shown = view.rows },
            .{
                .track = .{ .x = text.x, .y = text.y + text.h, .w = text.w, .h = right.w },
                .axis = .horizontal,
                .first = view.left,
                .last = if (view.wrap) 0 else @max((widest + 1) -| view.cols, view.left),
                .shown = view.cols,
            },
        };
    }

    fn minimap(self: *const EditorView, rect: Rect, metrics: Metrics, tab: *const Tab) Minimap {
        const text = self.textLayout(rect, metrics, tab).text;
        return .init(.{ .x = text.x + text.w, .y = text.y, .w = Minimap.width(metrics), .h = text.h }, metrics, tab.file.doc.buffer.lineCount());
    }

    /// Centers the line under the mouse.
    fn scrollToMinimap(tab: *Tab, map: Minimap, y: f32) void {
        tab.view.top = .{ .line = map.lineAt(y) -| tab.view.rows / 2 };
    }

    /// Scrolls a tab to what a scrollbar was dragged to.
    fn scrollTo(tab: *Tab, bar: Scrollbar, at: f32, grabbed: f32) void {
        const first = bar.firstAt(at, grabbed);
        if (bar.axis == .vertical) tab.view.top = .{ .line = first } else tab.view.left = first;
    }

    fn tabItems(self: *EditorView, pane: *const panes.Pane) []const tabs.Item {
        self.items.clearRetainingCapacity();
        for (pane.tabs.items) |tab| {
            self.items.append(self.editor.allocator, .{ .title = tab.file.name(), .preview = tab.file.preview }) catch break;
        }
        return self.items.items;
    }

    pub fn draw(self: *EditorView, canvas: Canvas, look: Look, rect: Rect, focused: bool) void {
        self.place(rect);
        for (self.placed.items) |item| {
            const pane = item.node.pane();
            const active = item.node == self.editor.pane;
            tabs.draw(canvas, look, item.rect.splitTop(look.metrics.bar())[0], .files, self.tabItems(pane), pane.active, focused and active);
            const tab = pane.tab();
            const text = self.textLayout(item.rect, look.metrics, tab);
            tab.view.setSize(&tab.file.doc, self.editor.cursorOf(tab).pos, text.cols, text.rows);
            canvas.setClip(.{ .x = text.gutter.x, .y = text.gutter.y, .w = text.gutter.w + text.text.w, .h = text.text.h });
            const before = self.beforeRect(item.rect, look.metrics, tab);
            drawTab(canvas, look, self.editor, tab, &text, before, focused and active, &self.spans);
            canvas.setClip(null);
            if (before) |left| canvas.fillRect(.{ .x = left.x + left.w, .y = left.y, .w = 1, .h = left.h }, look.theme.border);
            for (self.scrollbars(item.rect, look.metrics, tab)) |bar| bar.draw(canvas, look);
            self.minimap(item.rect, look.metrics, tab).draw(canvas, look, &tab.file.doc, tab.file.changes(), tab.view.top.line, tab.view.rows);
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
                    const hit = tabs.hit(bar, metrics, .files, self.tabItems(pane), pane.active, mouse.x, mouse.y) orelse return .yes;
                    editor.switchTo(item.node, hit.index);
                    if (hit.close or mouse.button == .middle) return .{ .request = editor.closeTab(hit.index) };
                    return .yes;
                }
                if (mouse.button == .middle) return .yes;
                if (item.node != editor.pane) editor.switchTo(item.node, pane.active);
                for (self.scrollbars(item.rect, metrics, pane.tab())) |bar_| {
                    if (!bar_.visible() or !bar_.track.contains(mouse.x, mouse.y)) continue;
                    const at = bar_.along(mouse.x, mouse.y);
                    self.drag = .{ .scroll = .{ .axis = bar_.axis, .grabbed = bar_.grab(at) } };
                    scrollTo(pane.tab(), bar_, at, self.drag.scroll.grabbed);
                    return .yes;
                }
                const map = self.minimap(item.rect, metrics, pane.tab());
                if (map.rect.contains(mouse.x, mouse.y)) {
                    self.drag = .minimap;
                    scrollToMinimap(pane.tab(), map, mouse.y);
                    return .yes;
                }
                if (self.beforeRect(item.rect, metrics, pane.tab())) |left| if (left.contains(mouse.x, mouse.y)) return .yes;
                const cell = self.textLayout(item.rect, metrics, pane.tab()).cellAt(mouse.x, mouse.y);
                if (mouse.button == .right) return self.openMenu(cell, mouse.x, mouse.y);
                editor.mouseDown(cell.x, cell.y, mouse.clicks, mouse.mods.shift);
                if (cell.x < 0) {
                    const line = editor.doc().buffer.lineOf(editor.doc().cursor.pos);
                    if (editor.file().tracking.hunkAt(editor.doc(), line) != null) return self.openChangeMenu(mouse.x, mouse.y);
                    editor.clickGutter(line);
                }
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
                .scroll => |scroll| for (self.placed.items) |item| if (item.node == editor.pane) {
                    const tab = item.node.pane().tab();
                    const bar_ = self.scrollbars(item.rect, metrics, tab)[@backingInt(scroll.axis)];
                    scrollTo(tab, bar_, bar_.along(mouse.x, mouse.y), scroll.grabbed);
                },
                .minimap => for (self.placed.items) |item| if (item.node == editor.pane) {
                    const tab = item.node.pane().tab();
                    scrollToMinimap(tab, self.minimap(item.rect, metrics, tab), mouse.y);
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
                const rows: isize = @intFromFloat(-wheel.dy);
                const cols: isize = @intFromFloat(wheel.dx);
                const tab = pane.tab();
                // Shift turns the wheel sideways.
                if (wheel.mods.shift) tab.view.scrollBy(&tab.file.doc, 0, rows) else tab.view.scrollBy(&tab.file.doc, rows, cols);
            },
            .text => |text| editor.typeText(text),
            else => return .no,
        }
        return .yes;
    }

    const edit_actions = [_]commands.Command{ .copy, .cut, .paste };
    const change_actions = [_]commands.Command{ .prev_change, .next_change, .peek_change, .revert_change };

    /// A right click outside the selection moves the cursor first.
    fn openMenu(self: *EditorView, cell: layout.Cell, x: f32, y: f32) Handled {
        const editor = self.editor;
        const doc = editor.doc();
        const selection = doc.cursor.selection();
        const pos = editor.view().posAt(doc, cell.x, cell.y);
        if (pos < selection.start or pos > selection.end or selection.len() == 0) editor.mouseDown(cell.x, cell.y, 1, false);
        const selected = doc.cursor.selection().len() > 0;
        self.actions = &edit_actions;
        self.menu.open(&.{
            .{ .label = "Copy", .shortcut = "Ctrl+C", .enabled = selected },
            .{ .label = "Cut", .shortcut = "Ctrl+X", .enabled = selected and !doc.read_only },
            .{ .label = "Paste", .shortcut = "Ctrl+V", .enabled = !doc.read_only },
        }, x, y, .of(EditorView, self));
        return .yes;
    }

    /// The change at the cursor line.
    fn openChangeMenu(self: *EditorView, x: f32, y: f32) Handled {
        self.actions = &change_actions;
        self.menu.open(&.{
            .{ .label = "Previous Change", .shortcut = "Shift+F7" },
            .{ .label = "Next Change", .shortcut = "F7" },
            .{ .label = "Show Diff", .shortcut = "Ctrl+Alt+D" },
            .{ .label = "Revert", .shortcut = "Ctrl+Alt+Z" },
        }, x, y, .of(EditorView, self));
        return .yes;
    }

    pub fn choose(self: *EditorView, index: usize) ?editor_zig.Request {
        return commands.run(self.editor, self.actions[index]);
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
    /// Of the line being drawn.
    spans: []const syntax.Span = &.{},

    fn drawLine(self: Painter, visible: VisibleLine) void {
        // Line backgrounds first and the selection last, so it stays on top.
        for (self.decorations) |item| if (item.kind == .line_background) self.drawDecoration(item, visible);
        for (self.decorations) |item| if (item.kind != .line_background and !isSelection(item)) self.drawDecoration(item, visible);
        for (self.decorations) |item| if (isSelection(item)) self.drawDecoration(item, visible);
        if (visible.first_wrap == 0 and self.layout.number_cols > 0) self.drawLineNumber(visible);
        self.drawText(visible);
        if (self.show_cursor) self.drawCursor(visible);
    }

    fn isSelection(item: Decoration) bool {
        return item.kind == .text_background and item.kind.text_background == .selection;
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

    /// Draws the characters of the visible rows, one draw call per run of
    /// one style. Characters outside the rows are skipped without being drawn.
    fn drawText(self: Painter, visible: VisibleLine) void {
        const doc = &self.tab.file.doc;
        const view = &self.tab.view;
        const line_start = doc.buffer.lineStart(visible.line);
        const last_wrap = visible.first_wrap + visible.rows - 1;

        var text: [2048]u8 = undefined;
        var len: usize = 0;
        // The cell of the first character in `text`, and the cell after the last.
        var run_x: usize = 0;
        var next_x: usize = 0;
        var style: Style = .text;
        var span: usize = 0;
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
                self.drawRun(visible, wrap, run_x, text[0..len], style);
                wrap = cell_wrap;
                len = 0;
            }
            if (cell.char.cp == '\t' or cell.char.cp == ' ') continue;
            const offset = cell.pos - line_start;
            while (span < self.spans.len and self.spans[span].end <= offset) span += 1;
            const cell_style = if (span < self.spans.len and self.spans[span].start <= offset) self.spans[span].style else .text;
            if (len > 0 and cell_style != style) {
                self.drawRun(visible, wrap, run_x, text[0..len], style);
                len = 0;
            }
            if (len == 0) {
                run_x = x;
                next_x = x;
                style = cell_style;
            }
            const pad = x - next_x;
            if (len + pad + cell.char.len > text.len) break;
            @memset(text[len..][0..pad], ' ');
            len += pad + doc.buffer.copy(cell.pos, text[len + pad ..][0..cell.char.len]).len;
            next_x = x + 1;
        }
        self.drawRun(visible, wrap, run_x, text[0..len], style);
    }

    fn drawRun(self: Painter, visible: VisibleLine, wrap: usize, x: usize, text: []const u8, style: Style) void {
        if (text.len == 0) return;
        const rect = self.layout.cellRect(x, visible.y + wrap - visible.first_wrap, 0);
        const theme = self.look.theme;
        self.canvas.drawText(rect.x, rect.y, text, switch (style) {
            .text => theme.text,
            inline else => |tag| @field(theme.syntax, @tagName(tag)),
        });
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
        bar.w = self.layout.metrics.caret();
        self.canvas.fillRect(bar, self.look.theme.cursor);
    }

    /// The text at HEAD of a change, over the rows from `row`.
    fn drawPeek(self: Painter, hunk: diff.Hunk, row: usize) void {
        const view = &self.tab.view;
        var lines = std.mem.splitScalar(u8, diff.lineSpan(self.tab.file.tracking.head.ready, hunk.old_start, hunk.old_len), '\n');
        for (row..@min(row + hunk.old_len, view.rows)) |y| {
            var rect = self.gutterRows(.{ .line = 0, .first_wrap = 0, .rows = 1, .y = y });
            rect.w += self.layout.text.w;
            self.drawOldLine(rect, self.layout.text.x, lines.next() orelse "", true);
        }
    }

    /// The text at HEAD in `rect`, from the line beside the top of the text.
    fn drawBefore(self: Painter, rect: Rect) void {
        const tracking = &self.tab.file.tracking;
        const head = switch (tracking.head) {
            .ready => |text| text,
            else => return,
        };
        const hunks = tracking.hunks.items;
        const first = diff.oldLine(hunks, self.tab.view.top.line);
        var lines = std.mem.splitScalar(u8, diff.lineSpan(head, first, self.tab.view.rows), '\n');
        for (0..self.tab.view.rows) |y| {
            const text = lines.next() orelse break;
            const line = first + y;
            const removed = for (hunks) |hunk| {
                if (line >= hunk.old_start and line < hunk.old_start + hunk.old_len) break true;
            } else false;
            var row = self.layout.cellRect(0, y, 0);
            row.x = rect.x;
            row.w = rect.w;
            self.drawOldLine(row, rect.x + self.layout.metrics.cell, text, removed);
        }
    }

    /// A line of the text at HEAD, red when it is removed or changed. Tabs
    /// as spaces, as the text draws them.
    fn drawOldLine(self: Painter, row: Rect, x: f32, text: []const u8, removed: bool) void {
        if (removed) self.canvas.fillRect(row, self.look.theme.diff_removed);
        const tab_width = self.tab.file.doc.tab_width;
        var buffer: [1024]u8 = undefined;
        var len: usize = 0;
        for (std.mem.trimEnd(u8, text, "\r")) |byte| {
            const spaces = if (byte == '\t') tab_width - len % tab_width else 1;
            if (len + spaces > buffer.len) break;
            @memset(buffer[len..][0..spaces], if (byte == '\t') ' ' else byte);
            len += spaces;
        }
        self.canvas.drawText(x, row.y, buffer[@min(self.tab.view.left, len)..len], self.look.theme.text);
    }

    fn color(self: Painter, style: decoration.Style) Color {
        return self.look.theme.styleColor(style);
    }
};

/// Draws only the lines of a tab that are on screen, so the size of the
/// file does not matter.
fn drawTab(canvas: Canvas, look: Look, editor: *const Editor, tab: *const Tab, text: *const TextLayout, before: ?Rect, focused: bool, spans: *std.ArrayList(syntax.Span)) void {
    const doc = &tab.file.doc;
    const view = &tab.view;
    canvas.fillRect(text.gutter, look.theme.gutter);

    const line_count = doc.buffer.lineCount();
    const top = view.advance(doc, view.top, 0);
    const last_line = @min(top.line + view.rows, line_count - 1);
    var painter: Painter = .{
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

    const peek = tab.peeked();
    // The old lines go where the line after the change starts.
    const below = if (peek) |hunk| hunk.new_start + hunk.new_len else null;
    var peek_row: ?usize = null;
    var line = top.line;
    var first_wrap = top.wrap;
    var y: usize = 0;
    while (y < view.rows and line < line_count) : (line += 1) {
        if (line == below) peek_row = y;
        const rows = @min(view.rowsOf(doc, line) - first_wrap, view.rows - y);
        tab.file.highlighter.spans(&tab.file.doc, line, spans);
        painter.spans = spans.items;
        painter.drawLine(.{ .line = line, .first_wrap = first_wrap, .rows = rows, .y = y });
        y += rows;
        first_wrap = 0;
    }
    if (line == below) peek_row = y;
    if (peek_row) |row| painter.drawPeek(peek.?, row);
    if (before) |left| {
        canvas.setClip(left);
        painter.drawBefore(left);
    }
}
