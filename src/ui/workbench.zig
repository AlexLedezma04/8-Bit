//! The whole window: places the panels, draws them, and routes input. A key
//! goes to the open menu or prompt, else to the focused panel, else to the
//! key bindings. A click gives its panel focus. Each dock has a tab bar of
//! its panels, and its edge can be dragged. Prompts that commands ask for
//! are opened here. While no file is open the editor area shows what to do
//! next, and the recent folders while no folder is open either.
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
const menu_zig = @import("widgets/menu.zig");
const Menu = menu_zig.Menu;
const Find = @import("../editor/find.zig").Find;
const EditorView = @import("panels/editor_view.zig").EditorView;
const FileTree = @import("panels/file_tree.zig").FileTree;
const Messages = @import("panels/messages.zig").Messages;
const Search = @import("panels/search.zig").Search;
const GitPanel = @import("panels/git.zig").GitPanel;
const TerminalPanel = @import("panels/terminal.zig").TerminalPanel;
const Welcome = @import("panels/welcome.zig").Welcome;
const tabs = @import("widgets/tabs.zig");
const status_bar = @import("panels/status_bar.zig");
const event = @import("../platform/event.zig");
const Event = event.Event;
const Area = editor_zig.Area;
const SidePanel = editor_zig.SidePanel;
const BottomPanel = editor_zig.BottomPanel;

/// Rows scrolled per step of the mouse wheel.
const wheel_rows = 3;

pub const Outcome = struct {
    request: ?Request = null,
    /// False when nothing on screen can have changed.
    redraw: bool = true,
};

pub const Workbench = struct {
    editor: *Editor,
    theme: theme_zig.Theme = undefined,
    /// The `config_version` of the editor that `theme` was loaded for.
    theme_version: ?u32 = null,
    prompt: Prompt,
    menu: Menu = .{},
    welcome: Welcome,
    view: EditorView,
    files: FileTree,
    messages: Messages,
    search: Search,
    git: GitPanel,
    terminal: TerminalPanel,
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
    /// Where the mouse is, in window pixels, for hover colors.
    mouse: ?[2]f32 = null,
    /// Wheel rows not scrolled yet: x, y.
    wheel_rest: [2]f32 = .{ 0, 0 },

    /// In place, because the panels point into it.
    pub fn init(self: *Workbench, editor: *Editor) void {
        self.* = .{
            .editor = editor,
            .prompt = .init(editor.allocator),
            .welcome = .{ .editor = editor },
            .view = .{ .editor = editor, .menu = &self.menu },
            .files = .{ .editor = editor, .prompt = &self.prompt, .menu = &self.menu },
            .messages = .{ .editor = editor },
            .search = .{ .editor = editor },
            .git = .{ .editor = editor, .prompt = &self.prompt },
            .terminal = .{ .editor = editor },
        };
    }

    pub fn deinit(self: *Workbench) void {
        self.git.deinit();
        self.terminal.deinit();
        self.files.deinit();
        self.view.deinit();
        self.prompt.deinit();
    }

    fn metrics(self: *const Workbench) Metrics {
        return .init(self.editor.zoom);
    }

    pub fn frame(self: *const Workbench) Frame {
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
            .sidebar => self.sidePanel(self.editor.sidePanel()),
            .editor => if (self.editor.empty()) .of(Welcome, &self.welcome) else .of(EditorView, &self.view),
            .bottom => self.bottomPanel(self.editor.bottom_panel),
        };
    }

    fn sidePanel(self: *Workbench, which: SidePanel) Panel {
        return switch (which) {
            .files => .of(FileTree, &self.files),
            .git => .of(GitPanel, &self.git),
        };
    }

    fn bottomPanel(self: *Workbench, which: BottomPanel) Panel {
        return switch (which) {
            .messages => .of(Messages, &self.messages),
            .search => .of(Search, &self.search),
            .terminal => .of(TerminalPanel, &self.terminal),
        };
    }

    const max_dock_panels = 4;

    /// One tab per panel of a dock, and the index of the one shown. The git
    /// panel, the last of the sidebar, has no tab outside a repository.
    fn dockTabs(self: *Workbench, area: Area, items: *[max_dock_panels]tabs.Item) struct { []const tabs.Item, usize } {
        switch (area) {
            inline .sidebar, .bottom => |dock| {
                const Which = if (dock == .sidebar) SidePanel else BottomPanel;
                const values = comptime std.enums.values(Which);
                inline for (values, 0..) |which, i| {
                    const shown = if (dock == .sidebar) self.sidePanel(which) else self.bottomPanel(which);
                    items[i] = .{ .title = shown.title(), .closable = false };
                }
                const active = if (dock == .sidebar) self.editor.sidePanel() else self.editor.bottom_panel;
                const count = if (dock == .sidebar and !self.editor.git.ready()) values.len - 1 else values.len;
                return .{ items[0..count], @backingInt(active) };
            },
            .editor => unreachable,
        }
    }

    fn selectDock(self: *Workbench, area: Area, index: usize) void {
        switch (area) {
            .sidebar => self.editor.showSide(@fromBackingInt(@intCast(index))),
            .bottom => self.editor.showBottom(@fromBackingInt(@intCast(index))),
            .editor => unreachable,
        }
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
        return .{ .theme = &self.theme, .metrics = self.metrics(), .mouse = self.mouse };
    }

    pub fn draw(self: *Workbench, canvas: Canvas) void {
        const style = self.look();
        const theme = style.theme;
        const target = self.frame();
        canvas.fillRect(.{ .w = self.width, .h = self.height }, theme.background);
        for (std.enums.values(Area)) |area| {
            const rect = rectOf(target, area) orelse continue;
            const focused = self.editor.focus == area;
            canvas.fillRect(rect, if (area == .editor) theme.background else theme.panel);
            const content = self.contentOf(target, area).?;
            const item = self.panelOf(area);
            if (area != .editor) {
                var items: [max_dock_panels]tabs.Item = undefined;
                const shown, const active = self.dockTabs(area, &items);
                tabs.draw(canvas, style, rect.splitTop(style.metrics.bar())[0], .dock, shown, active, focused);
            }
            canvas.setClip(content);
            item.draw(canvas, style, content, focused);
            canvas.setClip(null);
        }
        var buffer: [32]u8 = undefined;
        var notes: [3]prompt_zig.Note = undefined;
        self.prompt.draw(canvas, style, target.editor, self.promptNotes(&buffer, &notes, theme));
        status_bar.draw(canvas, style, self.editor.status(), target.status);
        self.menu.draw(canvas, style, self.window());
    }

    fn window(self: *const Workbench) Rect {
        return .{ .w = self.width, .h = self.height };
    }

    /// Takes every input event while the menu is open.
    fn toMenu(self: *Workbench, ev: Event) Outcome {
        if (ev == .mouse_up) self.captured = null;
        const outcome = switch (ev) {
            .key => |press| blk: {
                self.swallow_text = true;
                break :blk self.menu.key(press);
            },
            .mouse_down => |mouse| self.menu.click(self.metrics(), self.window(), mouse.x * self.density, mouse.y * self.density),
            .mouse_move => |mouse| blk: {
                self.menu.mouseMove(self.metrics(), self.window(), mouse.x * self.density, mouse.y * self.density);
                break :blk .open;
            },
            else => .open,
        };
        return switch (outcome) {
            .chosen => |request| self.fulfilHere(request),
            else => .{},
        };
    }

    /// A prompt is opened here; anything else goes to `main.zig`.
    fn fulfilHere(self: *Workbench, request: ?Request) Outcome {
        const found = request orelse return .{};
        if (found == .prompt) {
            self.ask(found.prompt);
            return .{};
        }
        return .{ .request = found };
    }

    pub fn handle(self: *Workbench, ev: Event) Outcome {
        const editor = self.editor;
        if (ev == .mouse_move) self.mouse = .{ ev.mouse_move.x * self.density, ev.mouse_move.y * self.density };
        if (self.menu.isOpen()) switch (ev) {
            .key, .text, .mouse_down, .mouse_move, .mouse_up, .wheel => return self.toMenu(ev),
            else => {},
        };
        switch (ev) {
            .quit => return self.run(.quit),
            .redraw, .wake => {},
            .focus => |gained| if (gained) {
                editor.diskChanged();
                return .{ .request = editor.checkDisk() };
            },
            .key => |press| return self.onKey(press),
            .text => |text| if (!self.swallow_text) {
                if (self.prompt.kind != null) {
                    self.prompt.typeText(text);
                    self.promptChanged();
                } else return self.toPanel(editor.focus, ev);
            },
            .mouse_down => |mouse| return self.onMouseDown(mouse),
            .mouse_move => |mouse| {
                const x = mouse.x * self.density;
                const y = mouse.y * self.density;
                if (self.dragging) |edge| {
                    editor.dock(if (edge == .sidebar) .sidebar else .bottom).size = self.frame().sizeAt(edge, self.metrics(), x, y);
                    return .{};
                }
                // Without a capture only hover colors change.
                const area = self.captured orelse return .{};
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
                const rows = self.wheelRows(wheel);
                if (rows[0] == 0 and rows[1] == 0) return .{ .redraw = false };
                if (wheel.mods.ctrl) return self.run(if (rows[1] > 0) .zoom_in else .zoom_out);
                var scaled = wheel;
                scaled.x *= self.density;
                scaled.y *= self.density;
                scaled.dx = rows[0];
                scaled.dy = rows[1];
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
        return self.fulfilHere(commands.run(self.editor, command));
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
            .new_file, .new_folder, .rename, .branch => unreachable,
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
            .branch => editor.git.createBranch(text),
            .find_in_project => {
                editor.findInProject(text);
                if (editor.project.running) editor.showBottom(.search);
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
        // The terminal button hides a shown terminal even without focus.
        if (status_bar.terminalButton(self.metrics(), target.status).contains(scaled.x, scaled.y)) {
            if (!self.editor.status().terminal) return self.run(.toggle_terminal);
            self.editor.toggleDock(.bottom);
            return .{};
        }
        inline for (.{ Area.sidebar, Area.bottom }) |area| if (rectOf(target, area)) |rect| {
            const bar = rect.splitTop(self.metrics().bar())[0];
            if (bar.contains(scaled.x, scaled.y)) {
                var items: [max_dock_panels]tabs.Item = undefined;
                const shown, const active = self.dockTabs(area, &items);
                const hit = tabs.hit(bar, self.metrics(), .dock, shown, active, scaled.x, scaled.y);
                if (hit) |found| self.selectDock(area, found.index) else self.editor.focus = area;
                return .{};
            }
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

    /// Wheel steps as whole rows. Smooth wheels and touchpads send parts of
    /// a step; they add up until they make a row.
    fn wheelRows(self: *Workbench, wheel: event.Wheel) [2]f32 {
        var rows: [2]f32 = undefined;
        for (&self.wheel_rest, &rows, [2]f32{ wheel.dx, wheel.dy }) |*rest, *whole, steps| {
            rest.* += steps * wheel_rows;
            whole.* = @trunc(rest.*);
            rest.* -= whole.*;
        }
        return rows;
    }

    /// Passes an event to a panel. `redraw` tells whether it used it.
    fn toPanel(self: *Workbench, area: Area, ev: Event) Outcome {
        const content = self.contentOf(self.frame(), area) orelse return .{ .redraw = false };
        const handled = self.panelOf(area).handle(ev, self.metrics(), content);
        var outcome = self.fulfilHere(handled.request);
        outcome.redraw = handled.used or outcome.request != null;
        return outcome;
    }

    /// The answer to an `ask` request.
    pub fn answer(self: *Workbench, question: editor_zig.Question, choice: editor_zig.Answer) ?Request {
        switch (question) {
            .delete => self.files.confirmDelete(choice == .yes),
            .discard => self.git.confirmDiscard(choice == .yes),
            .save, .reload => return self.editor.answer(choice),
        }
        return null;
    }

    /// Clipboard text after a `paste` request.
    pub fn paste(self: *Workbench, text: []const u8) void {
        const editor = self.editor;
        if (self.prompt.kind != null) {
            self.prompt.typeText(text);
            self.promptChanged();
        } else if (editor.focus == .bottom and editor.bottom_panel == .terminal) {
            self.terminal.paste(text);
        } else editor.paste(text);
    }

    /// Milliseconds until the screen must change by itself, if ever.
    pub fn timeLeft(self: *const Workbench) ?u64 {
        return self.editor.timeLeft();
    }
};
