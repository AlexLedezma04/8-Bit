//! A one-line input shown above the editor area. Enter confirms, Esc
//! cancels. The text is a `Document`, so editing keys work as in the editor.
//! Each kind of prompt keeps its own history; entries that contain the text
//! are suggested in a list, picked with Up and Down.
const std = @import("std");
const Document = @import("../../core/edit.zig").Document;
const Canvas = @import("../canvas.zig").Canvas;
const Rect = @import("../layout.zig").Rect;
const Look = @import("../panel.zig").Look;
const list_zig = @import("list.zig");
const List = list_zig.List;
const KeyPress = @import("../../platform/event.zig").KeyPress;
const keymap = @import("../../editor/keymap.zig");

pub const Kind = enum { new_file, new_folder, rename };

pub const Outcome = union(enum) {
    /// Still open.
    editing,
    cancel,
    /// The confirmed text. Valid until the next key.
    submit: []const u8,
};

pub const Prompt = struct {
    allocator: std.mem.Allocator,
    doc: Document,
    /// Null while closed.
    kind: ?Kind = null,
    label: []const u8 = "",
    histories: [kind_count]std.ArrayList([]u8) = @splat(.empty),
    /// History entries that contain the text, newest first.
    matches: std.ArrayList([]const u8) = .empty,
    list: List = .{},
    /// A suggestion was chosen with Up or Down.
    picked: bool = false,
    result: std.ArrayList(u8) = .empty,

    const kind_count = std.enums.values(Kind).len;
    const max_history = 50;
    const max_shown = 8;
    const width_cols = 60;

    pub fn init(allocator: std.mem.Allocator) Prompt {
        return .{ .allocator = allocator, .doc = .init(allocator) };
    }

    pub fn deinit(self: *Prompt) void {
        for (&self.histories) |*history| {
            for (history.items) |entry| self.allocator.free(entry);
            history.deinit(self.allocator);
        }
        self.matches.deinit(self.allocator);
        self.result.deinit(self.allocator);
        self.doc.deinit();
    }

    /// Opens with `initial` selected, so typing replaces it.
    pub fn open(self: *Prompt, kind: Kind, label: []const u8, initial: []const u8) !void {
        try self.doc.load(initial);
        self.doc.selectAll();
        self.kind = kind;
        self.label = label;
        self.refresh();
    }

    pub fn close(self: *Prompt) void {
        self.kind = null;
    }

    pub fn text(self: *Prompt) []const u8 {
        self.result.clearRetainingCapacity();
        const len = self.doc.buffer.len();
        const bytes = self.result.addManyAsSlice(self.allocator, len) catch return "";
        return self.doc.buffer.copy(0, bytes);
    }

    /// Typed text. Line breaks are left out.
    pub fn typeText(self: *Prompt, typed: []const u8) void {
        var rest = typed;
        while (rest.len > 0) {
            const end = std.mem.indexOfAny(u8, rest, "\r\n") orelse rest.len;
            if (end > 0) self.doc.insert(rest[0..end]) catch {};
            rest = rest[@min(end + 1, rest.len)..];
        }
        self.refresh();
    }

    pub fn key(self: *Prompt, press: KeyPress, bindings: []const keymap.Binding) Outcome {
        switch (press.key) {
            .escape => {
                self.close();
                return .cancel;
            },
            .enter => return self.submit(),
            .up, .down => if (!press.mods.shift and self.matches.items.len > 0) {
                if (self.picked) {
                    _ = self.list.key(press, self.matches.items.len, max_shown);
                } else {
                    self.list = .{};
                }
                self.picked = true;
                return .editing;
            },
            else => {},
        }
        const command = keymap.lookup(bindings, press.key, press.mods) orelse return .editing;
        self.edit(command) catch {};
        if (command != .select_all and !std.mem.startsWith(u8, @tagName(command), "move_") and !std.mem.startsWith(u8, @tagName(command), "select_")) self.refresh();
        return .editing;
    }

    /// The editing commands that make sense on one line.
    fn edit(self: *Prompt, command: @import("../../editor/commands.zig").Command) !void {
        const doc = &self.doc;
        switch (command) {
            .move_left => doc.move(.left, false),
            .move_right => doc.move(.right, false),
            .move_word_left => doc.move(.word_left, false),
            .move_word_right => doc.move(.word_right, false),
            .move_line_start, .move_file_start => doc.move(.line_start, false),
            .move_line_end, .move_file_end => doc.move(.line_end, false),
            .select_left => doc.move(.left, true),
            .select_right => doc.move(.right, true),
            .select_word_left => doc.move(.word_left, true),
            .select_word_right => doc.move(.word_right, true),
            .select_line_start => doc.move(.line_start, true),
            .select_line_end => doc.move(.line_end, true),
            .select_all => doc.selectAll(),
            .delete_left => try doc.delete(.left),
            .delete_right => try doc.delete(.right),
            .delete_word_left => try doc.delete(.word_left),
            .delete_word_right => try doc.delete(.word_right),
            .undo => _ = try doc.undo(),
            .redo => _ = try doc.redo(),
            else => {},
        }
    }

    fn submit(self: *Prompt) Outcome {
        const kind = self.kind orelse return .cancel;
        const chosen = if (self.picked) self.matches.items[self.list.selected] else self.text();
        if (chosen.ptr != self.result.items.ptr) {
            self.result.clearRetainingCapacity();
            self.result.appendSlice(self.allocator, chosen) catch return .cancel;
        }
        self.remember(kind, self.result.items);
        self.close();
        return .{ .submit = self.result.items };
    }

    /// Adds to the history of `kind`, newest last, without repeats.
    fn remember(self: *Prompt, kind: Kind, entry: []const u8) void {
        if (entry.len == 0) return;
        const history = &self.histories[@backingInt(kind)];
        for (history.items, 0..) |old, i| if (std.mem.eql(u8, old, entry)) {
            self.allocator.free(history.orderedRemove(i));
            break;
        };
        const copy = self.allocator.dupe(u8, entry) catch return;
        history.append(self.allocator, copy) catch return self.allocator.free(copy);
        if (history.items.len > max_history) self.allocator.free(history.orderedRemove(0));
    }

    /// Finds the suggestions for the text again.
    fn refresh(self: *Prompt) void {
        self.picked = false;
        self.list = .{};
        self.matches.clearRetainingCapacity();
        const kind = self.kind orelse return;
        const typed = self.text();
        const history = self.histories[@backingInt(kind)].items;
        var i = history.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.indexOf(u8, history[i], typed) == null) continue;
            self.matches.append(self.allocator, history[i]) catch return;
        }
    }

    /// The suggestions, as list rows.
    const Rows = struct {
        matches: []const []const u8,
        color: @import("../theme.zig").Color,

        pub fn row(self: Rows, index: usize) list_zig.Row {
            return .{ .text = self.matches[index], .color = self.color };
        }
    };

    /// A box at the top middle of `area`, below the tab bar, with the
    /// suggestions under it.
    pub fn draw(self: *Prompt, canvas: Canvas, look: Look, area: Rect) void {
        if (self.kind == null) return;
        const theme = look.theme;
        const metrics = look.metrics;
        const w = @min(area.w, width_cols * metrics.cell);
        const shown = @min(self.matches.items.len, max_shown);
        const box: Rect = .{
            .x = area.x + @floor((area.w - w) / 2),
            .y = area.y + metrics.bar() + metrics.row / 2,
            .w = w,
            .h = metrics.bar() + @as(f32, @floatFromInt(shown)) * metrics.row,
        };
        canvas.fillRect(.{ .x = box.x - 1, .y = box.y - 1, .w = box.w + 2, .h = box.h + 2 }, theme.border);
        canvas.fillRect(box, theme.status_bar);
        canvas.setClip(box);
        defer canvas.setClip(null);

        const y = metrics.barText(box.y);
        const label_x = box.x + metrics.cell;
        canvas.drawText(label_x, y, self.label, theme.line_number_current);
        const text_x = label_x + @as(f32, @floatFromInt(self.label.len + 1)) * metrics.cell;
        const visible = metrics.cols(box.x + box.w - text_x) -| 1;
        const doc = &self.doc;
        const first = (doc.columnOf(doc.cursor.pos) + 1) -| visible;
        const selection = doc.cursor.selection();
        if (selection.len() > 0) {
            const from = doc.columnOf(selection.start) -| first;
            const to = doc.columnOf(selection.end) -| first;
            canvas.fillRect(.{ .x = text_x + @as(f32, @floatFromInt(from)) * metrics.cell, .y = y, .w = @as(f32, @floatFromInt(to - from)) * metrics.cell, .h = metrics.row }, theme.selection);
        }
        const typed = self.text();
        canvas.drawText(text_x, y, typed[@min(doc.posAtColumn(0, first), typed.len)..], theme.text);
        const cursor_x = text_x + @as(f32, @floatFromInt(doc.columnOf(doc.cursor.pos) - first)) * metrics.cell;
        canvas.fillRect(.{ .x = cursor_x, .y = y, .w = @max(1, @floor(metrics.cell / 8)), .h = metrics.row }, theme.cursor);

        if (shown == 0) return;
        const rows: Rect = .{ .x = box.x, .y = box.y + metrics.bar(), .w = box.w, .h = box.h - metrics.bar() };
        const source: Rows = .{ .matches = self.matches.items, .color = theme.text };
        self.list.draw(canvas, look, rows, self.matches.items.len, source, self.picked);
    }
};

const testing = std.testing;
const expectText = @import("../../core/buffer.zig").expectText;

fn hit(prompt: *Prompt, code: @import("../../platform/event.zig").Key, mods: @import("../../platform/event.zig").Mods) Outcome {
    return prompt.key(.{ .key = code, .mods = mods }, &keymap.default);
}

test "typing, editing keys, Enter and Esc" {
    var prompt = Prompt.init(testing.allocator);
    defer prompt.deinit();
    try prompt.open(.rename, "Rename:", "old.txt");
    prompt.typeText("new\n.zig");
    try expectText(&prompt.doc.buffer, "new.zig");
    _ = hit(&prompt, .backspace, .{ .ctrl = true });
    _ = hit(&prompt, .left, .{});
    _ = hit(&prompt, .backspace, .{});
    try expectText(&prompt.doc.buffer, "ne.");
    try testing.expectEqualStrings("ne.", hit(&prompt, .enter, .{}).submit);
    try testing.expectEqual(@as(?Kind, null), prompt.kind);

    try prompt.open(.new_file, "New file:", "");
    try testing.expectEqual(Outcome.cancel, hit(&prompt, .escape, .{}));
}

test "each kind has its own history, suggested while typing" {
    var prompt = Prompt.init(testing.allocator);
    defer prompt.deinit();
    for ([_][]const u8{ "main.zig", "notes.txt", "main_test.zig" }) |name| {
        try prompt.open(.new_file, "New file:", "");
        prompt.typeText(name);
        _ = hit(&prompt, .enter, .{});
    }
    try prompt.open(.new_folder, "New folder:", "");
    try testing.expectEqual(@as(usize, 0), prompt.matches.items.len);

    try prompt.open(.new_file, "New file:", "");
    try testing.expectEqual(@as(usize, 3), prompt.matches.items.len);
    prompt.typeText("main");
    try testing.expectEqual(@as(usize, 2), prompt.matches.items.len);
    try testing.expectEqualStrings("main_test.zig", prompt.matches.items[0]);
    _ = hit(&prompt, .down, .{});
    _ = hit(&prompt, .down, .{});
    try testing.expectEqualStrings("main.zig", hit(&prompt, .enter, .{}).submit);
    // Used again: now the newest.
    try testing.expectEqualStrings("main.zig", prompt.histories[0].items[2]);
}
