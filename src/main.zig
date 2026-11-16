//! Wires platform, editor and UI together.
const std = @import("std");
const Window = @import("platform/window.zig").Window;
const Renderer = @import("platform/renderer.zig").Renderer;
const input = @import("platform/input.zig");
const clipboard = @import("platform/clipboard.zig");
const dialog = @import("platform/dialog.zig");
const fs = @import("platform/fs.zig");
const editor_zig = @import("editor/editor.zig");
const Editor = editor_zig.Editor;
const Request = editor_zig.Request;
const Workbench = @import("ui/workbench.zig").Workbench;

const App = struct {
    window: Window,
    renderer: Renderer,
    editor: Editor,
    workbench: Workbench,
    mailbox: editor_zig.Mailbox,
    quit: bool = false,

    fn draw(self: *App) void {
        var title: [128]u8 = undefined;
        self.window.setTitle(self.editor.title(&title));
        const size = self.renderer.outputSize();
        self.renderer.scale = @floatFromInt(self.editor.zoom);
        self.workbench.width = size.w;
        self.workbench.height = size.h;
        self.workbench.density = self.window.pixelDensity();
        self.workbench.draw(self.renderer.canvas());
        self.renderer.present();
    }

    /// Returns false when the event cannot have changed what is on screen.
    fn handle(self: *App, ev: @import("platform/event.zig").Event) bool {
        if (ev == .wake) {
            while (self.mailbox.take()) |posted| self.fulfil(self.editor.receive(posted));
            return true;
        }
        const outcome = self.workbench.handle(ev);
        self.fulfil(outcome.request);
        return outcome.redraw or outcome.request != null;
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
                self.workbench.paste(text);
                break :blk null;
            },
            .pick => |pick| blk: {
                dialog.show(pick, &self.window);
                break :blk null;
            },
            .prompt => unreachable, // opened by the workbench
            .ask => |question| self.workbench.answer(question.question, dialog.ask(&self.window, question.question, question.name) orelse blk: {
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
        .editor = try .init(init.gpa, init.io),
        .workbench = undefined,
        .mailbox = .{ .allocator = init.gpa, .io = init.io, .wake = input.wake },
    };
    defer app.mailbox.deinit();
    defer app.editor.deinit();
    app.workbench.init(&app.editor);
    defer app.workbench.deinit();
    dialog.init(&app.mailbox);
    app.editor.mailbox = &app.mailbox;
    app.editor.environ = init.environ_map;

    // A high-DPI screen starts at a matching zoom.
    app.editor.screen_zoom = @intFromFloat(std.math.clamp(@round(app.window.displayScale()), Editor.min_zoom, Editor.max_zoom));
    const config_dir = fs.configDir(init.gpa, init.environ_map);
    defer if (config_dir) |dir| init.gpa.free(dir);
    app.editor.loader.dir = config_dir;
    app.editor.reloadConfig();
    if (args.len > 1) {
        if (fs.isDir(init.io, args[1])) app.editor.openFolder(args[1]) else app.editor.open(args[1]);
    }

    // Sleep until an event comes, handle all waiting events, then draw one
    // frame only if something changed. Nothing runs while the user does
    // nothing; a status message or a pending git diff only sets a timeout.
    var dirty = true;
    while (!app.quit) {
        app.editor.now_ms = input.now();
        if (app.editor.tick()) dirty = true;
        if (dirty) app.draw();

        var next = input.wait(app.workbench.timeLeft());
        app.editor.now_ms = input.now();
        // No event means the message timed out and must be removed.
        dirty = next == null;
        while (next) |ev| : (next = input.poll()) {
            if (app.handle(ev)) dirty = true;
            if (app.quit) break;
        }
    }
}
