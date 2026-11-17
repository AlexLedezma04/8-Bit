//! The UI: layout math, the canvas and panel interfaces, widgets, panels and
//! the workbench. All of it draws on a `Canvas`, so none of it needs SDL.

pub const canvas = @import("canvas.zig");
pub const layout = @import("layout.zig");
pub const panel = @import("panel.zig");
pub const theme = @import("theme.zig");
pub const workbench = @import("workbench.zig");
pub const list = @import("widgets/list.zig");
pub const menu = @import("widgets/menu.zig");
pub const scrollbar = @import("widgets/scrollbar.zig");
pub const minimap = @import("widgets/minimap.zig");
pub const prompt = @import("widgets/prompt.zig");
pub const tabs = @import("widgets/tabs.zig");
pub const editor_view = @import("panels/editor_view.zig");
pub const file_tree = @import("panels/file_tree.zig");
pub const git = @import("panels/git.zig");
pub const welcome = @import("panels/welcome.zig");
pub const status_bar = @import("panels/status_bar.zig");
pub const terminal = @import("panels/terminal.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
