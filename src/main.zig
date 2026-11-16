//! Wires platform, editor and UI together.
const std = @import("std");
const Window = @import("platform/window.zig").Window;
const Renderer = @import("platform/renderer.zig").Renderer;
const input = @import("platform/input.zig");
const clipboard = @import("platform/clipboard.zig");
const dialog = @import("platform/dialog.zig");
const event = @import("platform/event.zig");
const editor_zig = @import("editor/editor.zig");
const Editor = editor_zig.Editor;
const Request = editor_zig.Request;
const commands = @import("editor/commands.zig");
const keymap = @import("editor/keymap.zig");
const decoration = @import("editor/decoration.zig");
const Theme = @import("ui/theme.zig").Theme;
const layout_zig = @import("ui/layout.zig");
const Layout = layout_zig.Layout;
const editor_view = @import("ui/panels/editor_view.zig");
const status_bar = @import("ui/panels/status_bar.zig");

/// Rows scrolled per step of the mouse wheel.
const wheel_rows = 3;

const App = struct {
    window: Window,
    renderer: Renderer,
    editor: Editor,
    mailbox: dialog.Mailbox,
    theme: Theme = .{},
    layout: Layout = undefined,
    /// A key press ran a command, so the text it also types is dropped.
    swallow_text: bool = false,
    quit: bool = false,

    /// Lays out the window for the current size, zoom and document.
    fn updateLayout(self: *App) void {
        const size = self.renderer.outputSize();
        self.renderer.scale = @floatFromInt(self.editor.zoom);
        self.layout = .init(
            size.w,
            size.h,
            .init(self.editor.zoom),
            self.editor.doc.buffer.lineCount(),
            decoration.gutterTextWidth(self.editor.decorations.items),
        );
        self.editor.view.cols = self.layout.cols;
        self.editor.view.rows = self.layout.rows;
    }

    fn draw(self: *App) void {
        var title: [128]u8 = undefined;
        self.window.setTitle(self.editor.title(&title));
        self.renderer.clear(self.theme.background);
        editor_view.draw(&self.renderer, &self.theme, &self.editor, &self.layout);
        status_bar.draw(&self.renderer, &self.theme, self.editor.status(), &self.layout);
        self.renderer.present();
    }

    /// Returns false when the event cannot have changed what is on screen.
    fn handle(self: *App, ev: event.Event) bool {
        switch (ev) {
            .quit => self.fulfil(commands.run(&self.editor, .quit)),
            .redraw, .focus => {},
            .mouse_up => return false,
            .key => |press| {
                const command = keymap.lookup(&keymap.default, press.key, press.mods);
                self.swallow_text = command != null;
                if (command) |found| self.fulfil(commands.run(&self.editor, found));
            },
            .text => |text| if (!self.swallow_text) self.editor.typeText(text),
            .mouse_down => |mouse| if (mouse.button == .left) {
                const cell = self.cellAt(mouse.x, mouse.y);
                self.editor.mouseDown(cell.x, cell.y, mouse.clicks, mouse.mods.shift);
            },
            .mouse_move => |mouse| {
                if (!mouse.left_down) return false;
                const cell = self.cellAt(mouse.x, mouse.y);
                self.editor.mouseDrag(cell.x, cell.y);
            },
            .wheel => |wheel| self.onWheel(wheel),
            .drop_file => |path| self.fulfil(self.editor.open(path)),
            .wake => while (self.mailbox.take()) |posted| self.fulfil(self.editor.receive(posted)),
        }
        return true;
    }

    fn onWheel(self: *App, wheel: event.Wheel) void {
        if (wheel.mods.ctrl) {
            if (wheel.dy != 0) self.fulfil(commands.run(&self.editor, if (wheel.dy > 0) .zoom_in else .zoom_out));
            return;
        }
        const rows: isize = @intFromFloat(-wheel.dy * wheel_rows);
        const cols: isize = @intFromFloat(wheel.dx * wheel_rows);
        // Shift turns the wheel sideways.
        if (wheel.mods.shift) self.editor.scroll(0, rows) else self.editor.scroll(rows, cols);
    }

    /// Mouse positions are in window units; the layout is in pixels.
    fn cellAt(self: *const App, x: f32, y: f32) layout_zig.Cell {
        const density = self.window.pixelDensity();
        return self.layout.cellAt(x * density, y * density);
    }

    /// Does what the editor asked for. An answer can lead to a new request.
    fn fulfil(self: *App, first: ?Request) void {
        var next = first;
        while (next) |request| next = switch (request) {
            .quit => {
                self.quit = true;
                return;
            },
            .copy => |text| blk: {
                clipboard.set(text);
                break :blk null;
            },
            .paste => blk: {
                const text = clipboard.get(self.editor.allocator) orelse break :blk null;
                defer self.editor.allocator.free(text);
                self.editor.paste(text);
                break :blk null;
            },
            .pick => |pick| blk: {
                dialog.show(pick, &self.window);
                break :blk null;
            },
            .confirm => self.editor.answer(dialog.confirmSave(&self.window, self.editor.name()) orelse blk: {
                self.editor.notify("Could not show a message box", .{});
                break :blk .cancel;
            }),
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var window = try Window.init(.{});
    defer window.deinit();
    var renderer = try Renderer.init(&window);
    defer renderer.deinit();

    var app: App = .{
        .window = window,
        .renderer = renderer,
        .editor = .init(init.gpa, init.io),
        .mailbox = .{ .allocator = init.gpa, .io = init.io, .wake = input.wake },
    };
    defer app.editor.deinit();
    defer app.mailbox.deinit();
    dialog.init(&app.mailbox);

    // A high-DPI screen starts at a matching zoom.
    app.editor.default_zoom = @intFromFloat(std.math.clamp(@round(2 * app.window.displayScale()), Editor.min_zoom, Editor.max_zoom));
    app.editor.zoom = app.editor.default_zoom;
    app.updateLayout();
    if (args.len > 1) app.fulfil(app.editor.open(args[1]));

    // Sleep until an event comes, handle all waiting events, then draw one
    // frame only if something changed. Nothing runs while the user does
    // nothing; a status message only sets a timeout so it can disappear.
    var dirty = true;
    while (!app.quit) {
        app.editor.now_ms = input.now();
        if (dirty) {
            app.updateLayout();
            app.draw();
        }

        var next = input.wait(app.editor.messageTimeLeft());
        app.editor.now_ms = input.now();
        // No event means the message timed out and must be removed.
        dirty = next == null;
        while (next) |ev| : (next = input.poll()) {
            if (app.handle(ev)) dirty = true;
            if (app.quit) break;
        }
    }
}
