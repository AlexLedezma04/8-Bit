//! The whole window: places the panels, draws them, and routes input. A key
//! goes to the prompt if it is open, else to the focused panel, else to the
//! key bindings. A click gives its panel focus. Dock edges can be dragged.
//! Prompts that commands ask for are opened here.
const std = @import("std");
const editor_zig = @import("../editor/editor.zig");
const Editor = editor_zig.Editor;
const Request = editor_zig.Request;
const commands = @import("../editor/commands.zig");
const keymap = @import("../editor/keymap.zig");
const layout = @import("layout.zig");
const Rect = layout.Rect;
const Metrics = layout.Metrics;
const Frame = layout.Frame;
const Canvas = @import("canvas.zig").Canvas;
const panel = @import("panel.zig");
const Panel = panel.Panel;
const Look = panel.Look;
const theme_zig = @import("theme.zig");
const prompt_zig = @import("widgets/prompt.zig");
const Prompt = prompt_zig.Prompt;
const Find = @import("../editor/find.zig").Find;
const EditorView = @import("panels/editor_view.zig").EditorView;
const FileTree = @import("panels/file_tree.zig").FileTree;
const Messages = @import("panels/messages.zig").Messages;
const Search = @import("panels/search.zig").Search;
const status_bar = @import("panels/status_bar.zig");
const event = @import("../platform/event.zig");
const Event = event.Event;
const Area = editor_zig.Area;

pub const Outcome = struct {
    request: ?Request = null,
    /// False when nothing on screen can have changed.
    redraw: bool = true,
};

/// The panels of the bottom dock, one title each in its bar.
pub const Bottom = enum { messages, search };

pub const Workbench = struct {
    editor: *Editor,
    theme: theme_zig.Theme = undefined,
    /// The `config_version` of the editor that `theme` was loaded for.
    theme_version: ?u32 = null,
    prompt: Prompt,
    view: EditorView,
    files: FileTree,
    messages: Messages,
    search: Search,
    bottom: Bottom = .messages,
    /// The find prompt asks what to replace; Enter then asks for the replacement.
    replacing: bool = false,
    /// Window size in pixels, and pixels per unit of mouse position.
    width: f32 = 800,
    height: f32 = 600,
    density: f32 = 1,
    /// A dock edge being dragged.
    dragging: ?Frame.Edge = null,
    /// The area that got the last mouse down; it gets the moves and the up.
    captured: ?Area = null,
    /// The last key was used, so the text it also types is dropped.
    swallow_text: bool = false,

    /// In place, because the panels point into it.
    pub fn init(self: *Workbench, editor: *Editor) void {
        self.* = .{
            .editor = editor,
            .prompt = .init(editor.allocator),
            .view = .{ .editor = editor },
            .files = .{ .editor = editor, .prompt = &self.prompt },
            .messages = .{ .editor = editor },
            .search = .{ .editor = editor },
        };
    }

    pub fn deinit(self: *Workbench) void {
        self.files.deinit();
        self.view.deinit();
        self.prompt.deinit();
    }

    fn metrics(self: *const Workbench) Metrics {
        return .init(self.editor.zoom);
    }

    fn frame(self: *const Workbench) Frame {
        const editor = self.editor;
        return .init(
            self.width,
            self.height,
            self.metrics(),
            if (editor.sidebar.shown) editor.sidebar.size else null,
            if (editor.bottom.shown) editor.bottom.size else null,
        );
    }

    fn panelOf(self: *Workbench, area: Area) Panel {
        return switch (area) {
            .sidebar => .of(FileTree, &self.files),
            .editor => .of(EditorView, &self.view),
            .bottom => self.bottomPanel(self.bottom),
        };
    }

    fn bottomPanel(self: *Workbench, which: Bottom) Panel {
        return switch (which) {
            .messages => .of(Messages, &self.messages),
            .search => .of(Search, &self.search),
        };
    }

    /// The cell where a title of the bottom bar starts.
    fn titleCell(self: *Workbench, which: Bottom) usize {
        var cell: usize = 1;
        for (std.enums.values(Bottom)) |other| {
            if (other == which) break;
            cell += self.bottomPanel(other).title().len + 2;
        }
        return cell;
    }

    fn titleAt(self: *Workbench, bar: Rect, x: f32) ?Bottom {
        const cell = self.metrics().cols(x - bar.x);
        for (std.enums.values(Bottom)) |which| {
            const start = self.titleCell(which);
            if (cell + 1 >= start and cell < start + self.bottomPanel(which).title().len + 1) return which;
        }
        return null;
    }

    fn rectOf(target: Frame, area: Area) ?Rect {
        return switch (area) {
            .sidebar => target.sidebar,
            .editor => target.editor,
            .bottom => target.bottom,
        };
    }

    /// Where the panel of an area draws: docks have a title bar on top.
    fn contentOf(self: *const Workbench, target: Frame, area: Area) ?Rect {
        const rect = rectOf(target, area) orelse return null;
        return if (area == .editor) rect else rect.splitTop(self.metrics().bar())[1];
    }

    fn look(self: *Workbench) Look {
        if (self.theme_version != self.editor.config_version) {
            const editor = self.editor;
            self.theme = theme_zig.load(editor.loader, editor.config_arena.allocator(), editor.settings.theme, editor);
            self.theme_version = editor.config_version;
        }
        return .{ .theme = &self.theme, .metrics = self.metrics() };
    }

    pub fn draw(self: *Workbench, canvas: Canvas) void {
        const style = self.look();
        const theme = style.theme;
        const target = self.frame();
        canvas.fillRect(.{ .w = self.width, .h = self.height }, theme.border);
        for (std.enums.values(Area)) |area| {
            const rect = rectOf(target, area) orelse continue;
            const focused = self.editor.focus == area;
            canvas.fillRect(rect, theme.background);
            const content = self.contentOf(target, area).?;
            const item = self.panelOf(area);
            if (area != .editor) {
                const bar = rect.splitTop(style.metrics.bar())[0];
                canvas.fillRect(bar, theme.status_bar);
                const active = if (focused) theme.tab_active_text else theme.tab_text;
                const y = style.metrics.barText(bar.y);
                if (area == .sidebar) canvas.drawText(bar.x + style.metrics.cell, y, item.title(), active);
                if (area == .bottom) for (std.enums.values(Bottom)) |which| {
                    const x = bar.x + @as(f32, @floatFromInt(self.titleCell(which))) * style.metrics.cell;
                    canvas.drawText(x, y, self.bottomPanel(which).title(), if (which == self.bottom) active else theme.line_number);
                };
            }
            canvas.setClip(content);
            item.draw(canvas, style, content, focused);
            canvas.setClip(null);
        }
        var buffer: [32]u8 = undefined;
        var notes: [3]prompt_zig.Note = undefined;
        self.prompt.draw(canvas, style, target.editor, self.promptNotes(&buffer, &notes, theme));
        status_bar.draw(canvas, style, self.editor.status(), target.status);
    }

    pub fn handle(self: *Workbench, ev: Event) Outcome {
        const editor = self.editor;
        switch (ev) {
            .quit => return self.run(.quit),
            .redraw, .wake => {},
            .focus => |gained| if (gained) {
                self.files.refresh();
                return .{ .request = editor.checkDisk() };
            },
            .key => |press| return self.onKey(press),
            .text => |text| if (!self.swallow_text) {
                if (self.prompt.kind != null) {
                    self.prompt.typeText(text);
                    self.promptChanged();
                } else if (editor.focus == .editor) {
                    editor.typeText(text);
                }
            },
            .mouse_down => |mouse| return self.onMouseDown(mouse),
            .mouse_move => |mouse| {
                const x = mouse.x * self.density;
                const y = mouse.y * self.density;
                if (self.dragging) |edge| {
                    editor.dock(if (edge == .sidebar) .sidebar else .bottom).size = self.frame().sizeAt(edge, self.metrics(), x, y);
                    return .{};
                }
                const area = self.captured orelse return .{ .redraw = false };
                var scaled = mouse;
                scaled.x = x;
                scaled.y = y;
                return self.toPanel(area, .{ .mouse_move = scaled });
            },
            .mouse_up => |mouse| {
                self.dragging = null;
                const area = self.captured orelse return .{ .redraw = false };
                self.captured = null;
                var scaled = mouse;
                scaled.x *= self.density;
                scaled.y *= self.density;
                return self.toPanel(area, .{ .mouse_up = scaled });
            },
            .wheel => |wheel| {
                if (wheel.mods.ctrl) {
                    if (wheel.dy == 0) return .{ .redraw = false };
                    return self.run(if (wheel.dy > 0) .zoom_in else .zoom_out);
                }
                var scaled = wheel;
                scaled.x *= self.density;
                scaled.y *= self.density;
                const area = self.areaAt(scaled.x, scaled.y) orelse return .{ .redraw = false };
                return self.toPanel(area, .{ .wheel = scaled });
            },
            .drop_file => |path| editor.open(path),
        }
        return .{};
    }

    fn onKey(self: *Workbench, press: event.KeyPress) Outcome {
        const editor = self.editor;
        const command = keymap.lookup(editor.bindings, press.key, press.mods);
        if (self.prompt.kind) |kind| {
            if (command) |found| if (kind == .find or kind == .replace or kind == .find_in_project) {
                if (worksInFind(found)) {
                    self.swallow_text = true;
                    return self.run(found);
                }
            };
            self.swallow_text = command != null or switch (press.key) {
                .enter, .escape, .up, .down => true,
                else => false,
            };
            switch (self.prompt.key(press, editor.bindings)) {
                .editing => self.promptChanged(),
                .cancel => self.endFind(),
                .submit => |text| return self.submitted(kind, text, press.mods.shift),
            }
            return .{};
        }
        const handled = self.toPanel(editor.focus, .{ .key = press });
        self.swallow_text = handled.redraw;
        if (handled.redraw) return handled;
        self.swallow_text = command != null;
        const found = command orelse return .{ .redraw = false };
        return self.run(found);
    }

    /// Runs a command. A prompt it asks for is opened here.
    fn run(self: *Workbench, command: commands.Command) Outcome {
        const request = commands.run(self.editor, command) orelse return .{};
        if (request == .prompt) {
            self.ask(request.prompt);
            return .{};
        }
        return .{ .request = request };
    }

    /// Commands that work while find, replace or find in project is open.
    fn worksInFind(command: commands.Command) bool {
        return switch (command) {
            .find, .replace, .find_next, .find_prev, .replace_all, .toggle_match_case, .toggle_whole_word => true,
            else => false,
        };
    }

    fn ask(self: *Workbench, kind: editor_zig.PromptKind) void {
        const editor = self.editor;
        const find = &editor.find;
        if (kind != .find and kind != .replace) self.endFind();
        self.replacing = false;
        const label: []const u8, const initial: []const u8 = switch (kind) {
            .find, .replace => blk: {
                const needle = find.begin(editor.doc());
                editor.afterEdit();
                if (kind == .find or needle.len == 0) {
                    self.replacing = kind == .replace;
                    break :blk .{ if (self.replacing) "Replace:" else "Find:", needle };
                }
                break :blk .{ "Replace with:", find.replacement.items };
            },
            .goto_line => .{ "Go to line:", "" },
            .find_in_project => blk: {
                const project = &editor.project.needle;
                if (!Find.copySelection(editor.allocator, editor.doc(), project) and project.items.len == 0) {
                    project.appendSlice(editor.allocator, find.needle.items) catch {};
                }
                break :blk .{ "Find in folder:", project.items };
            },
            .language => .{ "Language:", "" },
            .new_file, .new_folder, .rename => unreachable,
        };
        const choices = if (kind == .language) editor.language_names else &.{};
        self.prompt.open(if (self.replacing) .find else kind, label, initial, choices) catch {};
    }

    /// Find follows the text of its prompt as it is typed.
    fn promptChanged(self: *Workbench) void {
        const editor = self.editor;
        switch (self.prompt.kind orelse return) {
            .find => {
                editor.find.setNeedle(editor.doc(), self.prompt.text());
                editor.afterEdit();
            },
            .replace => editor.find.setReplacement(self.prompt.text()),
            else => {},
        }
    }

    fn submitted(self: *Workbench, kind: editor_zig.PromptKind, text: []const u8, shift: bool) Outcome {
        const editor = self.editor;
        switch (kind) {
            .new_file, .new_folder, .rename => self.files.submit(text),
            .find => {
                if (!self.replacing) return self.run(if (shift) .find_prev else .find_next);
                self.ask(.replace);
            },
            .replace => return self.run(.replace_next),
            .goto_line => editor.gotoLine(text),
            .language => editor.setLanguage(text),
            .find_in_project => {
                editor.findInProject(text);
                if (editor.project.running) {
                    self.bottom = .search;
                    editor.focusArea(.bottom);
                }
            },
        }
        return .{};
    }

    /// Stops highlighting matches once find and replace are closed.
    fn endFind(self: *Workbench) void {
        if (!self.editor.find.shown) return;
        self.editor.find.shown = false;
        self.editor.afterEdit();
    }

    fn closePrompt(self: *Workbench) void {
        self.prompt.close();
        self.endFind();
    }

    /// "3 of 12" for find and replace, and the options.
    fn promptNotes(self: *Workbench, buffer: []u8, notes: *[3]prompt_zig.Note, theme: *const theme_zig.Theme) []const prompt_zig.Note {
        const kind = self.prompt.kind orelse return &.{};
        if (kind != .find and kind != .replace and kind != .find_in_project) return &.{};
        const find = &self.editor.find;
        const count = find.matches.items.len;
        const counted = if (kind == .find_in_project or find.needle.items.len == 0)
            ""
        else if (count == 0)
            "No matches"
        else if (find.selected(self.editor.doc())) |index|
            std.fmt.bufPrint(buffer, "{d} of {d}", .{ index + 1, count }) catch ""
        else
            std.fmt.bufPrint(buffer, "{d} matches", .{count}) catch "";
        notes.* = .{
            .{ .text = counted, .color = theme.line_number_current },
            .{ .text = "Aa", .color = if (find.options.match_case) theme.accent else theme.line_number },
            .{ .text = "W", .color = if (find.options.whole_word) theme.accent else theme.line_number },
        };
        return if (counted.len == 0) notes[1..] else notes;
    }

    fn onMouseDown(self: *Workbench, mouse: event.MouseDown) Outcome {
        var scaled = mouse;
        scaled.x *= self.density;
        scaled.y *= self.density;
        if (self.prompt.kind != null) self.closePrompt();
        const target = self.frame();
        if (target.edgeAt(scaled.x, scaled.y)) |edge| {
            self.dragging = edge;
            return .{};
        }
        if (target.bottom) |rect| if (rect.splitTop(self.metrics().bar())[0].contains(scaled.x, scaled.y)) {
            self.bottom = self.titleAt(rect, scaled.x) orelse self.bottom;
            self.editor.focus = .bottom;
            return .{};
        };
        const area = self.areaAt(scaled.x, scaled.y) orelse return .{ .redraw = false };
        self.editor.focus = area;
        self.captured = area;
        return self.toPanel(area, .{ .mouse_down = scaled });
    }

    fn areaAt(self: *const Workbench, x: f32, y: f32) ?Area {
        const target = self.frame();
        for (std.enums.values(Area)) |area| {
            const content = self.contentOf(target, area) orelse continue;
            if (content.contains(x, y)) return area;
        }
        return null;
    }

    /// Passes an event to a panel. `redraw` tells whether it used it.
    fn toPanel(self: *Workbench, area: Area, ev: Event) Outcome {
        const content = self.contentOf(self.frame(), area) orelse return .{ .redraw = false };
        const handled = self.panelOf(area).handle(ev, self.metrics(), content);
        return .{ .request = handled.request, .redraw = handled.used };
    }

    /// The answer to an `ask` request.
    pub fn answer(self: *Workbench, question: editor_zig.Question, choice: editor_zig.Answer) ?Request {
        if (question == .delete) {
            self.files.confirmDelete(choice == .yes);
            return null;
        }
        return self.editor.answer(choice);
    }

    /// Clipboard text after a `paste` request.
    pub fn paste(self: *Workbench, text: []const u8) void {
        if (self.prompt.kind != null) {
            self.prompt.typeText(text);
            self.promptChanged();
        } else self.editor.paste(text);
    }

    /// Milliseconds until the screen must change by itself, if ever.
    pub fn timeLeft(self: *const Workbench) ?u64 {
        return self.editor.messageTimeLeft();
    }
};
