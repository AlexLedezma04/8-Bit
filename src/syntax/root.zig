//! Language detection, grammars and highlighting. SDL-free.
//! Import every file of this folder here, so `zig build test` runs its tests.

pub const grammar = @import("grammar.zig");
pub const language = @import("language.zig");
pub const syntax = @import("syntax.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
