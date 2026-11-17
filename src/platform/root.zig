//! The SDL-free part of the platform layer: event types, the mailbox, file
//! access, PNG files and the pty. The other files import SDL, so they are not imported here.

pub const event = @import("event.zig");
pub const fs = @import("fs.zig");
pub const mailbox = @import("mailbox.zig");
pub const png = @import("png.zig");
pub const pty = @import("pty.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
