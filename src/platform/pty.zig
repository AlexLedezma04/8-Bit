//! A shell in a pseudo-terminal: `/dev/ptmx` and fork on Linux, ConPTY on
//! Windows, behind one API picked at compile time. Output is read on a
//! thread of its own and handed to a callback. No SDL and no libc, so the
//! tests run a real shell.
const std = @import("std");
const builtin = @import("builtin");

pub const Options = struct {
    /// The shell program; empty means `$SHELL` (else /bin/sh) on Linux and
    /// PowerShell on Windows. Windows takes a whole command line.
    shell: []const u8 = "",
    /// Where the shell starts; null is the current folder.
    cwd: ?[]const u8 = null,
    /// The environment of the shell, with `TERM` added. Null: only `TERM`.
    /// Windows always passes on its own environment.
    env: ?*const std.process.Environ.Map = null,
    cols: u16 = 80,
    rows: u16 = 24,
    context: *anyopaque,
    /// Called on the reader thread with each piece of output, then once with
    /// null when the shell is gone. Not called after `destroy` starts.
    on_output: *const fn (context: *anyopaque, bytes: ?[]const u8) void,
};

pub const Pty = if (builtin.os.tag == .windows) WindowsPty else LinuxPty;

const read_size = 64 * 1024;

const LinuxPty = struct {
    const linux = std.os.linux;

    allocator: std.mem.Allocator,
    master: linux.fd_t,
    pid: linux.pid_t,
    /// Writing to it stops the reader.
    stop: [2]linux.fd_t,
    thread: std.Thread,
    context: *anyopaque,
    on_output: *const fn (*anyopaque, ?[]const u8) void,

    pub fn spawn(allocator: std.mem.Allocator, options: Options) !*LinuxPty {
        var arena_state: std.heap.ArenaAllocator = .init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const fd: linux.fd_t = @intCast(try check(linux.openat(linux.AT.FDCWD, "/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0)));
        errdefer _ = linux.close(fd);
        var unlock: c_int = 0;
        _ = try check(linux.ioctl(fd, linux.T.IOCSPTLCK, @intFromPtr(&unlock)));
        var number: c_uint = 0;
        _ = try check(linux.ioctl(fd, linux.T.IOCGPTN, @intFromPtr(&number)));
        const size: std.posix.winsize = .{ .row = options.rows, .col = options.cols, .xpixel = 0, .ypixel = 0 };
        _ = linux.ioctl(fd, linux.T.IOCSWINSZ, @intFromPtr(&size));

        // Everything the child needs is made before the fork: after it, only
        // system calls are safe.
        const slave = try std.fmt.allocPrintSentinel(arena, "/dev/pts/{d}", .{number}, 0);
        const env = try environment(arena, options.env);
        const shell = if (options.shell.len > 0) options.shell else if (options.env) |map| map.get("SHELL") orelse "/bin/sh" else "/bin/sh";
        const programs = try candidates(arena, shell, if (options.env) |map| map.get("PATH") else null);
        const argv = try arena.allocSentinel(?[*:0]const u8, 1, null);
        argv[0] = programs[0];
        const cwd: ?[*:0]const u8 = if (options.cwd) |dir| try arena.dupeSentinel(u8, dir, 0) else null;

        var stop: [2]linux.fd_t = undefined;
        _ = try check(linux.pipe2(&stop, .{ .CLOEXEC = true }));
        errdefer for (stop) |end| {
            _ = linux.close(end);
        };

        const forked = try check(linux.fork());
        if (forked == 0) child(slave, cwd, programs, argv, env);
        const pid: linux.pid_t = @intCast(forked);
        errdefer {
            _ = linux.kill(pid, .KILL);
            reap(pid);
        }

        const self = try allocator.create(LinuxPty);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .master = fd,
            .pid = pid,
            .stop = stop,
            .thread = undefined,
            .context = options.context,
            .on_output = options.on_output,
        };
        self.thread = try std.Thread.spawn(.{}, readLoop, .{self});
        return self;
    }

    /// The child side of the fork: a new session with the pty as its
    /// terminal, then the shell.
    fn child(slave: [*:0]const u8, cwd: ?[*:0]const u8, programs: []const [*:0]const u8, argv: [*:null]?[*:0]const u8, env: [*:null]const ?[*:0]const u8) noreturn {
        _ = linux.setsid();
        const opened = linux.openat(linux.AT.FDCWD, slave, .{ .ACCMODE = .RDWR }, 0);
        if (linux.errno(opened) != .SUCCESS) linux.exit(127);
        const fd: linux.fd_t = @intCast(opened);
        _ = linux.ioctl(fd, linux.T.IOCSCTTY, 0);
        for (0..3) |std_fd| _ = linux.dup2(fd, @intCast(std_fd));
        if (fd > 2) _ = linux.close(fd);
        if (cwd) |dir| _ = linux.chdir(dir);
        // Ignored signals stay ignored after exec: the editor ignores
        // SIGPIPE, and one started in the background ignores SIGINT. The
        // shell gets them all back.
        const default: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
        for (1..32) |number| {
            const signal: linux.SIG = @fromBackingInt(@as(u32, @intCast(number)));
            if (signal != .KILL and signal != .STOP) _ = linux.sigaction(signal, &default, null);
        }
        const none = linux.sigemptyset();
        _ = linux.sigprocmask(linux.SIG.SETMASK, &none, null);
        for (programs) |program| {
            argv[0] = program;
            _ = linux.execve(program, argv, env);
        }
        linux.exit(127);
    }

    /// The paths to try for `shell`: itself if it has a slash, else each
    /// folder of PATH.
    fn candidates(arena: std.mem.Allocator, shell: []const u8, path: ?[]const u8) ![]const [*:0]const u8 {
        var list: std.ArrayList([*:0]const u8) = .empty;
        if (std.mem.indexOfScalar(u8, shell, '/') != null) {
            try list.append(arena, try arena.dupeSentinel(u8, shell, 0));
        } else {
            var dirs = std.mem.tokenizeScalar(u8, path orelse "/usr/local/bin:/usr/bin:/bin", ':');
            while (dirs.next()) |dir| try list.append(arena, try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ dir, shell }, 0));
        }
        if (list.items.len == 0) return error.FileNotFound;
        return list.items;
    }

    fn environment(arena: std.mem.Allocator, env: ?*const std.process.Environ.Map) ![*:null]const ?[*:0]const u8 {
        var map: std.process.Environ.Map = if (env) |given| try given.clone(arena) else .init(arena);
        try map.put("TERM", "xterm-256color");
        try map.put("COLORTERM", "truecolor");
        const block = try map.createPosixBlock(arena, .{});
        return @ptrCast(block.slice.ptr);
    }

    fn readLoop(self: *LinuxPty) void {
        var buffer: [read_size]u8 = undefined;
        while (true) {
            var fds = [_]linux.pollfd{
                .{ .fd = self.master, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = self.stop[0], .events = linux.POLL.IN, .revents = 0 },
            };
            const polled = linux.poll(&fds, fds.len, -1);
            if (linux.errno(polled) == .INTR) continue;
            if (linux.errno(polled) != .SUCCESS or fds[1].revents != 0) return;
            const got = linux.read(self.master, &buffer, buffer.len);
            switch (linux.errno(got)) {
                .SUCCESS => if (got == 0) break else self.on_output(self.context, buffer[0..got]),
                .INTR, .AGAIN => {},
                // EIO: every program on the terminal has closed it.
                else => break,
            }
        }
        self.on_output(self.context, null);
    }

    /// Writes all of `bytes` to the shell.
    pub fn write(self: *LinuxPty, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0) {
            const wrote = linux.write(self.master, rest.ptr, rest.len);
            switch (linux.errno(wrote)) {
                .SUCCESS => rest = rest[wrote..],
                .INTR, .AGAIN => {},
                else => return,
            }
        }
    }

    /// Tells the shell its new size; it gets SIGWINCH.
    pub fn resize(self: *LinuxPty, cols: u16, rows: u16) void {
        const size: std.posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        _ = linux.ioctl(self.master, linux.T.IOCSWINSZ, @intFromPtr(&size));
    }

    /// Stops the reader, hangs up the shell and waits for it.
    pub fn destroy(self: *LinuxPty) void {
        _ = linux.write(self.stop[1], "x", 1);
        self.thread.join();
        _ = linux.kill(self.pid, .HUP);
        _ = linux.close(self.master);
        reap(self.pid);
        for (self.stop) |end| _ = linux.close(end);
        self.allocator.destroy(self);
    }

    /// Waits a moment for `pid` to end, then kills it.
    fn reap(pid: linux.pid_t) void {
        var status: i32 = 0;
        for (0..20) |_| {
            if (linux.wait4(pid, &status, linux.W.NOHANG, null) != 0) return;
            const pause: linux.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
            _ = linux.nanosleep(&pause, null);
        }
        _ = linux.kill(pid, .KILL);
        _ = linux.wait4(pid, &status, 0, null);
    }

    fn check(rc: usize) !usize {
        return switch (linux.errno(rc)) {
            .SUCCESS => rc,
            .NOENT => error.FileNotFound,
            .ACCES, .PERM => error.AccessDenied,
            .NOMEM => error.OutOfMemory,
            else => error.Unexpected,
        };
    }
};

const WindowsPty = struct {
    const windows = std.os.windows;
    const HANDLE = windows.HANDLE;
    const DWORD = windows.DWORD;
    const BOOL = windows.BOOL;
    const HPCON = *anyopaque;
    const Coord = extern struct { x: i16, y: i16 };
    const StartupInfoEx = extern struct { info: windows.STARTUPINFOW, attributes: ?*anyopaque };
    const ProcessInfo = extern struct { process: HANDLE, thread: HANDLE, process_id: DWORD, thread_id: DWORD };

    const pseudoconsole_attribute = 0x00020016;
    const extended_startupinfo_present = 0x00080000;
    const startf_usestdhandles = 0x00000100;
    const infinite = 0xffffffff;

    extern "kernel32" fn CreatePipe(read: *HANDLE, write: *HANDLE, attributes: ?*anyopaque, size: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn CreatePseudoConsole(size: Coord, input: HANDLE, output: HANDLE, flags: DWORD, console: *HPCON) callconv(.winapi) i32;
    extern "kernel32" fn ResizePseudoConsole(console: HPCON, size: Coord) callconv(.winapi) i32;
    extern "kernel32" fn ClosePseudoConsole(console: HPCON) callconv(.winapi) void;
    extern "kernel32" fn InitializeProcThreadAttributeList(list: ?*anyopaque, count: DWORD, flags: DWORD, size: *usize) callconv(.winapi) BOOL;
    extern "kernel32" fn UpdateProcThreadAttribute(list: *anyopaque, flags: DWORD, attribute: usize, value: ?*anyopaque, size: usize, previous: ?*anyopaque, returned: ?*usize) callconv(.winapi) BOOL;
    extern "kernel32" fn DeleteProcThreadAttributeList(list: *anyopaque) callconv(.winapi) void;
    extern "kernel32" fn CreateProcessW(name: ?[*:0]const u16, command: ?[*:0]u16, process_attributes: ?*anyopaque, thread_attributes: ?*anyopaque, inherit: BOOL, flags: DWORD, env: ?*anyopaque, cwd: ?[*:0]const u16, startup: *StartupInfoEx, info: *ProcessInfo) callconv(.winapi) BOOL;
    extern "kernel32" fn ReadFile(file: HANDLE, buffer: [*]u8, size: DWORD, read: *DWORD, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn WriteFile(file: HANDLE, buffer: [*]const u8, size: DWORD, written: *DWORD, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn WaitForSingleObject(handle: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
    extern "kernel32" fn TerminateProcess(process: HANDLE, code: c_uint) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;

    allocator: std.mem.Allocator,
    console: HPCON = undefined,
    /// Closed once, by whoever comes first: the waiter when the shell ends,
    /// or `destroy`.
    console_closed: std.atomic.Value(bool) = .init(false),
    input: HANDLE = undefined,
    output: HANDLE = undefined,
    process: HANDLE = undefined,
    /// The process thread attribute list, which must be pointer aligned.
    attributes: []align(@alignOf(usize)) u8 = &.{},
    reader: std.Thread = undefined,
    waiter: std.Thread = undefined,
    stopping: std.atomic.Value(bool) = .init(false),
    context: *anyopaque,
    on_output: *const fn (*anyopaque, ?[]const u8) void,

    pub fn spawn(allocator: std.mem.Allocator, options: Options) !*WindowsPty {
        var arena_state: std.heap.ArenaAllocator = .init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const self = try allocator.create(WindowsPty);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .context = options.context, .on_output = options.on_output };

        var in_read: HANDLE = undefined;
        var in_write: HANDLE = undefined;
        var out_read: HANDLE = undefined;
        var out_write: HANDLE = undefined;
        if (!CreatePipe(&in_read, &in_write, null, 0).toBool()) return error.Unexpected;
        errdefer _ = CloseHandle(in_write);
        defer _ = CloseHandle(in_read);
        if (!CreatePipe(&out_read, &out_write, null, 0).toBool()) return error.Unexpected;
        errdefer _ = CloseHandle(out_read);
        defer _ = CloseHandle(out_write);

        if (CreatePseudoConsole(coord(options.cols, options.rows), in_read, out_write, 0, &self.console) != 0) return error.Unexpected;
        errdefer self.closeConsole();

        var size: usize = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &size);
        const attributes = try allocator.alignedAlloc(u8, .of(usize), size);
        errdefer allocator.free(attributes);
        if (!InitializeProcThreadAttributeList(attributes.ptr, 1, 0, &size).toBool()) return error.Unexpected;
        errdefer DeleteProcThreadAttributeList(attributes.ptr);
        if (!UpdateProcThreadAttribute(attributes.ptr, 0, pseudoconsole_attribute, self.console, @sizeOf(HPCON), null, null).toBool()) return error.Unexpected;

        var startup: StartupInfoEx = .{ .info = std.mem.zeroes(windows.STARTUPINFOW), .attributes = attributes.ptr };
        startup.info.cb = @sizeOf(StartupInfoEx);
        // Without this, a shell started from a redirected parent writes to
        // the parent's handles instead of the console.
        startup.info.dwFlags = startf_usestdhandles;
        const command = try std.unicode.wtf8ToWtf16LeAllocZ(arena, if (options.shell.len > 0) options.shell else "powershell.exe");
        const cwd = if (options.cwd) |dir| try std.unicode.wtf8ToWtf16LeAllocZ(arena, dir) else null;
        var info: ProcessInfo = undefined;
        if (!CreateProcessW(null, command.ptr, null, null, .FALSE, extended_startupinfo_present, null, if (cwd) |dir| dir.ptr else null, &startup, &info).toBool()) return error.FileNotFound;
        _ = CloseHandle(info.thread);
        errdefer {
            _ = TerminateProcess(info.process, 1);
            _ = CloseHandle(info.process);
        }
        self.input = in_write;
        self.output = out_read;
        self.process = info.process;
        self.attributes = attributes;

        self.reader = try std.Thread.spawn(.{}, readLoop, .{self});
        errdefer {
            self.stopping.store(true, .release);
            self.closeConsole();
            self.reader.join();
        }
        self.waiter = try std.Thread.spawn(.{}, waitLoop, .{self});
        return self;
    }

    fn coord(cols: u16, rows: u16) Coord {
        return .{ .x = @intCast(@min(cols, std.math.maxInt(i16))), .y = @intCast(@min(rows, std.math.maxInt(i16))) };
    }

    fn readLoop(self: *WindowsPty) void {
        var buffer: [read_size]u8 = undefined;
        while (true) {
            var got: DWORD = 0;
            if (!ReadFile(self.output, &buffer, buffer.len, &got, null).toBool() or got == 0) break;
            if (self.stopping.load(.acquire)) return;
            self.on_output(self.context, buffer[0..got]);
        }
        if (!self.stopping.load(.acquire)) self.on_output(self.context, null);
    }

    /// ConPTY keeps its pipe open after the shell ends; closing the console
    /// then ends the reader.
    fn waitLoop(self: *WindowsPty) void {
        _ = WaitForSingleObject(self.process, infinite);
        self.closeConsole();
    }

    fn closeConsole(self: *WindowsPty) void {
        if (!self.console_closed.swap(true, .acq_rel)) ClosePseudoConsole(self.console);
    }

    pub fn write(self: *WindowsPty, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0) {
            var wrote: DWORD = 0;
            if (!WriteFile(self.input, rest.ptr, @intCast(@min(rest.len, std.math.maxInt(DWORD))), &wrote, null).toBool()) return;
            rest = rest[wrote..];
        }
    }

    pub fn resize(self: *WindowsPty, cols: u16, rows: u16) void {
        if (!self.console_closed.load(.acquire)) _ = ResizePseudoConsole(self.console, coord(cols, rows));
    }

    pub fn destroy(self: *WindowsPty) void {
        self.stopping.store(true, .release);
        _ = TerminateProcess(self.process, 1);
        self.waiter.join();
        self.closeConsole();
        self.reader.join();
        _ = CloseHandle(self.input);
        _ = CloseHandle(self.output);
        _ = CloseHandle(self.process);
        DeleteProcThreadAttributeList(self.attributes.ptr);
        self.allocator.free(self.attributes);
        self.allocator.destroy(self);
    }
};

const testing = std.testing;

/// Collects what the reader thread hands over, through a mailbox as the
/// editor does.
const Collector = struct {
    mailbox: @import("mailbox.zig").Mailbox(?[]u8),
    text: std.ArrayList(u8) = .empty,
    ended: bool = false,

    fn onOutput(context: *anyopaque, bytes: ?[]const u8) void {
        const self: *Collector = @ptrCast(@alignCast(context));
        const copy = if (bytes) |some| testing.allocator.dupe(u8, some) catch return else null;
        self.mailbox.post(copy) catch if (copy) |some| testing.allocator.free(some);
    }

    /// Takes output until `part` shows up; null waits for the shell to end.
    /// Fails after 10 seconds.
    fn waitFor(self: *Collector, part: ?[]const u8) !void {
        const clock: std.Io.Clock = .awake;
        const deadline = clock.now(testing.io).addDuration(.fromMilliseconds(10_000));
        while (if (part) |text| std.mem.indexOf(u8, self.text.items, text) == null else !self.ended) {
            if (self.ended or clock.now(testing.io).nanoseconds > deadline.nanoseconds) return error.TestUnexpectedResult;
            const posted = self.mailbox.take() orelse {
                std.Thread.yield() catch {};
                continue;
            };
            const bytes = posted orelse {
                self.ended = true;
                continue;
            };
            defer testing.allocator.free(bytes);
            try self.text.appendSlice(testing.allocator, bytes);
        }
    }

    fn deinit(self: *Collector) void {
        while (self.mailbox.take()) |posted| if (posted) |bytes| testing.allocator.free(bytes);
        self.mailbox.deinit();
        self.text.deinit(testing.allocator);
    }
};

fn noWake() void {}

test "a real shell: output, input, resize, exit" {
    var collector: Collector = .{ .mailbox = .{ .allocator = testing.allocator, .io = testing.io, .wake = noWake } };
    defer collector.deinit();
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    const windows = builtin.os.tag == .windows;
    const pty = try Pty.spawn(testing.allocator, .{
        .shell = if (windows) "cmd.exe" else "/bin/sh",
        .env = &env,
        .cols = 40,
        .rows = 10,
        .context = &collector,
        .on_output = Collector.onOutput,
    });
    defer pty.destroy();

    pty.write(if (windows) "echo %TERM%-hello\r" else "echo $TERM-$((40+2))\r");
    // cmd.exe has no TERM of its own; the shell on Linux gets ours.
    try collector.waitFor(if (windows) "-hello" else "xterm-256color-42");
    pty.resize(50, 12);
    if (!windows) {
        pty.write("stty size\r");
        try collector.waitFor("12 50");
    }
    pty.write("exit\r");
    try collector.waitFor(null);
}

test "the shell gets back signals the editor ignores" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const linux = std.os.linux;
    // As when the editor is started in the background.
    const ignore: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
    var old: linux.Sigaction = undefined;
    _ = linux.sigaction(.INT, &ignore, &old);
    defer _ = linux.sigaction(.INT, &old, null);

    var collector: Collector = .{ .mailbox = .{ .allocator = testing.allocator, .io = testing.io, .wake = noWake } };
    defer collector.deinit();
    const pty = try Pty.spawn(testing.allocator, .{ .shell = "/bin/sh", .context = &collector, .on_output = Collector.onOutput });
    defer pty.destroy();

    // A program the shell runs ignores no signal.
    pty.write("grep Sig''Ign /proc/self/status\r");
    try collector.waitFor("SigIgn:\t0000000000000000");
}
