//! The VT/ANSI parser: a state machine after the classic DEC parser that
//! turns the bytes a program writes into actions. UTF-8 and sequences may
//! be split across reads; the state carries over. OSC, DCS and the other
//! strings are read and dropped. SDL-free.
const std = @import("std");

/// A control sequence: `ESC [`, an optional private marker, numbers split by
/// `;` (or `:`), an optional intermediate byte and the final byte.
pub const Csi = struct {
    /// `?`, `>`, `<`, `=`, or 0.
    private: u8 = 0,
    params: [max_params]u16 = @splat(0),
    count: u8 = 0,
    intermediate: u8 = 0,
    final: u8 = 0,

    pub const max_params = 16;

    /// Parameter `index`, or `default` when it is missing or 0.
    pub fn param(self: *const Csi, index: usize, default: u16) u16 {
        return if (index < self.count and self.params[index] != 0) self.params[index] else default;
    }

    pub fn list(self: *const Csi) []const u16 {
        return self.params[0..self.count];
    }
};

/// An escape sequence that is not a CSI: `ESC`, an optional intermediate
/// byte (like `(` for character sets), and the final byte.
pub const Esc = struct { intermediate: u8 = 0, final: u8 };

const State = enum { ground, escape, csi, csi_ignore, string, string_escape };

/// `feed` calls these methods of the handler:
/// `print(u21)`, `control(u8)`, `csi(*const Csi)` and `esc(Esc)`.
pub const Parser = struct {
    state: State = .ground,
    csi_seq: Csi = .{},
    esc_intermediate: u8 = 0,
    /// Bytes of a UTF-8 character that came in an earlier read.
    utf8: [4]u8 = undefined,
    utf8_len: u3 = 0,
    utf8_need: u3 = 0,

    pub fn feed(self: *Parser, bytes: []const u8, handler: anytype) void {
        for (bytes) |byte| self.step(byte, handler);
    }

    fn step(self: *Parser, byte: u8, handler: anytype) void {
        if (self.utf8_need > 0) {
            if (byte & 0xc0 == 0x80) {
                self.utf8[self.utf8_len] = byte;
                self.utf8_len += 1;
                if (self.utf8_len == self.utf8_need) {
                    self.utf8_need = 0;
                    handler.print(std.unicode.utf8Decode(self.utf8[0..self.utf8_len]) catch replacement);
                }
                return;
            }
            // Cut short: the bad bytes are one character.
            self.utf8_need = 0;
            handler.print(replacement);
        }
        // These work in every state.
        switch (byte) {
            0x18, 0x1a => return self.toGround(),
            0x1b => return if (self.state == .string) {
                self.state = .string_escape;
            } else self.enter(.escape),
            else => {},
        }
        switch (self.state) {
            .ground => self.ground(byte, handler),
            .escape => self.escape(byte, handler),
            .csi => self.csi(byte, handler),
            .csi_ignore => if (byte >= 0x40 and byte <= 0x7e) self.toGround() else if (byte < 0x20) handler.control(byte),
            // BEL ends an OSC string, as xterm allows.
            .string => if (byte == 0x07) self.toGround(),
            // `ESC \` ends a string; anything else starts a new sequence.
            .string_escape => if (byte == '\\') self.toGround() else {
                self.enter(.escape);
                self.escape(byte, handler);
            },
        }
    }

    const replacement = 0xfffd;

    fn ground(self: *Parser, byte: u8, handler: anytype) void {
        switch (byte) {
            0...0x1f => handler.control(byte),
            0x20...0x7e => handler.print(byte),
            0x7f => {},
            0xc2...0xf4 => {
                self.utf8[0] = byte;
                self.utf8_len = 1;
                self.utf8_need = std.unicode.utf8ByteSequenceLength(byte) catch unreachable;
            },
            else => handler.print(replacement),
        }
    }

    fn escape(self: *Parser, byte: u8, handler: anytype) void {
        switch (byte) {
            0...0x1f => handler.control(byte),
            0x20...0x2f => self.esc_intermediate = byte,
            '[' => if (self.esc_intermediate == 0) self.enter(.csi) else self.endEsc(byte, handler),
            // OSC, DCS, SOS, PM and APC strings.
            ']', 'P', 'X', '^', '_' => if (self.esc_intermediate == 0) self.enter(.string) else self.endEsc(byte, handler),
            else => self.endEsc(byte, handler),
        }
    }

    fn endEsc(self: *Parser, byte: u8, handler: anytype) void {
        handler.esc(.{ .intermediate = self.esc_intermediate, .final = byte });
        self.toGround();
    }

    fn csi(self: *Parser, byte: u8, handler: anytype) void {
        const seq = &self.csi_seq;
        switch (byte) {
            0...0x1f => handler.control(byte),
            '0'...'9' => {
                if (seq.count == 0) seq.count = 1;
                const at = &seq.params[seq.count - 1];
                at.* = at.* *| 10 +| (byte - '0');
            },
            ';', ':' => {
                if (seq.count == 0) seq.count = 1;
                if (seq.count == Csi.max_params) return self.enter(.csi_ignore);
                seq.count += 1;
            },
            '?', '>', '<', '=' => if (seq.count == 0 and seq.private == 0) {
                seq.private = byte;
            } else self.enter(.csi_ignore),
            0x20...0x2f => seq.intermediate = byte,
            0x40...0x7e => {
                seq.final = byte;
                handler.csi(seq);
                self.toGround();
            },
            else => self.enter(.csi_ignore),
        }
    }

    fn enter(self: *Parser, state: State) void {
        self.state = state;
        self.csi_seq = .{};
        self.esc_intermediate = 0;
    }

    fn toGround(self: *Parser) void {
        self.state = .ground;
    }
};

const testing = std.testing;

/// Writes every action as text, to compare with what is expected.
const Recorder = struct {
    out: std.ArrayList(u8) = .empty,

    fn deinit(self: *Recorder) void {
        self.out.deinit(testing.allocator);
    }

    fn add(self: *Recorder, comptime format: []const u8, args: anytype) void {
        self.out.print(testing.allocator, format, args) catch unreachable;
    }

    pub fn print(self: *Recorder, char: u21) void {
        self.add("{u}", .{char});
    }
    pub fn control(self: *Recorder, byte: u8) void {
        self.add("<{d}>", .{byte});
    }
    pub fn csi(self: *Recorder, seq: *const Csi) void {
        self.add("[{c}{any}{c}{c}]", .{ if (seq.private == 0) ' ' else seq.private, seq.list(), if (seq.intermediate == 0) ' ' else seq.intermediate, seq.final });
    }
    pub fn esc(self: *Recorder, seq: Esc) void {
        self.add("(esc {c}{c})", .{ if (seq.intermediate == 0) ' ' else seq.intermediate, seq.final });
    }
};

fn expectParsed(reads: []const []const u8, expected: []const u8) !void {
    var parser: Parser = .{};
    var recorder: Recorder = .{};
    defer recorder.deinit();
    for (reads) |bytes| parser.feed(bytes, &recorder);
    try testing.expectEqualStrings(expected, recorder.out.items);
}

test "text, controls and UTF-8" {
    try expectParsed(&.{"a\r\n\tb\x07"}, "a<13><10><9>b<7>");
    try expectParsed(&.{"ñ€😀"}, "ñ€😀");
    // A bad byte, and a character cut short, are one replacement each.
    try expectParsed(&.{ "\xff", "\xe2\x82x" }, "\u{fffd}\u{fffd}x");
}

test "UTF-8 split across reads" {
    try expectParsed(&.{ "\xe2", "\x82", "\xac!" }, "€!");
    try expectParsed(&.{ "\xf0\x9f", "\x98\x80" }, "😀");
}

test "CSI with parameters, private marker and intermediate" {
    try expectParsed(&.{"\x1b[1;31m\x1b[H\x1b[?1049h\x1b[2 q"}, "[ { 1, 31 } m][ {  } H][?{ 1049 } h][ { 2 } q]");
    // A missing parameter is 0.
    try expectParsed(&.{"\x1b[;5H"}, "[ { 0, 5 } H]");
    // Split across reads.
    try expectParsed(&.{ "\x1b", "[3", "8;2;1;2;3", "m" }, "[ { 38, 2, 1, 2, 3 } m]");
    // Controls inside a sequence still work.
    try expectParsed(&.{"\x1b[1\r2C"}, "<13>[ { 12 } C]");
}

test "param falls back to a default" {
    var seq: Csi = .{ .count = 2, .params = .{ 0, 7 } ++ @as([14]u16, @splat(0)) };
    try testing.expectEqual(@as(u16, 1), seq.param(0, 1));
    try testing.expectEqual(@as(u16, 7), seq.param(1, 1));
    try testing.expectEqual(@as(u16, 1), seq.param(5, 1));
}

test "ESC sequences; strings ended by BEL or ST are dropped" {
    try expectParsed(&.{"\x1b7\x1b(0\x1bM"}, "(esc  7)(esc (0)(esc  M)");
    try expectParsed(&.{"\x1b]0;my title\x07x"}, "x");
    try expectParsed(&.{ "\x1b]2;a", "b\x1b\\y" }, "y");
    try expectParsed(&.{"\x1bPq#0;1\x1b\\z"}, "z");
    // CAN stops a sequence.
    try expectParsed(&.{"\x1b[12\x18a"}, "a");
}
