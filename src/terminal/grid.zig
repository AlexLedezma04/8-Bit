//! The screen of a terminal: cells with their character and style, the
//! cursor, the scroll region, the alternate screen and the scrollback. Only
//! what the screen does; `terminal.zig` maps escape sequences to it.
//! SDL-free.
const std = @import("std");

/// A terminal color: the default one, one of the 256 colors, or true color.
pub const Color = packed struct(u32) {
    kind: Kind,
    value: u24 = 0,

    pub const Kind = enum(u8) { default, index, rgb };
    pub const default: Color = .{ .kind = .default };

    pub fn index(n: u8) Color {
        return .{ .kind = .index, .value = n };
    }

    pub fn rgb(hex: u24) Color {
        return .{ .kind = .rgb, .value = hex };
    }
};

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    underline: bool = false,
    inverse: bool = false,
};

pub const Cell = struct {
    char: u21 = ' ',
    style: Style = .{},
};

pub const Point = struct { x: u16 = 0, y: u16 = 0 };

/// Lines that scrolled off the top, oldest first, at most `max`. Each line
/// keeps its own width and no blank cells at its end.
const Scrollback = struct {
    lines: std.ArrayList([]Cell) = .empty,
    /// Where the oldest line is, once the ring is full.
    start: usize = 0,
    max: usize,

    fn deinit(self: *Scrollback, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.lines.deinit(allocator);
    }

    fn clear(self: *Scrollback, allocator: std.mem.Allocator) void {
        for (self.lines.items) |kept| allocator.free(kept);
        self.lines.clearRetainingCapacity();
        self.start = 0;
    }

    /// Takes `line`.
    fn push(self: *Scrollback, allocator: std.mem.Allocator, line: []Cell) void {
        var end = line.len;
        while (end > 0 and std.meta.eql(line[end - 1], Cell{})) end -= 1;
        const kept = allocator.realloc(line, end) catch line;
        if (self.lines.items.len < self.max) {
            self.lines.append(allocator, kept) catch allocator.free(kept);
            return;
        }
        if (self.max == 0) return allocator.free(kept);
        allocator.free(self.lines.items[self.start]);
        self.lines.items[self.start] = kept;
        self.start = (self.start + 1) % self.max;
    }

    /// Gives back the newest line; the caller frees it.
    fn pop(self: *Scrollback) []Cell {
        std.mem.rotate([]Cell, self.lines.items, self.start);
        self.start = 0;
        return self.lines.pop().?;
    }

    fn count(self: *const Scrollback) usize {
        return self.lines.items.len;
    }

    fn get(self: *const Scrollback, index: usize) []const Cell {
        return self.lines.items[(self.start + index) % self.lines.items.len];
    }
};

/// What DECSC saves and DECRC restores.
const Saved = struct { cursor: Point = .{}, style: Style = .{}, graphics: bool = false };

pub const Grid = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    /// The screen shown, and the other one (primary or alternate).
    lines: [][]Cell,
    other: [][]Cell,
    alternate: bool = false,
    scrollback: Scrollback,
    cursor: Point = .{},
    /// The cursor is past the last column; the next character wraps.
    wrap_pending: bool = false,
    /// The style new characters get.
    style: Style = .{},
    /// The scroll region: rows `top` up to, not including, `bottom`.
    top: u16 = 0,
    bottom: u16,
    saved: Saved = .{},
    autowrap: bool = true,
    cursor_visible: bool = true,
    /// DEC line drawing replaces letters with box lines.
    graphics: bool = false,

    pub const tab_width = 8;

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16, scrollback: usize) !Grid {
        const lines = try blankScreen(allocator, cols, rows);
        errdefer freeScreen(allocator, lines);
        return .{
            .allocator = allocator,
            .cols = cols,
            .rows = rows,
            .lines = lines,
            .other = try blankScreen(allocator, cols, rows),
            .scrollback = .{ .max = scrollback },
            .bottom = rows,
        };
    }

    pub fn deinit(self: *Grid) void {
        freeScreen(self.allocator, self.lines);
        freeScreen(self.allocator, self.other);
        self.scrollback.deinit(self.allocator);
    }

    fn blankScreen(allocator: std.mem.Allocator, cols: u16, rows: u16) ![][]Cell {
        const lines = try allocator.alloc([]Cell, rows);
        var made: usize = 0;
        errdefer freeScreen(allocator, lines[0..made]);
        while (made < rows) : (made += 1) {
            lines[made] = try allocator.alloc(Cell, cols);
            @memset(lines[made], .{});
        }
        return lines;
    }

    fn freeScreen(allocator: std.mem.Allocator, lines: [][]Cell) void {
        for (lines) |row| allocator.free(row);
        allocator.free(lines);
    }

    /// An empty cell in the current background color.
    fn blank(self: *const Grid) Cell {
        return .{ .style = .{ .bg = self.style.bg } };
    }

    // Reading

    /// Lines that can be shown: the scrollback (not on the alternate
    /// screen), then the screen.
    pub fn lineCount(self: *const Grid) usize {
        return self.scrollbackCount() + self.rows;
    }

    pub fn scrollbackCount(self: *const Grid) usize {
        return if (self.alternate) 0 else self.scrollback.count();
    }

    /// Line `index` of `lineCount`. Scrollback lines can be shorter than
    /// the screen.
    pub fn line(self: *const Grid, index: usize) []const Cell {
        const back = self.scrollbackCount();
        return if (index < back) self.scrollback.get(index) else self.lines[index - back];
    }

    // Writing

    pub fn print(self: *Grid, char: u21) void {
        if (self.wrap_pending) {
            self.carriageReturn();
            self.lineFeed();
        }
        const shown = if (self.graphics) lineDrawing(char) else char;
        self.lines[self.cursor.y][self.cursor.x] = .{ .char = shown, .style = self.style };
        if (self.cursor.x + 1 < self.cols) {
            self.cursor.x += 1;
        } else if (self.autowrap) {
            self.wrap_pending = true;
        }
    }

    /// DEC special graphics, as programs draw boxes with it.
    fn lineDrawing(char: u21) u21 {
        return switch (char) {
            'j' => '┘',
            'k' => '┐',
            'l' => '┌',
            'm' => '└',
            'n' => '┼',
            'q' => '─',
            't' => '├',
            'u' => '┤',
            'v' => '┴',
            'w' => '┬',
            'x' => '│',
            'a' => '▒',
            '~' => '·',
            else => char,
        };
    }

    pub fn carriageReturn(self: *Grid) void {
        self.cursor.x = 0;
        self.wrap_pending = false;
    }

    /// Down one row; at the bottom of the scroll region the region scrolls.
    pub fn lineFeed(self: *Grid) void {
        self.wrap_pending = false;
        if (self.cursor.y + 1 == self.bottom) {
            self.scroll(self.top, self.bottom, 1, true, true);
        } else if (self.cursor.y + 1 < self.rows) {
            self.cursor.y += 1;
        }
    }

    /// Up one row; at the top of the scroll region the region scrolls down.
    pub fn reverseIndex(self: *Grid) void {
        self.wrap_pending = false;
        if (self.cursor.y == self.top) {
            self.scroll(self.top, self.bottom, 1, false, false);
        } else if (self.cursor.y > 0) {
            self.cursor.y -= 1;
        }
    }

    pub fn backspace(self: *Grid) void {
        self.wrap_pending = false;
        self.cursor.x -|= 1;
    }

    pub fn tab(self: *Grid) void {
        self.cursor.x = @min(self.cols - 1, (self.cursor.x / tab_width + 1) * tab_width);
    }

    /// Moves the cursor, kept on the screen.
    pub fn moveTo(self: *Grid, x: i32, y: i32) void {
        self.wrap_pending = false;
        self.cursor = .{
            .x = @intCast(std.math.clamp(x, 0, @as(i32, self.cols) - 1)),
            .y = @intCast(std.math.clamp(y, 0, @as(i32, self.rows) - 1)),
        };
    }

    pub fn moveBy(self: *Grid, dx: i32, dy: i32) void {
        self.moveTo(@as(i32, self.cursor.x) + dx, @as(i32, self.cursor.y) + dy);
    }

    /// Moves rows `first` up to `end` by `n`: up, or down. Rows that come in
    /// are blank. With `keep`, rows that leave the top of the primary screen
    /// go to the scrollback.
    fn scroll(self: *Grid, first: u16, end: u16, n: u16, up: bool, keep_lines: bool) void {
        const region = self.lines[first..end];
        const count = @min(n, region.len);
        const keep = keep_lines and first == 0 and !self.alternate;
        for (0..count) |_| {
            if (up) {
                var gone = region[0];
                std.mem.copyForwards([]Cell, region[0 .. region.len - 1], region[1..]);
                if (keep) if (self.allocator.alloc(Cell, self.cols)) |fresh| {
                    self.scrollback.push(self.allocator, gone);
                    gone = fresh;
                } else |_| {};
                @memset(gone, self.blank());
                region[region.len - 1] = gone;
            } else {
                const gone = region[region.len - 1];
                std.mem.copyBackwards([]Cell, region[1..], region[0 .. region.len - 1]);
                @memset(gone, self.blank());
                region[0] = gone;
            }
        }
    }

    pub fn scrollUp(self: *Grid, n: u16) void {
        self.scroll(self.top, self.bottom, n, true, true);
    }

    pub fn scrollDown(self: *Grid, n: u16) void {
        self.scroll(self.top, self.bottom, n, false, false);
    }

    /// Inserts blank lines at the cursor, inside the scroll region.
    pub fn insertLines(self: *Grid, n: u16) void {
        if (self.cursor.y < self.top or self.cursor.y >= self.bottom) return;
        self.scroll(self.cursor.y, self.bottom, n, false, false);
        self.carriageReturn();
    }

    pub fn deleteLines(self: *Grid, n: u16) void {
        if (self.cursor.y < self.top or self.cursor.y >= self.bottom) return;
        self.scroll(self.cursor.y, self.bottom, n, true, false);
        self.carriageReturn();
    }

    /// Inserts blank cells at the cursor; the rest of the line moves right.
    pub fn insertChars(self: *Grid, n: u16) void {
        const row = self.lines[self.cursor.y][self.cursor.x..];
        const count = @min(n, row.len);
        std.mem.copyBackwards(Cell, row[count..], row[0 .. row.len - count]);
        @memset(row[0..count], self.blank());
        self.wrap_pending = false;
    }

    /// Deletes cells at the cursor; the rest of the line moves left.
    pub fn deleteChars(self: *Grid, n: u16) void {
        const row = self.lines[self.cursor.y][self.cursor.x..];
        const count = @min(n, row.len);
        std.mem.copyForwards(Cell, row[0 .. row.len - count], row[count..]);
        @memset(row[row.len - count ..], self.blank());
        self.wrap_pending = false;
    }

    /// Blanks `n` cells from the cursor.
    pub fn eraseChars(self: *Grid, n: u16) void {
        const row = self.lines[self.cursor.y][self.cursor.x..];
        @memset(row[0..@min(n, row.len)], self.blank());
        self.wrap_pending = false;
    }

    pub const Erase = enum { to_end, to_start, all };

    pub fn eraseLine(self: *Grid, how: Erase) void {
        const row = self.lines[self.cursor.y];
        const x = self.cursor.x;
        @memset(switch (how) {
            .to_end => row[x..],
            .to_start => row[0 .. x + 1],
            .all => row,
        }, self.blank());
        self.wrap_pending = false;
    }

    pub fn eraseScreen(self: *Grid, how: Erase) void {
        const y = self.cursor.y;
        const rows = switch (how) {
            .to_end => self.lines[y + 1 ..],
            .to_start => self.lines[0..y],
            .all => self.lines,
        };
        for (rows) |row| @memset(row, self.blank());
        if (how != .all) self.eraseLine(how);
    }

    pub fn clearScrollback(self: *Grid) void {
        self.scrollback.clear(self.allocator);
    }

    /// The scroll region, from one-based rows as DECSTBM sends them; 0 is
    /// the edge of the screen. The cursor goes home.
    pub fn setRegion(self: *Grid, top: u16, bottom: u16) void {
        const first = @max(top, 1) - 1;
        const end = if (bottom == 0) self.rows else @min(bottom, self.rows);
        if (first + 1 >= end) return;
        self.top = first;
        self.bottom = end;
        self.moveTo(0, 0);
    }

    pub fn saveCursor(self: *Grid) void {
        self.saved = .{ .cursor = self.cursor, .style = self.style, .graphics = self.graphics };
    }

    pub fn restoreCursor(self: *Grid) void {
        self.style = self.saved.style;
        self.graphics = self.saved.graphics;
        self.moveTo(self.saved.cursor.x, self.saved.cursor.y);
    }

    /// Switches to the alternate screen, which starts blank, or back.
    pub fn setAlternate(self: *Grid, on: bool) void {
        if (on == self.alternate) return;
        std.mem.swap([][]Cell, &self.lines, &self.other);
        self.alternate = on;
        if (on) for (self.lines) |row| @memset(row, .{});
    }

    /// SGR: the style of the next characters. 16, 256 and true color.
    pub fn setStyle(self: *Grid, params: []const u16) void {
        if (params.len == 0) {
            self.style = .{};
            return;
        }
        var i: usize = 0;
        while (i < params.len) : (i += 1) {
            const p = params[i];
            switch (p) {
                0 => self.style = .{},
                1 => self.style.bold = true,
                4 => self.style.underline = true,
                7 => self.style.inverse = true,
                22 => self.style.bold = false,
                24 => self.style.underline = false,
                27 => self.style.inverse = false,
                30...37 => self.style.fg = .index(@intCast(p - 30)),
                39 => self.style.fg = .default,
                40...47 => self.style.bg = .index(@intCast(p - 40)),
                49 => self.style.bg = .default,
                90...97 => self.style.fg = .index(@intCast(p - 90 + 8)),
                100...107 => self.style.bg = .index(@intCast(p - 100 + 8)),
                38, 48 => {
                    const color, const used = extendedColor(params[i + 1 ..]) orelse return;
                    if (p == 38) self.style.fg = color else self.style.bg = color;
                    i += used;
                },
                else => {},
            }
        }
    }

    /// `5;n` or `2;r;g;b`, and how many parameters it took.
    fn extendedColor(rest: []const u16) ?struct { Color, usize } {
        if (rest.len >= 2 and rest[0] == 5) return .{ .index(@truncate(rest[1])), 2 };
        if (rest.len >= 4 and rest[0] == 2) {
            const r: u24 = @as(u8, @truncate(rest[1]));
            const g: u24 = @as(u8, @truncate(rest[2]));
            const b: u24 = @as(u8, @truncate(rest[3]));
            return .{ .rgb(r << 16 | g << 8 | b), 4 };
        }
        return null;
    }

    /// Back to how a new terminal starts. The scrollback stays.
    pub fn reset(self: *Grid) void {
        self.setAlternate(false);
        self.style = .{};
        for (self.lines) |row| @memset(row, .{});
        self.* = .{
            .allocator = self.allocator,
            .cols = self.cols,
            .rows = self.rows,
            .lines = self.lines,
            .other = self.other,
            .scrollback = self.scrollback,
            .bottom = self.rows,
        };
    }

    /// A new size. Lines keep their content and are cut or padded; nothing
    /// reflows. When rows go, the ones above the cursor go to the scrollback,
    /// so the cursor line stays; when rows come, lines come back from it.
    pub fn resize(self: *Grid, cols: u16, rows: u16) !void {
        if (cols == self.cols and rows == self.rows) return;
        const pull: u16 = if (self.alternate) 0 else @intCast(@min(rows -| self.rows, self.scrollback.count()));
        const shift = (self.cursor.y + 1) -| rows;
        const lines = try self.resizeScreen(self.lines, cols, rows, shift, !self.alternate);
        self.other = self.resizeScreen(self.other, cols, rows, 0, false) catch |err| {
            freeScreen(self.allocator, lines);
            return err;
        };
        self.lines = lines;
        self.cols = cols;
        self.rows = rows;
        self.top = 0;
        self.bottom = rows;
        for (0..pull) |_| {
            self.scroll(0, rows, 1, false, false);
            const back = self.scrollback.pop();
            defer self.allocator.free(back);
            @memset(self.lines[0], .{});
            const width = @min(cols, back.len);
            @memcpy(self.lines[0][0..width], back[0..width]);
        }
        self.cursor.y = self.cursor.y - shift + pull;
        self.moveTo(self.cursor.x, self.cursor.y);
        self.saved.cursor = .{ .x = @min(self.saved.cursor.x, cols - 1), .y = @min(self.saved.cursor.y + pull, rows - 1) };
    }

    /// Frees `old` once the new screen is made; `shift` top lines leave first.
    fn resizeScreen(self: *Grid, old: [][]Cell, cols: u16, rows: u16, shift: usize, keep: bool) ![][]Cell {
        const lines = try self.allocator.alloc([]Cell, rows);
        errdefer self.allocator.free(lines);
        // Make every new line first, so a failure changes nothing.
        var made: usize = 0;
        errdefer for (lines[0..made]) |row| self.allocator.free(row);
        while (made < rows) : (made += 1) {
            lines[made] = try self.allocator.alloc(Cell, cols);
            @memset(lines[made], .{});
            if (shift + made < old.len) {
                const from = old[shift + made];
                const width = @min(cols, from.len);
                @memcpy(lines[made][0..width], from[0..width]);
            }
        }
        for (old, 0..) |row, i| {
            if (keep and i < shift) self.scrollback.push(self.allocator, row) else self.allocator.free(row);
        }
        self.allocator.free(old);
        return lines;
    }
};

const testing = std.testing;

fn testGrid(cols: u16, rows: u16) !Grid {
    return .init(testing.allocator, cols, rows, 100);
}

fn printAll(grid: *Grid, text: []const u8) void {
    const view = std.unicode.Utf8View.initUnchecked(text);
    var chars = view.iterator();
    while (chars.nextCodepoint()) |char| switch (char) {
        '\n' => {
            grid.carriageReturn();
            grid.lineFeed();
        },
        else => grid.print(char),
    };
}

/// The characters of line `index`, without blanks at the end.
fn expectLine(grid: *const Grid, index: usize, expected: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var len: usize = 0;
    for (grid.line(index)) |cell| len += std.unicode.utf8Encode(cell.char, buffer[len..]) catch unreachable;
    try testing.expectEqualStrings(expected, std.mem.trimEnd(u8, buffer[0..len], " "));
}

test "printing wraps at the last column and scrolls into the scrollback" {
    var grid = try testGrid(4, 2);
    defer grid.deinit();
    printAll(&grid, "abcd");
    // The cursor waits at the last column until the next character.
    try testing.expectEqual(Point{ .x = 3, .y = 0 }, grid.cursor);
    printAll(&grid, "ef\ngh");
    try testing.expectEqual(@as(usize, 1), grid.scrollbackCount());
    try expectLine(&grid, 0, "abcd");
    try expectLine(&grid, 1, "ef");
    try expectLine(&grid, 2, "gh");
}

test "the scrollback is a ring of its size" {
    var grid: Grid = try .init(testing.allocator, 3, 1, 2);
    defer grid.deinit();
    printAll(&grid, "1\n2\n3\n4");
    try testing.expectEqual(@as(usize, 2), grid.scrollbackCount());
    try expectLine(&grid, 0, "2");
    try expectLine(&grid, 1, "3");
    try expectLine(&grid, 2, "4");
    // Blank cells at the end are not kept.
    try testing.expectEqual(@as(usize, 1), grid.line(0).len);
    grid.clearScrollback();
    try testing.expectEqual(@as(usize, 0), grid.scrollbackCount());
}

test "erase line and screen" {
    var grid = try testGrid(5, 3);
    defer grid.deinit();
    printAll(&grid, "abcde\nfghij\nklmno");
    grid.moveTo(2, 1);
    grid.eraseLine(.to_end);
    try expectLine(&grid, 1, "fg");
    grid.eraseLine(.to_start);
    try expectLine(&grid, 1, "");
    grid.moveTo(1, 2);
    grid.eraseScreen(.to_start);
    try expectLine(&grid, 0, "");
    try expectLine(&grid, 2, "  mno");
    grid.eraseScreen(.all);
    try expectLine(&grid, 2, "");
}

test "the scroll region scrolls alone and keeps the scrollback out" {
    var grid = try testGrid(3, 4);
    defer grid.deinit();
    printAll(&grid, "a\nb\nc\nd");
    grid.setRegion(2, 3);
    try testing.expectEqual(Point{}, grid.cursor);
    grid.moveTo(0, 2);
    grid.lineFeed();
    try expectLine(&grid, 0, "a");
    try expectLine(&grid, 1, "c");
    try expectLine(&grid, 2, "");
    try expectLine(&grid, 3, "d");
    try testing.expectEqual(@as(usize, 0), grid.scrollbackCount());
    grid.moveTo(0, 1);
    grid.reverseIndex();
    try expectLine(&grid, 1, "");
    try expectLine(&grid, 2, "c");
}

test "insert and delete lines and characters" {
    var grid = try testGrid(5, 3);
    defer grid.deinit();
    printAll(&grid, "abcde\nfghij\nklmno");
    grid.moveTo(1, 0);
    grid.deleteChars(2);
    try expectLine(&grid, 0, "ade");
    grid.insertChars(1);
    try expectLine(&grid, 0, "a de");
    grid.eraseChars(2);
    try expectLine(&grid, 0, "a  e");
    grid.moveTo(0, 1);
    grid.insertLines(1);
    try expectLine(&grid, 1, "");
    try expectLine(&grid, 2, "fghij");
    grid.deleteLines(1);
    try expectLine(&grid, 1, "fghij");
    try expectLine(&grid, 2, "");
}

test "colors: 16, 256 and true color, bold and inverse" {
    var grid = try testGrid(4, 1);
    defer grid.deinit();
    grid.setStyle(&.{ 1, 31, 44 });
    try testing.expectEqual(Style{ .fg = .index(1), .bg = .index(4), .bold = true }, grid.style);
    grid.setStyle(&.{ 38, 5, 208, 48, 2, 1, 2, 3, 7 });
    try testing.expectEqual(Style{ .fg = .index(208), .bg = .rgb(0x010203), .bold = true, .inverse = true }, grid.style);
    grid.setStyle(&.{ 22, 27, 97, 49 });
    try testing.expectEqual(Style{ .fg = .index(15) }, grid.style);
    grid.print('x');
    try testing.expectEqual(Color.index(15), grid.line(0)[0].style.fg);
    grid.setStyle(&.{});
    try testing.expectEqual(Style{}, grid.style);
}

test "the alternate screen starts blank and the primary one comes back" {
    var grid = try testGrid(4, 2);
    defer grid.deinit();
    printAll(&grid, "a\nb\nc");
    grid.setAlternate(true);
    try testing.expectEqual(@as(usize, 0), grid.scrollbackCount());
    try expectLine(&grid, 0, "");
    printAll(&grid, "vim\n~\n~");
    // Nothing of the alternate screen goes to the scrollback.
    grid.setAlternate(false);
    try testing.expectEqual(@as(usize, 1), grid.scrollbackCount());
    try expectLine(&grid, 1, "b");
    try expectLine(&grid, 2, "c");
}

test "resize keeps the content and the cursor line" {
    var grid = try testGrid(4, 3);
    defer grid.deinit();
    printAll(&grid, "abcd\nef\ngh");
    try grid.resize(2, 2);
    try testing.expectEqual(@as(usize, 1), grid.scrollbackCount());
    try expectLine(&grid, 0, "abcd");
    try expectLine(&grid, 1, "ef");
    try expectLine(&grid, 2, "gh");
    try testing.expectEqual(Point{ .x = 1, .y = 1 }, grid.cursor);
    try grid.resize(6, 3);
    // The line that went comes back.
    try testing.expectEqual(@as(usize, 0), grid.scrollbackCount());
    try expectLine(&grid, 0, "abcd");
    try expectLine(&grid, 2, "gh");
    try testing.expectEqual(Point{ .x = 1, .y = 2 }, grid.cursor);
    try testing.expectEqual(@as(usize, 6), grid.lines[0].len);
    try grid.resize(6, 4);
    try expectLine(&grid, 3, "");
}

test "a full scrollback gives its newest lines back first" {
    var grid: Grid = try .init(testing.allocator, 3, 1, 2);
    defer grid.deinit();
    printAll(&grid, "1\n2\n3\n4");
    try grid.resize(3, 2);
    try expectLine(&grid, 0, "2");
    try expectLine(&grid, 1, "3");
    try expectLine(&grid, 2, "4");
    printAll(&grid, "\n5\n6");
    try expectLine(&grid, 0, "3");
    try expectLine(&grid, 1, "4");
}

test "save and restore the cursor, tabs, line drawing, reset" {
    var grid = try testGrid(20, 2);
    defer grid.deinit();
    grid.moveTo(3, 1);
    grid.setStyle(&.{31});
    grid.saveCursor();
    grid.moveTo(0, 0);
    grid.setStyle(&.{0});
    grid.restoreCursor();
    try testing.expectEqual(Point{ .x = 3, .y = 1 }, grid.cursor);
    try testing.expectEqual(Color.index(1), grid.style.fg);
    grid.tab();
    try testing.expectEqual(@as(u16, 8), grid.cursor.x);
    grid.graphics = true;
    printAll(&grid, "lqk");
    try expectLine(&grid, 1, "        ┌─┐");
    grid.reset();
    try testing.expectEqual(Point{}, grid.cursor);
    try testing.expect(!grid.graphics);
    try expectLine(&grid, 1, "");
}
