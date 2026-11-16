//! One running terminal: the output of its shell goes through the VT parser
//! to the grid, and keys, text and size go back to the shell. The shell is
//! behind `Port`, so this stays SDL-free and is tested with a fake one.
const std = @import("std");
const vt = @import("vt.zig");
const Grid = @import("grid.zig").Grid;
const keys = @import("keys.zig");
const KeyPress = @import("../platform/event.zig").KeyPress;

/// Where keys and the size go: the pty, or a test double.
pub const Port = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (*anyopaque, []const u8) void,
        resize: *const fn (*anyopaque, u16, u16) void,
    };

    /// A port for `T`, which has `write` and `resize` methods.
    pub fn of(comptime T: type, target: *T) Port {
        const gen = struct {
            fn write(ptr: *anyopaque, bytes: []const u8) void {
                cast(ptr).write(bytes);
            }
            fn resize(ptr: *anyopaque, cols: u16, rows: u16) void {
                cast(ptr).resize(cols, rows);
            }
            fn cast(ptr: *anyopaque) *T {
                return @ptrCast(@alignCast(ptr));
            }
            const table: VTable = .{ .write = @This().write, .resize = @This().resize };
        };
        return .{ .ptr = target, .vtable = &gen.table };
    }

    pub fn write(self: Port, bytes: []const u8) void {
        self.vtable.write(self.ptr, bytes);
    }

    pub fn resize(self: Port, cols: u16, rows: u16) void {
        self.vtable.resize(self.ptr, cols, rows);
    }
};

pub const Session = struct {
    grid: Grid,
    parser: vt.Parser = .{},
    port: Port,
    /// DECCKM: arrows send `ESC O`.
    app_cursor: bool = false,
    bracketed_paste: bool = false,
    /// The shell is gone.
    ended: bool = false,

    pub fn init(allocator: std.mem.Allocator, port: Port, cols: u16, rows: u16, scrollback: usize) !Session {
        return .{ .grid = try .init(allocator, cols, rows, scrollback), .port = port };
    }

    pub fn deinit(self: *Session) void {
        self.grid.deinit();
    }

    /// What the shell wrote.
    pub fn output(self: *Session, bytes: []const u8) void {
        self.parser.feed(bytes, Handler{ .session = self });
    }

    /// The shell exited.
    pub fn end(self: *Session) void {
        self.ended = true;
        self.output("\x1b[0m\r\n[Process ended. Enter closes it.]");
        self.grid.cursor_visible = false;
    }

    /// Sends a key that is not typed text. False when it types text (or is
    /// not a terminal key), so the text that comes with it is sent instead.
    pub fn key(self: *Session, press: KeyPress) bool {
        var buffer: [16]u8 = undefined;
        self.port.write(keys.encode(press, self.app_cursor, &buffer) orelse return false);
        return true;
    }

    pub fn typeText(self: *Session, text: []const u8) void {
        self.port.write(text);
    }

    /// Pasted lines end with Enter, as if typed. Programs that ask for it
    /// get the paste marked, so they do not run it line by line.
    pub fn paste(self: *Session, text: []const u8) void {
        if (self.bracketed_paste) self.port.write("\x1b[200~");
        var lines = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        while (lines.next()) |line| : (first = false) {
            if (!first) self.port.write("\r");
            self.port.write(std.mem.trimEnd(u8, line, "\r"));
        }
        if (self.bracketed_paste) self.port.write("\x1b[201~");
    }

    pub fn resize(self: *Session, cols: u16, rows: u16) void {
        if (cols == self.grid.cols and rows == self.grid.rows) return;
        self.grid.resize(cols, rows) catch return;
        self.port.resize(cols, rows);
    }

    fn reply(self: *Session, comptime format: []const u8, args: anytype) void {
        var buffer: [32]u8 = undefined;
        self.port.write(std.fmt.bufPrint(&buffer, format, args) catch return);
    }
};

/// What the parser calls: maps each action to the grid.
const Handler = struct {
    session: *Session,

    pub fn print(self: Handler, char: u21) void {
        self.session.grid.print(char);
    }

    pub fn control(self: Handler, byte: u8) void {
        const grid = &self.session.grid;
        switch (byte) {
            '\x08' => grid.backspace(),
            '\t' => grid.tab(),
            '\n', 0x0b, 0x0c => grid.lineFeed(),
            '\r' => grid.carriageReturn(),
            else => {},
        }
    }

    pub fn esc(self: Handler, seq: vt.Esc) void {
        const grid = &self.session.grid;
        if (seq.intermediate == '(') {
            grid.graphics = seq.final == '0';
            return;
        }
        if (seq.intermediate != 0) return;
        switch (seq.final) {
            '7' => grid.saveCursor(),
            '8' => grid.restoreCursor(),
            'D' => grid.lineFeed(),
            'E' => {
                grid.carriageReturn();
                grid.lineFeed();
            },
            'M' => grid.reverseIndex(),
            'c' => {
                grid.reset();
                self.session.app_cursor = false;
                self.session.bracketed_paste = false;
            },
            else => {},
        }
    }

    pub fn csi(self: Handler, seq: *const vt.Csi) void {
        const session = self.session;
        const grid = &session.grid;
        if (seq.intermediate != 0) return;
        if (seq.private == '?') return self.mode(seq);
        if (seq.private == '>') {
            if (seq.final == 'c') session.reply("\x1b[>0;0;0c", .{});
            return;
        }
        if (seq.private != 0) return;
        const n = seq.param(0, 1);
        const x: i32 = grid.cursor.x;
        const y: i32 = grid.cursor.y;
        switch (seq.final) {
            '@' => grid.insertChars(n),
            'A' => grid.moveBy(0, -@as(i32, n)),
            'B', 'e' => grid.moveBy(0, n),
            'C', 'a' => grid.moveBy(n, 0),
            'D' => grid.moveBy(-@as(i32, n), 0),
            'E' => grid.moveTo(0, y + n),
            'F' => grid.moveTo(0, y - n),
            'G', '`' => grid.moveTo(@as(i32, n) - 1, y),
            'H', 'f' => grid.moveTo(@as(i32, seq.param(1, 1)) - 1, @as(i32, n) - 1),
            'd' => grid.moveTo(x, @as(i32, n) - 1),
            'J' => switch (seq.param(0, 0)) {
                0 => grid.eraseScreen(.to_end),
                1 => grid.eraseScreen(.to_start),
                2 => grid.eraseScreen(.all),
                3 => grid.clearScrollback(),
                else => {},
            },
            'K' => switch (seq.param(0, 0)) {
                0 => grid.eraseLine(.to_end),
                1 => grid.eraseLine(.to_start),
                2 => grid.eraseLine(.all),
                else => {},
            },
            'L' => grid.insertLines(n),
            'M' => grid.deleteLines(n),
            'P' => grid.deleteChars(n),
            'X' => grid.eraseChars(n),
            'S' => grid.scrollUp(n),
            'T' => grid.scrollDown(n),
            'm' => grid.setStyle(seq.list()),
            'r' => grid.setRegion(seq.param(0, 0), seq.param(1, 0)),
            's' => grid.saveCursor(),
            'u' => grid.restoreCursor(),
            // Device status: OK, and where the cursor is.
            'n' => switch (seq.param(0, 0)) {
                5 => session.reply("\x1b[0n", .{}),
                6 => session.reply("\x1b[{d};{d}R", .{ y + 1, x + 1 }),
                else => {},
            },
            // Device attributes: a VT100 with advanced video.
            'c' => if (seq.param(0, 0) == 0) session.reply("\x1b[?1;2c", .{}),
            else => {},
        }
    }

    /// DEC private modes: `CSI ? n h` sets them, `l` resets them.
    fn mode(self: Handler, seq: *const vt.Csi) void {
        const session = self.session;
        const grid = &session.grid;
        const on = switch (seq.final) {
            'h' => true,
            'l' => false,
            else => return,
        };
        for (seq.list()) |number| switch (number) {
            1 => session.app_cursor = on,
            7 => grid.autowrap = on,
            25 => grid.cursor_visible = on,
            47, 1047 => grid.setAlternate(on),
            1049 => if (on) {
                grid.saveCursor();
                grid.setAlternate(true);
            } else {
                grid.setAlternate(false);
                grid.restoreCursor();
            },
            2004 => session.bracketed_paste = on,
            else => {},
        };
    }
};

const testing = std.testing;

/// Keeps what the session sends to the shell.
const FakePort = struct {
    sent: std.ArrayList(u8) = .empty,
    size: [2]u16 = .{ 0, 0 },

    fn deinit(self: *FakePort) void {
        self.sent.deinit(testing.allocator);
    }

    pub fn write(self: *FakePort, bytes: []const u8) void {
        self.sent.appendSlice(testing.allocator, bytes) catch unreachable;
    }

    pub fn resize(self: *FakePort, cols: u16, rows: u16) void {
        self.size = .{ cols, rows };
    }
};

fn expectRow(session: *const Session, row: usize, expected: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var len: usize = 0;
    const grid = &session.grid;
    for (grid.line(grid.scrollbackCount() + row)) |cell| len += std.unicode.utf8Encode(cell.char, buffer[len..]) catch unreachable;
    try testing.expectEqualStrings(expected, std.mem.trimEnd(u8, buffer[0..len], " "));
}

test "output with escape sequences draws on the grid" {
    var port: FakePort = .{};
    defer port.deinit();
    var session: Session = try .init(testing.allocator, .of(FakePort, &port), 10, 3, 100);
    defer session.deinit();

    session.output("$ ls\r\n\x1b[1;34mdir\x1b[0m  file\r\n$ ");
    try expectRow(&session, 0, "$ ls");
    try expectRow(&session, 1, "dir  file");
    try testing.expect(session.grid.line(1)[0].style.bold);
    try testing.expectEqual(@import("grid.zig").Color.index(4), session.grid.line(1)[0].style.fg);
    // Move home, erase the screen, write at row 2 column 3.
    session.output("\x1b[H\x1b[2J\x1b[2;3Hx\x1b[K");
    try expectRow(&session, 0, "");
    try expectRow(&session, 1, "  x");
}

test "programs get answers to status and attribute queries" {
    var port: FakePort = .{};
    defer port.deinit();
    var session: Session = try .init(testing.allocator, .of(FakePort, &port), 10, 3, 100);
    defer session.deinit();
    session.output("ab\x1b[6n\x1b[c\x1b[5n");
    try testing.expectEqualStrings("\x1b[1;3R\x1b[?1;2c\x1b[0n", port.sent.items);
}

test "the alternate screen, cursor keys mode and bracketed paste" {
    var port: FakePort = .{};
    defer port.deinit();
    var session: Session = try .init(testing.allocator, .of(FakePort, &port), 10, 3, 100);
    defer session.deinit();
    session.output("shell\x1b[?1049h\x1b[?1h\x1b[?2004h\x1b[Hvim");
    try testing.expect(session.grid.alternate);
    try expectRow(&session, 0, "vim");

    try testing.expect(session.key(.{ .key = .up }));
    try testing.expect(!session.key(.{ .key = .char('a') }));
    session.paste("one\r\ntwo");
    try testing.expectEqualStrings("\x1bOA\x1b[200~one\rtwo\x1b[201~", port.sent.items);

    session.output("\x1b[?1049l\x1b[?1l");
    try expectRow(&session, 0, "shell");
    try testing.expectEqual(@as(u16, 5), session.grid.cursor.x);
    port.sent.clearRetainingCapacity();
    _ = session.key(.{ .key = .up });
    try testing.expectEqualStrings("\x1b[A", port.sent.items);
}

test "resize goes to the shell; an ended shell says so" {
    var port: FakePort = .{};
    defer port.deinit();
    var session: Session = try .init(testing.allocator, .of(FakePort, &port), 10, 3, 100);
    defer session.deinit();
    session.resize(40, 12);
    try testing.expectEqual([2]u16{ 40, 12 }, port.size);
    try testing.expectEqual(@as(u16, 40), session.grid.cols);
    session.end();
    try testing.expect(session.ended);
    try expectRow(&session, 1, "[Process ended. Enter closes it.]");
}
