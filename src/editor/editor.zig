//! Top-level editor state (open buffers, mode). No SDL types here.
const Buffer = @import("../core/buffer.zig").Buffer;
const Cursor = @import("../core/cursor.zig").Cursor;

pub const Editor = struct {
    buffer: Buffer,
    cursor: Cursor = .{},
};
