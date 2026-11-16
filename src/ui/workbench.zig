//! The whole window: places the panels, draws them, and routes input. A key
//! goes to the prompt if it is open, else to the focused panel, else to the
//! key bindings. A click gives its panel focus. Dock edges can be dragged.
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
const Prompt = @import("widgets/prompt.zig").Prompt;
const EditorView = @import("panels/editor_view.zig").EditorView;
const FileTree = @import("panels/file_tree.zig").FileTree;
const Messages = @import("panels/messages.zig").Messages;
const status_bar = @import("panels/status_bar.zig");
const event = @import("../platform/event.zig");
const Event = event.Event;
const Area = editor_zig.Area;

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
    view: EditorView,
    files: FileTree,
    messages: Messages,
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
            .bottom => .of(Messages, &self.messages),
        };
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
                canvas.drawText(bar.x + style.metrics.cell, style.metrics.barText(bar.y), item.title(), if (focused) theme.tab_active_text else theme.tab_text);
            }
            canvas.setClip(content);
            item.draw(canvas, style, content, focused);
            canvas.setClip(null);
        }
        self.prompt.draw(canvas, style, target.editor);
        status_bar.draw(canvas, style, self.editor.status(), target.status);
    }

    pub fn handle(self: *Workbench, ev: Event) Outcome {
        const editor = self.editor;
        switch (ev) {
            .quit => return .{ .request = commands.run(editor, .quit) },
            .redraw, .wake => {},
            .focus => |gained| if (gained) {
                self.files.refresh();
                return .{ .request = editor.checkDisk() };
            },
            .key => |press| return self.onKey(press),
            .text => |text| if (!self.swallow_text) {
                if (self.prompt.kind != null) {
                    self.prompt.typeText(text);
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
                    return .{ .request = commands.run(editor, if (wheel.dy > 0) .zoom_in else .zoom_out) };
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
            self.swallow_text = command != null or switch (press.key) {
                .enter, .escape, .up, .down => true,
                else => false,
            };
            switch (self.prompt.key(press, editor.bindings)) {
                .editing, .cancel => {},
                .submit => |text| self.files.submit(kind, text),
            }
            return .{};
        }
        const handled = self.toPanel(editor.focus, .{ .key = press });
        self.swallow_text = handled.redraw;
        if (handled.redraw) return handled;
        self.swallow_text = command != null;
        const found = command orelse return .{ .redraw = false };
        return .{ .request = commands.run(editor, found) };
    }

    fn onMouseDown(self: *Workbench, mouse: event.MouseDown) Outcome {
        var scaled = mouse;
        scaled.x *= self.density;
        scaled.y *= self.density;
        if (self.prompt.kind != null) self.prompt.close();
        const target = self.frame();
        if (target.edgeAt(scaled.x, scaled.y)) |edge| {
            self.dragging = edge;
            return .{};
        }
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
        if (self.prompt.kind != null) self.prompt.typeText(text) else self.editor.paste(text);
    }

    /// Milliseconds until the screen must change by itself, if ever.
    pub fn timeLeft(self: *const Workbench) ?u64 {
        return self.editor.messageTimeLeft();
    }
};
