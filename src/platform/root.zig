//! The SDL-free part of the platform layer: event types, the mailbox and
//! file access. The other files import SDL, so they are not imported here.

pub const event = @import("event.zig");
pub const fs = @import("fs.zig");
pub const mailbox = @import("mailbox.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
