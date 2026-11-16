//! Loads settings, themes and key bindings from ZON files: the user's file in
//! the config folder, else the built-in one from `assets/`. Feature modules
//! get the parsed value and never read files themselves.
const std = @import("std");
const assets = @import("assets");
const fs = @import("../platform/fs.zig");

/// Folder of the theme files, built-in and the user's.
pub const theme_folder = "themes";

pub const Settings = struct {
    tab_width: u8,
    use_spaces: bool,
    wrap: bool,
    /// 0 matches the screen.
    zoom: u8,
    theme: []const u8,
    line_numbers: bool,
    undo_limit_mb: u16,
};

pub const Loader = struct {
    io: std.Io,
    /// Scratch memory while parsing.
    gpa: std.mem.Allocator,
    /// The user config folder; null when there is none.
    dir: ?[]const u8 = null,

    /// Where the user's `name.zon` is, or would be.
    pub fn path(self: Loader, buffer: []u8, name: []const u8) ?[]const u8 {
        const dir = self.dir orelse return null;
        return std.fmt.bufPrint(buffer, "{s}" ++ std.fs.path.sep_str ++ "{s}.zon", .{ dir, name }) catch null;
    }

    /// The user's `name.zon`, else the built-in one.
    pub fn source(self: Loader, arena: std.mem.Allocator, name: []const u8, notifier: anytype) ?[:0]const u8 {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        if (self.path(&buffer, name)) |file| {
            if (fs.read(self.io, arena, file)) |bytes| return bytes else |err| switch (err) {
                error.FileNotFound => {},
                else => notifier.notify("Could not read {s}.zon: {t}", .{ name, err }),
            }
        }
        return assets.files.get(name);
    }

    /// `name.zon` filled in over `base`: fields it leaves out keep their value
    /// from `base`. A file with errors is reported and `base` is returned.
    pub fn load(self: Loader, comptime T: type, arena: std.mem.Allocator, name: []const u8, base: T, notifier: anytype) T {
        const bytes = self.source(arena, name, notifier) orelse {
            notifier.notify("No {s}.zon", .{name});
            return base;
        };
        const file = parse(Zon(T, true), self.gpa, arena, bytes, name, notifier) orelse return base;
        var result = base;
        fill(T, &result, file);
        return result;
    }

    /// Names of the files in a folder, built-in and the user's, sorted.
    pub fn names(self: Loader, arena: std.mem.Allocator, folder: []const u8) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        for (assets.files.keys()) |key| {
            if (key.len > folder.len and std.mem.startsWith(u8, key, folder) and key[folder.len] == '/')
                try list.append(arena, key[folder.len + 1 ..]);
        }
        if (self.dir) |dir| {
            const sub = try std.fs.path.join(arena, &.{ dir, folder });
            try list.appendSlice(arena, try fs.list(self.io, arena, sub, ".zon"));
        }
        std.mem.sort([]const u8, list.items, {}, lessThan);
        var unique: usize = 0;
        for (list.items) |name| {
            if (unique > 0 and std.mem.eql(u8, list.items[unique - 1], name)) continue;
            list.items[unique] = name;
            unique += 1;
        }
        return list.items[0..unique];
    }
};

/// The built-in `name.zon`, which sets every field of `T`.
pub fn builtin(comptime T: type, gpa: std.mem.Allocator, arena: std.mem.Allocator, name: []const u8) T {
    const Panic = struct {
        pub fn notify(_: @This(), comptime format: []const u8, args: anytype) void {
            std.debug.panic("built-in " ++ format, args);
        }
    };
    var result: T = undefined;
    fill(T, &result, parse(Zon(T, false), gpa, arena, assets.files.get(name).?, name, Panic{}).?);
    return result;
}

/// The text of a ZON file with one top-level field set to `value`, which is
/// ZON text. The rest, comments too, stays as it is.
pub fn setField(allocator: std.mem.Allocator, source: [:0]const u8, field: []const u8, value: []const u8) ![]u8 {
    var tokens = std.zig.Tokenizer.init(source);
    var depth: usize = 0;
    var previous: [2]std.zig.Token.Tag = @splat(.invalid);
    var name_end: usize = 0;
    var open: ?usize = null;
    while (true) {
        const token = tokens.next();
        switch (token.tag) {
            .eof => break,
            .l_brace => {
                depth += 1;
                if (open == null) open = token.loc.end;
            },
            .r_brace => depth -|= 1,
            .identifier => if (depth == 1 and previous[1] == .period and
                std.mem.eql(u8, source[token.loc.start..token.loc.end], field))
            {
                name_end = token.loc.end;
            },
            else => {},
        }
        // `.field = value`: the value is the token after `=`.
        if (name_end != 0 and previous[1] == .equal and previous[0] == .identifier) {
            return std.mem.concat(allocator, u8, &.{ source[0..token.loc.start], value, source[token.loc.end..] });
        }
        previous = .{ previous[1], token.tag };
    }
    const at = open orelse return error.NotAStruct;
    return std.fmt.allocPrint(allocator, "{s}\n    .{s} = {s},{s}", .{ source[0..at], field, value, source[at..] });
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn parse(comptime T: type, gpa: std.mem.Allocator, arena: std.mem.Allocator, bytes: [:0]const u8, name: []const u8, notifier: anytype) ?T {
    var diagnostics: std.zon.parse.Diagnostics = .{ .errors = &.{} };
    return std.zon.parse.fromSlice(T, .{ .gpa = gpa, .arena = arena, .source = bytes, .diagnostics = &diagnostics }) catch |err| {
        if (diagnostics.errors.len == 0) {
            notifier.notify("Could not load {s}.zon: {t}", .{ name, err });
        } else {
            const first = diagnostics.errors[0];
            notifier.notify("{s}.zon:{d}: {s}", .{ name, first.loc.line + 1, first.msg });
        }
        return null;
    };
}

/// What a file holds for `T`. With `partial`, every struct field may be left
/// out. A type with `fromZon` is written as that function's argument.
fn Zon(comptime T: type, comptime partial: bool) type {
    if (@typeInfo(T) != .@"struct") return T;
    if (@hasDecl(T, "fromZon")) return @typeInfo(@TypeOf(T.fromZon)).@"fn".param_types[0].?;
    const info = @typeInfo(T).@"struct";
    var types: [info.field_types.len]type = undefined;
    var attrs: [types.len]std.lang.Type.Struct.FieldAttributes = @splat(.{});
    for (info.field_types, 0..) |field, i| {
        types[i] = if (partial) ?Zon(field, true) else Zon(field, false);
        if (partial) attrs[i].default_value_ptr = &@as(types[i], null);
    }
    return @Struct(.auto, null, info.field_names, &types, &attrs);
}

/// Copies what `value` sets into `target`.
fn fill(comptime T: type, target: *T, value: anytype) void {
    if (@typeInfo(@TypeOf(value)) == .optional) {
        if (value) |set| fill(T, target, set);
    } else if (@typeInfo(T) != .@"struct") {
        target.* = value;
    } else if (@hasDecl(T, "fromZon")) {
        target.* = T.fromZon(value);
    } else {
        const info = @typeInfo(T).@"struct";
        inline for (info.field_names, info.field_types) |name, field|
            fill(field, &@field(target, name), @field(value, name));
    }
}

const testing = std.testing;

/// Remembers the last message, in place of the editor.
pub const TestNotifier = struct {
    buffer: [160]u8 = undefined,
    message: []const u8 = "",

    pub fn notify(self: *TestNotifier, comptime format: []const u8, args: anytype) void {
        self.message = std.fmt.bufPrint(&self.buffer, format, args) catch &self.buffer;
    }
};

const Sample = struct {
    size: u8,
    name: []const u8,
    color: Hex,
    inner: struct { a: bool, b: bool },

    const Hex = struct {
        value: u32,
        pub fn fromZon(value: u24) Hex {
            return .{ .value = value };
        }
    };
};

const sample_base: Sample = .{ .size = 1, .name = "base", .color = .{ .value = 0 }, .inner = .{ .a = false, .b = false } };

fn testLoader(arena: std.mem.Allocator, tmp: *const testing.TmpDir) !Loader {
    return .{ .io = testing.io, .gpa = testing.allocator, .dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path}) };
}

test "a user file fills in over the base; what it leaves out is kept" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const loader = try testLoader(arena.allocator(), &tmp);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "sample.zon", .data = ".{ .name = \"mine\", .color = 0xabcdef, .inner = .{ .b = true } }" });

    var notifier: TestNotifier = .{};
    const sample = loader.load(Sample, arena.allocator(), "sample", sample_base, &notifier);
    try testing.expectEqual(@as(u8, 1), sample.size);
    try testing.expectEqualStrings("mine", sample.name);
    try testing.expectEqual(@as(u32, 0xabcdef), sample.color.value);
    try testing.expect(!sample.inner.a and sample.inner.b);
    try testing.expectEqualStrings("", notifier.message);
}

test "a bad file is reported with its line and the base is kept" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const loader = try testLoader(arena.allocator(), &tmp);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "sample.zon", .data = ".{\n    .size = 2,\n    .nope = 3,\n}" });

    var notifier: TestNotifier = .{};
    const sample = loader.load(Sample, arena.allocator(), "sample", sample_base, &notifier);
    try testing.expectEqual(@as(u8, 1), sample.size);
    try testing.expectStringStartsWith(notifier.message, "sample.zon:3: ");

    _ = loader.load(Sample, arena.allocator(), "missing", sample_base, &notifier);
    try testing.expectEqualStrings("No missing.zon", notifier.message);
}

test "without a user file the built-in one is used" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const loader: Loader = .{ .io = testing.io, .gpa = testing.allocator };
    var notifier: TestNotifier = .{};
    const base = builtin(Settings, testing.allocator, arena.allocator(), "settings");
    const settings = loader.load(Settings, arena.allocator(), "settings", base, &notifier);
    try testing.expectEqualStrings("dark", settings.theme);
    try testing.expectEqual(@as(u8, 4), settings.tab_width);
}

test "names lists built-in and user files once each" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const loader = try testLoader(arena.allocator(), &tmp);
    try tmp.dir.createDirPath(testing.io, "themes");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "themes/blue.zon", .data = ".{}" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "themes/dark.zon", .data = ".{}" });

    const names = try loader.names(arena.allocator(), "themes");
    try testing.expectEqual(@as(usize, 3), names.len);
    for ([_][]const u8{ "blue", "dark", "light" }, names) |expected, name| try testing.expectEqualStrings(expected, name);
}

test "setField changes one field and keeps the rest" {
    const source = "// .theme = \"x\"\n.{\n    .theme = \"dark\", // mine\n    .inner = .{ .theme = 1 },\n}";
    const changed = try setField(testing.allocator, source, "theme", "\"light\"");
    defer testing.allocator.free(changed);
    try testing.expectEqualStrings("// .theme = \"x\"\n.{\n    .theme = \"light\", // mine\n    .inner = .{ .theme = 1 },\n}", changed);

    const added = try setField(testing.allocator, ".{ .zoom = 2 }", "theme", "\"light\"");
    defer testing.allocator.free(added);
    try testing.expectEqualStrings(".{\n    .theme = \"light\", .zoom = 2 }", added);
}
