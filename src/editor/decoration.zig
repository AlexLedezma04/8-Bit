//! Marks on the text that the editor view draws: selection, search matches,
//! git markers, blame. Features add decorations; only the view draws them.
const std = @import("std");
const Range = @import("../core/buffer.zig").Range;

/// What a decoration means. The theme decides its color.
pub const Style = enum {
    selection,
    current_line,
    match,
    bracket,
    /// Gutter markers of git changes.
    added,
    changed,
    removed,
    /// Lines of a diff view.
    diff_added,
    diff_removed,
    diff_header,
};

pub const Decoration = struct {
    /// Text positions. Line decorations apply to every line the range touches.
    range: Range,
    kind: Kind,

    pub const Kind = union(enum) {
        /// Background behind the characters of the range.
        text_background: Style,
        /// Background across the whole line.
        line_background: Style,
        /// A colored bar in the gutter.
        gutter_marker: Style,
        /// A short text in the gutter, before the line number.
        gutter_text: []const u8,
    };
};

fn startsBefore(pos: usize, decoration: Decoration) bool {
    return decoration.range.start < pos;
}

/// The decorations of `sorted` (by range start) that can touch `visible`.
/// The caller still skips those that end before it.
pub fn upTo(sorted: []const Decoration, visible: Range) []const Decoration {
    return sorted[0..std.sort.partitionPoint(Decoration, sorted, visible.end + 1, startsBefore)];
}

/// Widest gutter text, so the gutter can make room for it.
pub fn gutterTextWidth(decorations: []const Decoration) usize {
    var width: usize = 0;
    for (decorations) |decoration| switch (decoration.kind) {
        .gutter_text => |text| width = @max(width, std.unicode.utf8CountCodepoints(text) catch text.len),
        else => {},
    };
    return width;
}

const testing = std.testing;

test "upTo keeps only decorations that start before the visible end" {
    const list = [_]Decoration{
        .{ .range = .{ .start = 0, .end = 2 }, .kind = .{ .gutter_marker = .added } },
        .{ .range = .{ .start = 5, .end = 9 }, .kind = .{ .text_background = .selection } },
        .{ .range = .{ .start = 10, .end = 10 }, .kind = .{ .gutter_text = "ab12" } },
        .{ .range = .{ .start = 30, .end = 40 }, .kind = .{ .line_background = .removed } },
    };
    try testing.expectEqual(@as(usize, 3), upTo(&list, .{ .start = 6, .end = 10 }).len);
    try testing.expectEqual(@as(usize, 1), upTo(&list, .{ .start = 0, .end = 4 }).len);
    try testing.expectEqual(@as(usize, 4), upTo(&list, .{ .start = 0, .end = 99 }).len);
    try testing.expectEqual(@as(usize, 0), upTo(&.{}, .{ .start = 0, .end = 99 }).len);
    try testing.expectEqual(@as(usize, 4), gutterTextWidth(&list));
}
