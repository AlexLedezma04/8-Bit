//! The editor's terminals: each one a shell in a pty and the session that
//! reads its output. The pty's thread posts output through the mailbox;
//! `receive` hands it to the session on the main thread.
const std = @import("std");
const Pty = @import("../platform/pty.zig").Pty;
const terminal = @import("../terminal/terminal.zig");
const Session = terminal.Session;
const editor_zig = @import("editor.zig");
const Mailbox = editor_zig.Mailbox;

/// Output of the terminal with this id; null when its shell ended. The
/// bytes are allocated with the editor's allocator.
pub const Output = struct { id: u32, bytes: ?[]u8 };

pub const Terminal = struct {
    allocator: std.mem.Allocator,
    mailbox: *Mailbox,
    id: u32,
    pty: *Pty,
    session: Session,
    name_buffer: [24]u8 = undefined,
    name_len: usize = 0,

    pub fn name(self: *const Terminal) []const u8 {
        return self.name_buffer[0..self.name_len];
    }

    /// On the pty's thread: only the allocator and the mailbox are touched.
    fn onOutput(context: *anyopaque, bytes: ?[]const u8) void {
        const self: *Terminal = @ptrCast(@alignCast(context));
        const copy = if (bytes) |some| self.allocator.dupe(u8, some) catch return else null;
        self.mailbox.post(.{ .terminal = .{ .id = self.id, .bytes = copy } }) catch if (copy) |some| self.allocator.free(some);
    }

    fn destroy(self: *Terminal) void {
        self.pty.destroy();
        self.session.deinit();
        self.allocator.destroy(self);
    }
};

pub const Start = struct {
    shell: []const u8,
    cwd: ?[]const u8,
    env: ?*const std.process.Environ.Map,
    scrollback: usize,
};

pub const Terminals = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(*Terminal) = .empty,
    /// The one shown.
    active: usize = 0,
    next_id: u32 = 1,

    /// The size a terminal has until it is drawn.
    const cols = 80;
    const rows = 24;

    pub fn deinit(self: *Terminals) void {
        for (self.list.items) |item| item.destroy();
        self.list.deinit(self.allocator);
    }

    pub fn current(self: *const Terminals) ?*Terminal {
        return if (self.active < self.list.items.len) self.list.items[self.active] else null;
    }

    /// Starts a shell in a new terminal and shows it.
    pub fn open(self: *Terminals, mailbox: *Mailbox, start: Start) !void {
        try self.list.ensureUnusedCapacity(self.allocator, 1);
        const created = try self.allocator.create(Terminal);
        errdefer self.allocator.destroy(created);
        created.* = .{ .allocator = self.allocator, .mailbox = mailbox, .id = self.next_id, .pty = undefined, .session = undefined };
        created.name_len = (std.fmt.bufPrint(&created.name_buffer, "Terminal {d}", .{created.id}) catch unreachable).len;
        created.pty = try Pty.spawn(self.allocator, .{
            .shell = start.shell,
            .cwd = start.cwd,
            .env = start.env,
            .cols = cols,
            .rows = rows,
            .context = created,
            .on_output = Terminal.onOutput,
        });
        errdefer created.pty.destroy();
        created.session = try .init(self.allocator, .of(Pty, created.pty), cols, rows, start.scrollback);
        self.next_id +%= 1;
        self.list.appendAssumeCapacity(created);
        self.active = self.list.items.len - 1;
    }

    /// Takes output from the mailbox and frees it. Output of a terminal
    /// that was closed is dropped.
    pub fn receive(self: *Terminals, output: Output) void {
        defer if (output.bytes) |bytes| self.allocator.free(bytes);
        for (self.list.items) |item| {
            if (item.id != output.id) continue;
            if (output.bytes) |bytes| item.session.output(bytes) else item.session.end();
            return;
        }
    }

    /// Stops the shell of a terminal and removes it.
    pub fn close(self: *Terminals, index: usize) void {
        self.list.orderedRemove(index).destroy();
        if (self.active > index or self.active == self.list.items.len) self.active -|= 1;
    }

    /// Shows the next terminal, or the previous one.
    pub fn cycle(self: *Terminals, step: isize) void {
        const count: isize = @intCast(self.list.items.len);
        if (count == 0) return;
        self.active = @intCast(@mod(@as(isize, @intCast(self.active)) + step, count));
    }
};
