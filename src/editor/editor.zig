//! Top-level editor state (open documents, mode). No SDL types here.
const Document = @import("../core/edit.zig").Document;

pub const Editor = struct {
    doc: Document,
};
