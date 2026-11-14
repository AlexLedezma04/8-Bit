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

    while (true) {
        renderer.clear(theme.background);
        renderer.present();

        const ev = input.wait() orelse break;
        if (ev == .quit) break;
    }
}
