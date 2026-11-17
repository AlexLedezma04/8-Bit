//! Reads the PNG files the app ships: 8-bit RGBA, not interlaced. No SDL.
const std = @import("std");

pub const Image = struct {
    width: u32,
    height: u32,
    /// RGBA, rows top to bottom.
    pixels: []u8,

    pub fn deinit(self: Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    /// The image at `w` by `h` pixels, each the average of the pixels it
    /// covers, weighted by alpha so transparent ones add no color.
    pub fn shrink(self: Image, allocator: std.mem.Allocator, w: u32, h: u32) !Image {
        const pixels = try allocator.alloc(u8, @as(usize, w) * h * 4);
        for (0..h) |y| for (0..w) |x| {
            const x0 = x * self.width / w;
            const y0 = y * self.height / h;
            const x1 = @max(x0 + 1, (x + 1) * self.width / w);
            const y1 = @max(y0 + 1, (y + 1) * self.height / h);
            var sum: [4]u64 = @splat(0);
            for (y0..y1) |sy| for (x0..x1) |sx| {
                const pixel = self.pixels[(sy * self.width + sx) * 4 ..][0..4];
                for (0..3) |i| sum[i] += @as(u64, pixel[i]) * pixel[3];
                sum[3] += pixel[3];
            };
            const out = pixels[(y * w + x) * 4 ..][0..4];
            for (0..3) |i| out[i] = if (sum[3] == 0) 0 else @intCast(sum[i] / sum[3]);
            out[3] = @intCast(sum[3] / ((x1 - x0) * (y1 - y0)));
        };
        return .{ .width = w, .height = h, .pixels = pixels };
    }
};

const signature = "\x89PNG\r\n\x1a\n";

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Image {
    if (!std.mem.startsWith(u8, bytes, signature)) return error.NotPng;
    var width: u32 = 0;
    var height: u32 = 0;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(allocator);
    var at: usize = signature.len;
    while (at + 12 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[at..][0..4], .big);
        const kind = bytes[at + 4 ..][0..4];
        const body = bytes[at + 8 ..][0..len];
        at += 12 + len;
        if (std.mem.eql(u8, kind, "IHDR")) {
            width = std.mem.readInt(u32, body[0..4], .big);
            height = std.mem.readInt(u32, body[4..8], .big);
            // Depth 8, RGBA, no interlace.
            if (body[8] != 8 or body[9] != 6 or body[12] != 0) return error.Unsupported;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try data.appendSlice(allocator, body);
        } else if (std.mem.eql(u8, kind, "IEND")) break;
    }
    const stride = @as(usize, width) * 4;
    // Each row starts with its filter byte.
    const raw = try allocator.alloc(u8, (stride + 1) * height);
    defer allocator.free(raw);
    var input: std.Io.Reader = .fixed(data.items);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = .init(&input, .zlib, &window);
    try inflate.reader.readSliceAll(raw);

    const pixels = try allocator.alloc(u8, stride * height);
    errdefer allocator.free(pixels);
    for (0..height) |y| {
        const filter = raw[y * (stride + 1)];
        const row = raw[y * (stride + 1) + 1 ..][0..stride];
        const out = pixels[y * stride ..][0..stride];
        const above: ?[]const u8 = if (y > 0) pixels[(y - 1) * stride ..][0..stride] else null;
        for (out, row, 0..) |*pixel, value, i| {
            const a: u8 = if (i >= 4) out[i - 4] else 0;
            const b: u8 = if (above) |up| up[i] else 0;
            const c: u8 = if (i >= 4) if (above) |up| up[i - 4] else 0 else 0;
            pixel.* = value +% switch (filter) {
                0 => 0,
                1 => a,
                2 => b,
                3 => @as(u8, @intCast((@as(u16, a) + b) / 2)),
                4 => paeth(a, b, c),
                else => return error.BadFilter,
            };
        }
    }
    return .{ .width = width, .height = height, .pixels = pixels };
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    return if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c;
}

const testing = std.testing;

test "the icon decodes: transparent corners, opaque squares" {
    const image = try decode(testing.allocator, @import("assets").icon);
    defer image.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1024), image.width);
    try testing.expectEqual(@as(u32, 1024), image.height);
    try testing.expectEqual(@as(u8, 0), image.pixels[3]);
    // A pixel inside the top-left square.
    const square = (190 * 1024 + 190) * 4;
    try testing.expectEqual(@as(u8, 255), image.pixels[square + 3]);
}

test "every row filter: none, sub, up, average and paeth" {
    // 2x5 pixels, row y uses filter y.
    const file = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x02\x00\x00\x00\x05\x08\x06\x00\x00\x00\x6f\xb3\x3d\x9c\x00\x00\x00\x2f\x49\x44\x41\x54\x78\x9c\x63\x60\x38\x61\xf4\x9f\xf9\x44\xd4\x6c\x46\xae\x83\x40\x06\x83\xc6\x1c\x26\xae\x9f\x0c\x0c\x20\xcc\x2c\x12\x26\xd9\xc0\xfe\x57\xe4\x1c\x0b\x98\xc7\xc0\xc0\x00\x00\x47\xa0\x0c\x7c\xd6\xe4\x0d\x40\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";
    const image = try decode(testing.allocator, file);
    defer image.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &.{
        0,  200, 50, 255, 3,  200, 90, 155, 10, 193, 50, 255, 13, 193, 90, 155,
        20, 186, 50, 255, 23, 186, 90, 155, 30, 179, 50, 255, 33, 179, 90, 155,
        40, 172, 50, 255, 43, 172, 90, 155,
    }, image.pixels);
}

test "shrink averages what each pixel covers, by alpha" {
    // Red opaque, red transparent, blue opaque, white half.
    var pixels = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 0, 0, 0, 255, 255, 255, 255, 255, 128 };
    const image: Image = .{ .width = 2, .height = 2, .pixels = &pixels };
    const one = try image.shrink(testing.allocator, 1, 1);
    defer one.deinit(testing.allocator);
    // The transparent green adds nothing; alpha is the plain average.
    try testing.expectEqualSlices(u8, &.{ 153, 51, 153, 159 }, one.pixels);
    const same = try image.shrink(testing.allocator, 2, 2);
    defer same.deinit(testing.allocator);
    // A pixel that covers only a transparent one has no color.
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255, 255, 128 }, same.pixels);
}

test "a file that is not a PNG fails" {
    try testing.expectError(error.NotPng, decode(testing.allocator, "GIF89a"));
}
