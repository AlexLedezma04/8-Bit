//! Find and replace in the active file: what to find, the options, and the
//! matches, which are kept up to date and highlighted while the prompt is open.
const std = @import("std");
const search = @import("../core/search.zig");
const Document = @import("../core/edit.zig").Document;
const Range = @import("../core/buffer.zig").Range;

pub const Option = enum { match_case, whole_word };
pub const Direction = enum { forward, back };

pub const Find = struct {
    allocator: std.mem.Allocator,
    needle: std.ArrayList(u8) = .empty,
    replacement: std.ArrayList(u8) = .empty,
    options: search.Options = .{},
    /// Sorted. Filled by `refresh`.
    matches: std.ArrayList(Range) = .empty,
    /// The prompt is open.
    shown: bool = false,
    /// Where typing searches from: the cursor when the prompt opened.
    origin: usize = 0,

    pub fn deinit(self: *Find) void {
        self.needle.deinit(self.allocator);
        self.replacement.deinit(self.allocator);
        self.matches.deinit(self.allocator);
    }

    pub fn query(self: *const Find) search.Query {
        return .{ .needle = self.needle.items, .options = self.options };
    }

    pub fn refresh(self: *Find, doc: *const Document) void {
        self.query().all(self.allocator, search.textOf(doc), &self.matches) catch self.matches.clearRetainingCapacity();
    }

    /// Starts a search from the cursor and selects the first match. The
    /// needle becomes the selection if it is on one line. Returns the needle.
    pub fn begin(self: *Find, doc: *Document) []const u8 {
        self.origin = doc.cursor.selection().start;
        self.shown = true;
        _ = copySelection(self.allocator, doc, &self.needle);
        self.refresh(doc);
        if (self.after(self.origin)) |match| select(doc, match);
        return self.needle.items;
    }

    /// Puts the selection into `out` if it is on one line.
    fn copySelection(allocator: std.mem.Allocator, doc: *const Document, out: *std.ArrayList(u8)) bool {
        const selection = doc.cursor.selection();
        const one_line = doc.buffer.lineOf(selection.start) == doc.buffer.lineOf(selection.end);
        if (selection.len() == 0 or !one_line) return false;
        out.resize(allocator, selection.len()) catch return false;
        _ = doc.buffer.copy(selection.start, out.items);
        return true;
    }

    /// The typed needle: selects the first match from the origin.
    pub fn setNeedle(self: *Find, doc: *Document, text: []const u8) void {
        if (std.mem.eql(u8, text, self.needle.items)) return;
        self.needle.clearRetainingCapacity();
        self.needle.appendSlice(self.allocator, text) catch return;
        self.refresh(doc);
        if (self.after(self.origin)) |match| select(doc, match) else doc.cursor = .{ .pos = self.origin };
    }

    pub fn setReplacement(self: *Find, text: []const u8) void {
        self.replacement.clearRetainingCapacity();
        self.replacement.appendSlice(self.allocator, text) catch {};
    }

    pub fn toggle(self: *Find, option: Option) bool {
        const flag = switch (option) {
            .match_case => &self.options.match_case,
            .whole_word => &self.options.whole_word,
        };
        flag.* = !flag.*;
        return flag.*;
    }

    /// Selects the next or previous match, going round at the ends. False
    /// when there is none.
    pub fn step(self: *Find, doc: *Document, direction: Direction) bool {
        self.refresh(doc);
        const selection = doc.cursor.selection();
        const match = switch (direction) {
            .forward => self.after(if (selection.len() > 0) selection.end else selection.start),
            .back => self.before(selection.start),
        } orelse return false;
        select(doc, match);
        return true;
    }

    /// Replaces the selected match and selects the next one. Without a
    /// selected match, only goes to the next one.
    pub fn replaceNext(self: *Find, doc: *Document) !bool {
        self.refresh(doc);
        if (self.selected(doc) != null) try doc.replace(doc.cursor.selection(), self.replacement.items);
        return self.step(doc, .forward);
    }

    pub fn replaceAll(self: *Find, doc: *Document) !usize {
        return search.replaceAll(doc, self.query(), self.replacement.items);
    }

    /// Index of the match that is selected, if one is.
    pub fn selected(self: *const Find, doc: *const Document) ?usize {
        const selection = doc.cursor.selection();
        const at = self.firstFrom(selection.start);
        if (at < self.matches.items.len and std.meta.eql(self.matches.items[at], selection)) return at;
        return null;
    }

    fn firstFrom(self: *const Find, pos: usize) usize {
        return std.sort.partitionPoint(Range, self.matches.items, pos, startsBefore);
    }

    fn startsBefore(pos: usize, range: Range) bool {
        return range.start < pos;
    }

    fn after(self: *const Find, pos: usize) ?Range {
        const items = self.matches.items;
        if (items.len == 0) return null;
        const at = self.firstFrom(pos);
        return items[if (at < items.len) at else 0];
    }

    fn before(self: *const Find, pos: usize) ?Range {
        const items = self.matches.items;
        if (items.len == 0) return null;
        const at = self.firstFrom(pos);
        return items[if (at > 0) at - 1 else items.len - 1];
    }

    fn select(doc: *Document, match: Range) void {
        doc.cursor = .{ .anchor = match.start, .pos = match.end };
    }
};

const testing = std.testing;
const expectText = @import("../core/buffer.zig").expectText;

test "typing selects the first match from the origin; steps go round" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    try doc.load("ab ab ab");
    var find: Find = .{ .allocator = testing.allocator };
    defer find.deinit();
    doc.cursor.pos = 1;
    try testing.expectEqualStrings("", find.begin(&doc));
    find.setNeedle(&doc, "ab");
    try testing.expectEqual(Range{ .start = 3, .end = 5 }, doc.cursor.selection());
    try testing.expectEqual(@as(?usize, 1), find.selected(&doc));
    try testing.expect(find.step(&doc, .forward));
    try testing.expect(find.step(&doc, .forward));
    try testing.expectEqual(Range{ .start = 0, .end = 2 }, doc.cursor.selection());
    try testing.expect(find.step(&doc, .back));
    try testing.expectEqual(@as(?usize, 2), find.selected(&doc));
    find.setNeedle(&doc, "abc");
    try testing.expectEqual(@as(?usize, null), find.selected(&doc));
    try testing.expectEqual(Range{ .start = 1, .end = 1 }, doc.cursor.selection());
    try testing.expect(!find.step(&doc, .forward));
}

test "begin takes a one-line selection" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    try doc.load("one two\nthree");
    var find: Find = .{ .allocator = testing.allocator };
    defer find.deinit();
    doc.cursor = .{ .anchor = 4, .pos = 7 };
    try testing.expectEqualStrings("two", find.begin(&doc));
    doc.cursor = .{ .anchor = 4, .pos = 10 };
    try testing.expectEqualStrings("two", find.begin(&doc));
    try testing.expectEqual(@as(usize, 4), find.origin);
}

test "replace the selected match, then the rest; options" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    try doc.load("a A a");
    var find: Find = .{ .allocator = testing.allocator };
    defer find.deinit();
    _ = find.begin(&doc);
    find.setNeedle(&doc, "a");
    find.setReplacement("bb");
    try testing.expect(try find.replaceNext(&doc));
    try expectText(&doc.buffer, "bb A a");
    try testing.expectEqual(Range{ .start = 3, .end = 4 }, doc.cursor.selection());
    try testing.expect(find.toggle(.match_case));
    try testing.expect(try find.replaceNext(&doc));
    try expectText(&doc.buffer, "bb A a");
    try testing.expectEqual(@as(usize, 1), try find.replaceAll(&doc));
    try expectText(&doc.buffer, "bb A bb");
}
