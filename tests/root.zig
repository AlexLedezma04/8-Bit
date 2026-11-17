//! Integration tests: check that modules work together, through the same
//! public API the app uses. Add each new test file below.

test {
    _ = @import("config_test.zig");
    _ = @import("editor_session_test.zig");
    _ = @import("git_test.zig");
    _ = @import("look_test.zig");
    _ = @import("search_test.zig");
    _ = @import("syntax_test.zig");
    _ = @import("terminal_test.zig");
    _ = @import("text_draw_test.zig");
    _ = @import("text_model_test.zig");
    _ = @import("workbench_test.zig");
    _ = @import("workspace_test.zig");
}
