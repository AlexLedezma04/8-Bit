//! Test root for SDL-free code: core, editor and ui.
test {
    _ = @import("core/buffer.zig");
    _ = @import("core/cursor.zig");
    _ = @import("core/utf8.zig");
    _ = @import("editor/editor.zig");
    _ = @import("editor/commands.zig");
    _ = @import("ui/theme.zig");
}
