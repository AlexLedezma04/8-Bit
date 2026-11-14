//! Integration tests: check that modules work together, through the same
//! public API the app uses. Add each new test file below.

test {
    _ = @import("editor_test.zig");
}
