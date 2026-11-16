//! Line endings of a file: LF or CRLF.
const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;

pub const LineEnding = enum {
    lf,
    crlf,

    pub fn text(self: LineEnding) []const u8 {
        return switch (self) {
            .lf => "\n",
            .crlf => "\r\n",
        };
    }

    pub fn name(self: LineEnding) []const u8 {
        return switch (self) {
            .lf => "LF",
            .crlf => "CRLF",
        };
    }

    /// The ending of the first line; LF when the text has one line.
    pub fn detect(buffer: *const Buffer) LineEnding {
        if (buffer.lineCount() == 1) return .lf;
        const newline = buffer.lineStart(1) - 1;
        return if (newline > 0 and buffer.byteAt(newline - 1) == '\r') .crlf else .lf;
    }

    /// Copy of `source` with every LF, CRLF and lone CR changed to this ending.
    pub fn normalize(self: LineEnding, allocator: std.mem.Allocator, source: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.ensureTotalCapacity(allocator, source.len);
        var i: usize = 0;
        while (i < source.len) : (i += 1) {
            const byte = source[i];
            if (byte != '\r' and byte != '\n') {
                try out.append(allocator, byte);
                continue;
            }
            if (byte == '\r' and i + 1 < source.len and source[i + 1] == '\n') i += 1;
            try out.appendSlice(allocator, self.text());
        }
        return out.toOwnedSlice(allocator);
    }
};

const testing = std.testing;

test "detect uses the first line break" {
    var buffer = Buffer.init(testing.allocator);
    defer buffer.deinit();
    try testing.expectEqual(LineEnding.lf, LineEnding.detect(&buffer));
    try buffer.load("a\nb\r\n");
    try testing.expectEqual(LineEnding.lf, LineEnding.detect(&buffer));
    try buffer.load("a\r\nb\n");
    try testing.expectEqual(LineEnding.crlf, LineEnding.detect(&buffer));
    try buffer.load("\nb");
    try testing.expectEqual(LineEnding.lf, LineEnding.detect(&buffer));
}

test "normalize changes every kind of line break" {
    const mixed = "a\nb\r\nc\rd\r";
    const lf = try LineEnding.lf.normalize(testing.allocator, mixed);
    defer testing.allocator.free(lf);
    try testing.expectEqualStrings("a\nb\nc\nd\n", lf);
    const crlf = try LineEnding.crlf.normalize(testing.allocator, mixed);
    defer testing.allocator.free(crlf);
    try testing.expectEqualStrings("a\r\nb\r\nc\r\nd\r\n", crlf);
}
