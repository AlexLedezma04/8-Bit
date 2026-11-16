//! Which part of a document is on screen: scroll position and line wrapping.
//! Everything is measured in character cells; `ui/` turns cells into pixels.
//! Only lines near the screen are ever measured.
const std = @import("std");
const Document = @import("../core/edit.zig").Document;

/// One screen row: a line, and which wrapped row of that line.
pub const Row = struct {
    line: usize = 0,
    wrap: usize = 0,

    fn isBefore(self: Row, other: Row) bool {
        return self.line < other.line or (self.line == other.line and self.wrap < other.wrap);
    }
};

pub const View = struct {
    /// Size of the text area. The UI sets it on every layout.
    cols: usize = 80,
    rows: usize = 24,
    /// Long lines continue on the next row instead of being clipped.
    wrap: bool = false,
    /// The row at the top of the text area.
    top: Row = .{},
    /// First visible column when wrap is off.
    left: usize = 0,

    /// Rows and columns kept between the cursor and the edge when possible.
    const margin_rows = 2;
    const margin_cols = 4;

    pub fn setWrap(self: *View, wrap: bool) void {
        self.wrap = wrap;
        self.top.wrap = 0;
        self.left = 0;
    }

    /// Number of screen rows `line` takes.
    pub fn rowsOf(self: *const View, doc: *const Document, line: usize) usize {
        if (!self.wrap) return 1;
        return doc.columnOf(doc.buffer.lineEnd(line)) / self.width() + 1;
    }

    /// First column shown on a wrapped row of a line.
    pub fn firstColumn(self: *const View, wrap_row: usize) usize {
        return if (self.wrap) wrap_row * self.width() else self.left;
    }

    pub fn rowOf(self: *const View, doc: *const Document, pos: usize) Row {
        return .{
            .line = doc.buffer.lineOf(pos),
            .wrap = if (self.wrap) doc.columnOf(pos) / self.width() else 0,
        };
    }

    /// The row `delta` rows after `from` (before, if negative). Stops at the
    /// first and the last row of the document.
    pub fn advance(self: *const View, doc: *const Document, from: Row, delta: isize) Row {
        const last_line = doc.buffer.lineCount() - 1;
        var row: Row = .{ .line = @min(from.line, last_line) };
        var line_rows = self.rowsOf(doc, row.line);
        row.wrap = @min(from.wrap, line_rows - 1);

        var steps = @abs(delta);
        while (steps > 0) : (steps -= 1) {
            if (delta < 0) {
                if (row.wrap > 0) {
                    row.wrap -= 1;
                } else if (row.line > 0) {
                    row.line -= 1;
                    line_rows = self.rowsOf(doc, row.line);
                    row.wrap = line_rows - 1;
                } else break;
            } else {
                if (row.wrap + 1 < line_rows) {
                    row.wrap += 1;
                } else if (row.line < last_line) {
                    row.line += 1;
                    line_rows = self.rowsOf(doc, row.line);
                    row.wrap = 0;
                } else break;
            }
        }
        return row;
    }

    pub fn scrollBy(self: *View, doc: *const Document, rows: isize, cols: isize) void {
        self.top = self.advance(doc, self.top, rows);
        if (!self.wrap) self.left = if (cols < 0) self.left -| @abs(cols) else self.left + @abs(cols);
    }

    /// Scrolls just enough to show the cursor, with a small margin.
    pub fn scrollToCursor(self: *View, doc: *const Document) void {
        const pos = doc.cursor.pos;
        const cursor = self.rowOf(doc, pos);
        const margin: isize = @intCast(@min(margin_rows, (self.rows -| 1) / 2));
        const last_row: isize = @intCast(self.rows -| 1);
        const lowest_top = self.advance(doc, cursor, -margin);
        const highest_top = self.advance(doc, cursor, margin - last_row);
        self.top = self.advance(doc, self.top, 0);
        if (lowest_top.isBefore(self.top)) self.top = lowest_top;
        if (self.top.isBefore(highest_top)) self.top = highest_top;

        if (self.wrap) return;
        const column = doc.columnOf(pos);
        const side = @min(margin_cols, (self.cols -| 1) / 2);
        if (column < self.left + side) self.left = column -| side;
        if (column + side >= self.left + self.cols) self.left = column + side + 1 - self.cols;
    }

    /// Text position under a cell of the text area. Cells outside the area
    /// give the nearest position, so a drag can leave the area.
    pub fn posAt(self: *const View, doc: *const Document, cell_x: isize, cell_y: isize) usize {
        const row = self.advance(doc, self.top, cell_y);
        const x: usize = @intCast(std.math.clamp(cell_x, 0, @as(isize, @intCast(self.width())) - 1));
        return doc.posAtColumn(row.line, self.firstColumn(row.wrap) + x);
    }

    /// Moves the cursor up or down by screen rows, keeping its column.
    pub fn moveVertical(self: *const View, doc: *Document, rows: isize, extend: bool) void {
        if (!self.wrap) {
            const lines = @abs(rows);
            return doc.move(if (rows < 0) .{ .page_up = lines } else .{ .page_down = lines }, extend);
        }
        const goal = doc.cursor.goal_col orelse doc.columnOf(doc.cursor.pos);
        const target = self.advance(doc, self.rowOf(doc, doc.cursor.pos), rows);
        const column = self.firstColumn(target.wrap) + goal % self.width();
        doc.cursor.moveTo(doc.posAtColumn(target.line, column), extend);
        doc.cursor.goal_col = column;
    }

    /// Rows a page move travels: one screen, keeping one row of context.
    pub fn pageRows(self: *const View) isize {
        return @intCast(@max(self.rows -| 1, 1));
    }

    fn width(self: *const View) usize {
        return @max(self.cols, 1);
    }
};

const testing = std.testing;

fn testDocument(text: []const u8) !Document {
    var doc = Document.init(testing.allocator);
    errdefer doc.deinit();
    try doc.load(text);
    return doc;
}

/// Ten lines "0".."9", each on its own line.
const ten_lines = "0\n1\n2\n3\n4\n5\n6\n7\n8\n9";

test "advance stops at both ends" {
    var doc = try testDocument(ten_lines);
    defer doc.deinit();
    const view: View = .{};
    try testing.expectEqual(Row{ .line = 3 }, view.advance(&doc, .{}, 3));
    try testing.expectEqual(Row{ .line = 9 }, view.advance(&doc, .{ .line = 8 }, 5));
    try testing.expectEqual(Row{ .line = 0 }, view.advance(&doc, .{ .line = 2 }, -5));
    try testing.expectEqual(Row{ .line = 9 }, view.advance(&doc, .{ .line = 40 }, 0));
}

test "wrapped lines take several rows" {
    var doc = try testDocument("abcdefghij\n\nabcde");
    defer doc.deinit();
    var view: View = .{ .cols = 4, .rows = 3 };
    try testing.expectEqual(@as(usize, 1), view.rowsOf(&doc, 0));
    view.setWrap(true);
    try testing.expectEqual(@as(usize, 3), view.rowsOf(&doc, 0));
    try testing.expectEqual(@as(usize, 1), view.rowsOf(&doc, 1));
    try testing.expectEqual(@as(usize, 2), view.rowsOf(&doc, 2));

    try testing.expectEqual(Row{ .line = 0, .wrap = 2 }, view.rowOf(&doc, 9));
    try testing.expectEqual(Row{ .line = 0, .wrap = 2 }, view.advance(&doc, .{}, 2));
    try testing.expectEqual(Row{ .line = 2, .wrap = 0 }, view.advance(&doc, .{}, 4));
    try testing.expectEqual(Row{ .line = 0, .wrap = 2 }, view.advance(&doc, .{ .line = 1 }, -1));
    try testing.expectEqual(Row{ .line = 2, .wrap = 1 }, view.advance(&doc, .{}, 99));
}

test "the cursor stays on screen with a margin" {
    var doc = try testDocument(ten_lines);
    defer doc.deinit();
    var view: View = .{ .cols = 10, .rows = 5 };

    doc.cursor.pos = 2 * 6;
    view.scrollToCursor(&doc);
    try testing.expectEqual(@as(usize, 4), view.top.line);
    doc.cursor.pos = 2 * 9;
    view.scrollToCursor(&doc);
    try testing.expectEqual(@as(usize, 7), view.top.line);
    doc.cursor.pos = 2 * 8;
    view.scrollToCursor(&doc);
    try testing.expectEqual(@as(usize, 6), view.top.line);
    doc.cursor.pos = 0;
    view.scrollToCursor(&doc);
    try testing.expectEqual(@as(usize, 0), view.top.line);
}

test "horizontal scroll follows the cursor when wrap is off" {
    var doc = try testDocument("0123456789abcdefghijklmnopqrstuvwxyz");
    defer doc.deinit();
    var view: View = .{ .cols = 10, .rows = 5 };
    doc.cursor.pos = 20;
    view.scrollToCursor(&doc);
    try testing.expectEqual(@as(usize, 15), view.left);
    doc.cursor.pos = 16;
    view.scrollToCursor(&doc);
    try testing.expectEqual(@as(usize, 12), view.left);
    doc.cursor.pos = 0;
    view.scrollToCursor(&doc);
    try testing.expectEqual(@as(usize, 0), view.left);

    doc.cursor.pos = 30;
    view.setWrap(true);
    view.scrollToCursor(&doc);
    try testing.expectEqual(@as(usize, 0), view.left);
}

test "scrollBy moves the top row and the left column" {
    var doc = try testDocument(ten_lines);
    defer doc.deinit();
    var view: View = .{ .cols = 10, .rows = 5 };
    view.scrollBy(&doc, 3, 2);
    try testing.expectEqual(@as(usize, 3), view.top.line);
    try testing.expectEqual(@as(usize, 2), view.left);
    view.scrollBy(&doc, -9, -9);
    try testing.expectEqual(@as(usize, 0), view.top.line);
    try testing.expectEqual(@as(usize, 0), view.left);
}

test "posAt maps cells to text positions" {
    var doc = try testDocument("\tab\nlonger line\nz");
    defer doc.deinit();
    var view: View = .{ .cols = 6, .rows = 2 };
    try testing.expectEqual(@as(usize, 0), view.posAt(&doc, 2, 0));
    try testing.expectEqual(@as(usize, 2), view.posAt(&doc, 5, 0));
    try testing.expectEqual(@as(usize, 6), view.posAt(&doc, 2, 1));
    // Outside the area: the nearest cell.
    try testing.expectEqual(@as(usize, 4), view.posAt(&doc, -3, 1));
    try testing.expectEqual(@as(usize, 9), view.posAt(&doc, 40, 1));
    try testing.expectEqual(@as(usize, 16), view.posAt(&doc, 0, 9));

    view.left = 3;
    try testing.expectEqual(@as(usize, 8), view.posAt(&doc, 1, 1));

    // Wrapped: the first line fills its row, so its end is on a second row.
    view.setWrap(true);
    try testing.expectEqual(@as(usize, 3), view.posAt(&doc, 0, 1));
    try testing.expectEqual(@as(usize, 5), view.posAt(&doc, 1, 2));
    try testing.expectEqual(@as(usize, 11), view.posAt(&doc, 1, 3));
    try testing.expectEqual(@as(usize, 15), view.posAt(&doc, 5, 3));
}

test "up and down move by screen row when wrap is on" {
    var doc = try testDocument("abcdefghij\nxy\nabcdefgh");
    defer doc.deinit();
    var view: View = .{ .cols = 4, .rows = 10 };
    view.setWrap(true);
    doc.cursor.pos = 2;
    const stops = [_]usize{ 6, 10, 13, 16, 20 };
    for (stops) |stop| {
        view.moveVertical(&doc, 1, false);
        try testing.expectEqual(stop, doc.cursor.pos);
    }
    view.moveVertical(&doc, -4, true);
    try testing.expectEqual(@as(usize, 6), doc.cursor.pos);
    try testing.expectEqual(@as(?usize, 20), doc.cursor.anchor);
}

test "up and down move by line when wrap is off" {
    var doc = try testDocument("abcdefghij\nxy\nabcdefgh");
    defer doc.deinit();
    const view: View = .{ .cols = 4, .rows = 10 };
    doc.cursor.pos = 7;
    view.moveVertical(&doc, 1, false);
    try testing.expectEqual(@as(usize, 13), doc.cursor.pos);
    view.moveVertical(&doc, 1, false);
    try testing.expectEqual(@as(usize, 21), doc.cursor.pos);
}
