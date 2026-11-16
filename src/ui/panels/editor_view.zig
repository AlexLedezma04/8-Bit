//! Draws the visible part of a document: gutter, decorations, text, cursor.
//! What is visible is decided by `editor/view.zig`; this file only draws it.
const std = @import("std");
const Renderer = @import("../../platform/renderer.zig").Renderer;
const Editor = @import("../../editor/editor.zig").Editor;
const decoration = @import("../../editor/decoration.zig");
const Decoration = decoration.Decoration;
const Layout = @import("../layout.zig").Layout;
const Rect = @import("../layout.zig").Rect;
const theme_zig = @import("../theme.zig");
const Theme = theme_zig.Theme;
const Color = theme_zig.Color;

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
    renderer: *Renderer,
    theme: *const Theme,
    editor: *const Editor,
    layout: *const Layout,
    decorations: []const Decoration,

    fn drawLine(self: Painter, visible: VisibleLine) void {
        for (self.decorations) |item| self.drawDecoration(item, visible);
        if (visible.first_wrap == 0 and self.layout.number_cols > 0) self.drawLineNumber(visible);
        self.drawText(visible);
        self.drawCursor(visible);
    }

    fn drawDecoration(self: Painter, item: Decoration, visible: VisibleLine) void {
        const doc = &self.editor.doc;
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
            .line_background => |style| self.fillColumns(visible, 0, std.math.maxInt(usize), self.color(style)),
            .gutter_marker => |style| {
                var bar = self.gutterRows(visible);
                bar.w = self.layout.metrics.cell / 2;
                self.renderer.fillRect(bar, self.color(style));
            },
            .gutter_text => |text| if (visible.first_wrap == 0) {
                const rect = self.gutterRows(visible);
                self.renderer.drawText(rect.x + self.layout.metrics.cell, self.layout.metrics.textTop(rect.y), text, self.theme.line_number);
            },
        }
    }

    /// Fills the cells between two columns of a line, on each visible row.
    fn fillColumns(self: Painter, visible: VisibleLine, from: usize, to: usize, fill: Color) void {
        const view = &self.editor.view;
        for (0..visible.rows) |i| {
            const first = view.firstColumn(visible.first_wrap + i);
            const start = @max(from, first);
            const end = @min(to, first + view.cols);
            if (start >= end) continue;
            self.renderer.fillRect(self.layout.cellRect(start - first, visible.y + i, end - start), fill);
        }
    }

    fn gutterRows(self: Painter, visible: VisibleLine) Rect {
        var rect = self.layout.cellRect(0, visible.y, 0);
        rect.x = self.layout.gutter.x;
        rect.h *= @floatFromInt(visible.rows);
        return rect;
    }

    fn drawLineNumber(self: Painter, visible: VisibleLine) void {
        const doc = &self.editor.doc;
        const layout = self.layout;
        var digits: [20]u8 = undefined;
        const number = std.fmt.bufPrint(&digits, "{d}", .{visible.line + 1}) catch return;
        const column: f32 = @floatFromInt(1 + layout.gutter_text_cols + layout.number_cols - number.len);
        const current = visible.line == doc.buffer.lineOf(doc.cursor.pos);
        const rect = self.gutterRows(visible);
        self.renderer.drawText(
            rect.x + column * layout.metrics.cell,
            layout.metrics.textTop(rect.y),
            number,
            if (current) self.theme.line_number_current else self.theme.line_number,
        );
    }

    /// Draws the characters of the visible rows, one draw call per row.
    /// Characters outside the rows are skipped without being drawn.
    fn drawText(self: Painter, visible: VisibleLine) void {
        const doc = &self.editor.doc;
        const view = &self.editor.view;
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
        self.renderer.drawText(rect.x, self.layout.metrics.textTop(rect.y), text, self.theme.text);
    }

    fn drawCursor(self: Painter, visible: VisibleLine) void {
        const doc = &self.editor.doc;
        const view = &self.editor.view;
        const pos = doc.cursor.pos;
        if (doc.buffer.lineOf(pos) != visible.line) return;
        const row = view.rowOf(doc, pos);
        if (row.wrap < visible.first_wrap or row.wrap >= visible.first_wrap + visible.rows) return;
        const column = doc.columnOf(pos);
        const first = view.firstColumn(row.wrap);
        if (column < first or column - first >= view.cols) return;
        var bar = self.layout.cellRect(column - first, visible.y + row.wrap - visible.first_wrap, 0);
        bar.w = self.layout.metrics.cell / 8;
        self.renderer.fillRect(bar, self.theme.cursor);
    }

    fn color(self: Painter, style: decoration.Style) Color {
        return switch (style) {
            .selection => self.theme.selection,
            .match => self.theme.search_match,
            .added => self.theme.git_added,
            .changed => self.theme.git_changed,
            .removed => self.theme.git_removed,
        };
    }
};

/// Draws only the lines that are on screen, so the size of the file does
/// not matter.
pub fn draw(renderer: *Renderer, theme: *const Theme, editor: *const Editor, layout: *const Layout) void {
    const doc = &editor.doc;
    const view = &editor.view;
    renderer.fillRect(layout.gutter, theme.gutter);

    const line_count = doc.buffer.lineCount();
    const top = view.advance(doc, view.top, 0);
    const last_line = @min(top.line + view.rows, line_count - 1);
    const painter: Painter = .{
        .renderer = renderer,
        .theme = theme,
        .editor = editor,
        .layout = layout,
        .decorations = decoration.upTo(editor.decorations.items, .{
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
