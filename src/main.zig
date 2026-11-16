const Window = @import("platform/window.zig").Window;
const Renderer = @import("platform/renderer.zig").Renderer;
const input = @import("platform/input.zig");
const Theme = @import("ui/theme.zig").Theme;

pub fn main() !void {
    var window = try Window.init(.{});
    defer window.deinit();
    var renderer = try Renderer.init(&window);
    defer renderer.deinit();

    const theme: Theme = .{};

    // Sleep until an event comes, handle all waiting events, then draw one
    // frame only if something changed.
    var dirty = true;
    while (true) {
        if (dirty) {
            draw(&renderer, theme);
            dirty = false;
        }
        var event: ?input.InputEvent = input.wait();
        while (event) |ev| : (event = input.poll()) switch (ev) {
            .quit => return,
            .redraw => dirty = true,
            .other => {},
        };
    }
}

fn draw(renderer: *Renderer, theme: Theme) void {
    const cell = renderer.cellSize();
    renderer.clear(theme.background);
    renderer.drawText(cell, cell, "8-Bit \u{2500}\u{2500} h\u{E9}llo, w\u{F6}rld! \u{BF}Qu\u{E9} tal?", theme.text);
    renderer.drawText(cell, cell * 3, "\u{250C}\u{2500}\u{2500}\u{2510} fn main() !void {}", theme.syntax.keyword);
    renderer.drawText(cell, cell * 4, "\u{2514}\u{2500}\u{2500}\u{2518} 0123456789 \u{1F600}", theme.syntax.number);
    renderer.present();
}
