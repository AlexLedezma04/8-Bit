//! The editor's side of git: the repository of the open folder, its status,
//! history and branches, and the git commands the user runs. Each command
//! runs through `git/repo.zig` on a thread of its own; the job comes back
//! through the mailbox to `receive`, on the main thread.
const std = @import("std");
const repo = @import("../git/repo.zig");
const status_zig = @import("../git/status.zig");
const Status = status_zig.Status;
const Entry = status_zig.Entry;
const log = @import("../git/log.zig");
const diff = @import("../git/diff.zig");
const editor_zig = @import("editor.zig");
const Editor = editor_zig.Editor;
const Request = editor_zig.Request;
const Mailbox = editor_zig.Mailbox;
const File = @import("file.zig").File;

/// Bigger files are left out of diff views.
const max_diff_file = 4 << 20;

/// What a job is for, and so what is done with its output.
pub const Task = union(enum) {
    status,
    /// The text at HEAD of the file with this id.
    head: u32,
    blame: u32,
    /// A page of the history with this generation.
    history: u32,
    branches,
    /// The last commit message, to amend it.
    amend,
    /// Stage, commit, switch: shows what went wrong, then refreshes.
    action: Action,
    /// A diff view, made on the thread.
    diff: Source,
};

pub const Action = struct {
    /// Shown when it worked.
    done: []const u8 = "",
    /// HEAD can move, so open files and their HEAD text are read again.
    moves_head: bool = false,
    /// Closes the commit message when it worked.
    commit: bool = false,
};

/// What a diff view compares.
pub const Source = union(enum) {
    /// The index and HEAD, of a path relative to the root.
    staged: []const u8,
    /// A commit and its parent, by hash.
    commit: []const u8,
};

/// One git command, run on its own thread. The thread only touches the job.
pub const Job = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mailbox: *Mailbox,
    arena: std.heap.ArenaAllocator,
    task: Task,
    /// git, by name or path.
    program: []const u8,
    cwd: []const u8,
    args: []const []const u8,
    thread: std.Thread = undefined,
    output: ?repo.Output = null,
    /// The hash of HEAD, read with the status.
    head: []const u8 = "",
    /// Why there is no output.
    failure: ?anyerror = null,
    /// What a diff task made.
    view: diff.Unified = .{},
    title: []const u8 = "",
    /// The file whose language the view takes.
    like: ?[]const u8 = null,

    fn run(self: *Job) void {
        self.work() catch |err| {
            self.failure = err;
        };
        self.mailbox.post(.{ .git = self }) catch {};
    }

    fn work(self: *Job) !void {
        switch (self.task) {
            .diff => |source| try self.makeDiff(source),
            else => self.output = try repo.run(self.allocator, self.io, self.program, self.cwd, self.args),
        }
        if (self.task == .status) {
            const head = try repo.run(self.arena.allocator(), self.io, self.program, self.cwd, &.{ "rev-parse", "-q", "--verify", "HEAD" });
            self.head = std.mem.trimEnd(u8, head.stdout, "\r\n");
        }
    }

    fn destroy(self: *Job) void {
        if (self.output) |output| output.deinit(self.allocator);
        self.view.deinit(self.allocator);
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    fn succeeded(self: *const Job) bool {
        return if (self.output) |output| output.ok else false;
    }

    /// Takes stdout from the job.
    fn take(self: *Job) []u8 {
        const output = &(self.output orelse return &.{});
        const taken = output.stdout;
        output.stdout = &.{};
        return taken;
    }

    /// What git prints for `rev:path`, or "" when there is none.
    fn show(self: *Job, rev: []const u8, path: []const u8) ![]const u8 {
        const arena = self.arena.allocator();
        const output = try repo.run(arena, self.io, self.program, self.cwd, &.{ "show", try std.fmt.allocPrint(arena, "{s}:{s}", .{ rev, path }) });
        return if (output.ok and output.stdout.len <= max_diff_file) output.stdout else "";
    }

    fn makeDiff(self: *Job, source: Source) !void {
        const arena = self.arena.allocator();
        switch (source) {
            .staged => |path| {
                try self.addFile(null, try self.show("HEAD", path), try self.show("", path));
                self.title = try std.fmt.allocPrint(arena, "{s} (staged)", .{std.fs.path.basename(path)});
                self.like = path;
            },
            .commit => |hash| {
                const about = try repo.run(arena, self.io, self.program, self.cwd, &.{ "log", "-1", "--date=short", "--format=%h %an %ad%n%B", hash });
                if (!about.ok) return error.NoSuchCommit;
                var lines = std.mem.tokenizeScalar(u8, about.stdout, '\n');
                while (lines.next()) |line| try self.view.header(self.allocator, "{s}", .{line});
                const files = try repo.run(arena, self.io, self.program, self.cwd, &log.changedFilesArgs(hash));
                var records = std.mem.splitScalar(u8, files.stdout, 0);
                var count: usize = 0;
                while (records.next()) |_| {
                    const path = records.next() orelse break;
                    const parent = try std.fmt.allocPrint(arena, "{s}^", .{hash});
                    try self.addFile(path, try self.show(parent, path), try self.show(hash, path));
                    self.like = path;
                    count += 1;
                }
                // One language fits only one file.
                if (count != 1) self.like = null;
                self.title = try std.fmt.allocPrint(arena, "Commit {s}", .{hash[0..@min(hash.len, 7)]});
            },
        }
    }

    fn addFile(self: *Job, name: ?[]const u8, old_text: []const u8, new_text: []const u8) !void {
        const arena = self.arena.allocator();
        const old = try diff.splitLines(arena, old_text);
        const new = try diff.splitLines(arena, new_text);
        if (name) |path| try self.view.header(self.allocator, "{s}", .{path});
        try self.view.add(self.allocator, old, new, try diff.diff(arena, old, new));
    }
};

/// The commits the git panel lists, a page at a time.
pub const History = struct {
    commits: std.ArrayList(log.Commit) = .empty,
    /// The output each page points into.
    pages: std.ArrayList([]u8) = .empty,
    /// Only the commits of this file.
    path: ?[]u8 = null,
    /// Goes up when the list starts again, so late pages are dropped.
    generation: u32 = 0,
    loading: bool = false,
    /// The last page was not full.
    complete: bool = false,

    fn clear(self: *History, allocator: std.mem.Allocator) void {
        for (self.pages.items) |page| allocator.free(page);
        self.pages.clearRetainingCapacity();
        self.commits.clearRetainingCapacity();
        if (self.path) |path| allocator.free(path);
        self.path = null;
        self.generation +%= 1;
        self.loading = false;
        self.complete = false;
    }

    fn deinit(self: *History, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.pages.deinit(allocator);
        self.commits.deinit(allocator);
    }
};

pub const Git = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// False once git turned out not to be installed: git features hide.
    available: bool = true,
    /// The absolute root of the repository of the open folder.
    root: ?[]u8 = null,
    /// The open folder relative to `root`: `/` between names and at the end.
    prefix: []u8 = &.{},
    /// Points into `status_text`.
    status: Status = .{},
    status_text: []u8 = &.{},
    /// The hash of HEAD at the last status, empty before the first commit.
    /// When it changes, so does the text at HEAD of every file.
    head: ?std.ArrayList(u8) = null,
    /// A status job runs; `again` asks for one more when it is done.
    refreshing: bool = false,
    again: bool = false,
    jobs: std.ArrayList(*Job) = .empty,
    history: History = .{},
    /// Point into `branches_text`.
    branches: std.ArrayList(log.Branch) = .empty,
    branches_text: []u8 = &.{},
    /// Blame is shown in the gutter.
    blame: bool = false,
    /// What the git panel shows.
    page: Page = .changes,

    pub const Page = enum { changes, history, branches };

    fn editor(self: *Git) *Editor {
        return @fieldParentPtr("git", self);
    }

    pub fn deinit(self: *Git) void {
        for (self.jobs.items) |job| {
            job.thread.join();
            job.destroy();
        }
        self.jobs.deinit(self.allocator);
        self.close();
        self.history.deinit(self.allocator);
        self.branches.deinit(self.allocator);
    }

    /// Forgets the repository and what it said about open files.
    pub fn close(self: *Git) void {
        for (self.editor().files.items) |file| file.tracking.forgetAll(self.allocator);
        if (self.root) |root| self.allocator.free(root);
        self.allocator.free(self.prefix);
        self.root = null;
        self.prefix = &.{};
        self.setStatus(&.{});
        if (self.head) |*head| head.deinit(self.allocator);
        self.head = null;
        self.history.clear(self.allocator);
        self.branches.clearRetainingCapacity();
        self.allocator.free(self.branches_text);
        self.branches_text = &.{};
    }

    /// Finds the repository of a newly opened folder and reads its status.
    pub fn open(self: *Git, folder: []const u8) void {
        self.close();
        const root = self.findRoot(folder) orelse return;
        const real = std.Io.Dir.cwd().realPathFileAlloc(self.io, folder, self.allocator) catch return self.allocator.free(root);
        defer self.allocator.free(real);
        const rest = std.mem.trimStart(u8, real[@min(root.len, real.len)..], std.fs.path.sep_str);
        self.prefix = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ rest, if (rest.len > 0) "/" else "" }) catch return self.allocator.free(root);
        std.mem.replaceScalar(u8, self.prefix, '\\', '/');
        self.root = root;
        self.refresh();
    }

    /// True when the open folder is in a repository and git can run.
    pub fn ready(self: *const Git) bool {
        return self.available and self.root != null;
    }

    /// False when the job could not start.
    fn start(self: *Git, task: Task, cwd: []const u8, args: []const []const u8) bool {
        self.spawn(task, cwd, args) catch |err| {
            self.editor().notify("Could not run git: {t}", .{err});
            return false;
        };
        return true;
    }

    fn spawn(self: *Git, task: Task, cwd: []const u8, args: []const []const u8) !void {
        const mailbox = self.editor().mailbox orelse return error.NoMailbox;
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        job.* = .{ .allocator = self.allocator, .io = self.io, .mailbox = mailbox, .arena = .init(self.allocator), .task = task, .program = undefined, .cwd = undefined, .args = undefined };
        errdefer job.arena.deinit();
        const arena = job.arena.allocator();
        job.program = try arena.dupe(u8, self.editor().settings.git);
        job.cwd = try arena.dupe(u8, cwd);
        const copies = try arena.alloc([]const u8, args.len);
        for (copies, args) |*copy, arg| copy.* = try arena.dupe(u8, arg);
        job.args = copies;
        if (task == .diff) job.task = .{ .diff = switch (task.diff) {
            inline else => |text, tag| @unionInit(Source, @tagName(tag), try arena.dupe(u8, text)),
        } };
        try self.jobs.ensureUnusedCapacity(self.allocator, 1);
        job.thread = try std.Thread.spawn(.{}, Job.run, .{job});
        self.jobs.appendAssumeCapacity(job);
    }

    /// Runs a command for one file, in the folder of the file.
    fn startForFile(self: *Git, task: Task, path: []const u8, args: []const []const u8) bool {
        return self.start(task, std.fs.path.dirname(path) orelse ".", args);
    }

    // Status

    /// Reads the status again. Many calls while one runs make one more.
    pub fn refresh(self: *Git) void {
        self.recheck();
        if (!self.ready()) return;
        if (self.refreshing) {
            self.again = true;
            return;
        }
        self.refreshing = self.start(.status, self.root.?, &status_zig.args);
    }

    /// The repository around `folder`, honoring `GIT_CEILING_DIRECTORIES`.
    fn findRoot(self: *Git, folder: []const u8) ?[]u8 {
        const env = self.editor().environ;
        const ceilings = if (env) |map| map.get("GIT_CEILING_DIRECTORIES") orelse "" else "";
        return repo.findRoot(self.allocator, self.io, folder, ceilings) catch null;
    }

    /// Opens the repository again when one was made, deleted or moved
    /// around the open folder since.
    fn recheck(self: *Git) void {
        const folder = self.editor().folder orelse return;
        const root = self.findRoot(folder);
        defer if (root) |path| self.allocator.free(path);
        const same = if (root) |path| self.root != null and std.mem.eql(u8, path, self.root.?) else self.root == null;
        if (!same) self.open(folder);
    }

    fn setStatus(self: *Git, text: []u8) void {
        self.status.deinit(self.allocator);
        self.allocator.free(self.status_text);
        self.status_text = text;
        self.status = Status.parse(self.allocator, text) catch .{};
    }

    /// The path of a file of the open folder relative to the root, in
    /// `buffer`. A folder ends with `/`, as git writes it.
    fn relative(self: *const Git, buffer: []u8, path: []const u8, is_dir: bool) ?[]const u8 {
        const owner: *const Editor = @fieldParentPtr("git", self);
        const folder = owner.folder orelse return null;
        if (!std.mem.startsWith(u8, path, folder) or path.len <= folder.len + 1) return null;
        const rel = std.fmt.bufPrint(buffer, "{s}{s}{s}", .{ self.prefix, path[folder.len + 1 ..], if (is_dir) "/" else "" }) catch return null;
        std.mem.replaceScalar(u8, rel, '\\', '/');
        return rel;
    }

    /// The status of a file or folder of the open folder.
    pub fn statusOf(self: *const Git, path: []const u8, is_dir: bool) ?Entry {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        return self.status.find(self.relative(&buffer, path, is_dir) orelse return null);
    }

    pub fn changedInside(self: *const Git, folder: []const u8) bool {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        return self.status.changedInside(self.relative(&buffer, folder, false) orelse return false);
    }

    // Actions

    fn act(self: *Git, action: Action, args: []const []const u8) void {
        if (!self.ready()) return self.editor().notify("No git repository", .{});
        _ = self.start(.{ .action = action }, self.root.?, args);
    }

    pub fn stage(self: *Git, entry: Entry) void {
        self.act(.{}, &status_zig.stageArgs(entry.path));
    }

    pub fn unstage(self: *Git, entry: Entry) void {
        self.act(.{}, &status_zig.unstageArgs(entry.path));
    }

    pub fn stageAll(self: *Git) void {
        self.act(.{}, &status_zig.stage_all);
    }

    pub fn unstageAll(self: *Git) void {
        self.act(.{}, &status_zig.unstage_all);
    }

    pub fn discard(self: *Git, entry: Entry) void {
        self.act(.{ .done = "Discarded changes" }, &status_zig.discardArgs(entry));
    }

    /// Commits `message`. An empty message is refused.
    pub fn commit(self: *Git, message: []const u8, amending: bool) void {
        if (log.isBlankMessage(message)) return self.editor().notify("Write a commit message first", .{});
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const args = log.commitArgs(arena.allocator(), message, amending) catch return;
        self.act(.{ .done = if (amending) "Amended the last commit" else "Committed", .moves_head = true, .commit = true }, args);
    }

    /// Opens the commit message with the last message, to amend it.
    pub fn amend(self: *Git) void {
        if (!self.ready()) return self.editor().notify("No git repository", .{});
        _ = self.start(.amend, self.root.?, &log.last_message);
    }

    pub fn switchBranch(self: *Git, name: []const u8) void {
        self.act(.{ .done = "Switched branch", .moves_head = true }, &log.switchArgs(name));
    }

    pub fn createBranch(self: *Git, name: []const u8) void {
        const trimmed = std.mem.trim(u8, name, " ");
        if (trimmed.len == 0) return;
        self.act(.{ .done = "Created branch", .moves_head = true }, &log.createArgs(trimmed));
    }

    // History and branches

    /// Lists the commits again from the newest, of `path` if set.
    pub fn loadHistory(self: *Git, path: ?[]const u8) void {
        self.history.clear(self.allocator);
        if (path) |file| self.history.path = self.allocator.dupe(u8, file) catch null;
        self.moreHistory();
    }

    /// Loads the next page of commits, unless one is loading or all are there.
    pub fn moreHistory(self: *Git) void {
        const history = &self.history;
        if (!self.ready() or history.loading or history.complete) return;
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const name = if (history.path) |path| std.fs.path.basename(path) else null;
        const args = log.logArgs(arena.allocator(), history.commits.items.len, name) catch return;
        const task: Task = .{ .history = history.generation };
        history.loading = if (history.path) |path| self.startForFile(task, path, args) else self.start(task, self.root.?, args);
    }

    pub fn loadBranches(self: *Git) void {
        if (self.ready()) _ = self.start(.branches, self.root.?, &log.branches_args);
    }

    // Views and the files of the editor

    pub fn showDiff(self: *Git, source: Source) void {
        if (!self.ready()) return self.editor().notify("No git repository", .{});
        _ = self.start(.{ .diff = source }, self.root.?, &.{});
    }

    /// Opens a file of the repository side by side with its text at HEAD,
    /// named as the file tree names it.
    pub fn compare(self: *Git, path: []const u8) void {
        const editor_ = self.editor();
        const inside = std.mem.startsWith(u8, path, self.prefix) and editor_.folder != null;
        const parts: [2][]const u8 = if (inside) .{ editor_.folder.?, path[self.prefix.len..] } else .{ self.root.?, path };
        const joined = std.fs.path.join(self.allocator, &parts) catch return;
        defer self.allocator.free(joined);
        std.mem.replaceScalar(u8, joined, '/', std.fs.path.sep);
        editor_.open(joined);
        editor_.tab().compare = true;
    }

    /// Asks for the HEAD text of an open file.
    pub fn fetchHead(self: *Git, file: *File) void {
        const path = file.path orelse return;
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const spec = std.fmt.bufPrint(&buffer, "HEAD:./{s}", .{std.fs.path.basename(path)}) catch return;
        file.tracking.head = if (self.startForFile(.{ .head = file.id }, path, &.{ "show", spec })) .asked else .missing;
    }

    pub fn fetchBlame(self: *Git, file: *File) void {
        const path = file.path orelse return;
        file.tracking.blame = if (self.startForFile(.{ .blame = file.id }, path, &log.blameArgs(std.fs.path.basename(path)))) .asked else .missing;
    }

    fn notInstalled(self: *Git) void {
        if (!self.available) return;
        self.available = false;
        self.editor().notify("git is not installed: git features are off", .{});
    }

    /// Takes a job that is done, uses its output and frees it.
    pub fn receive(self: *Git, job: *Job) ?Request {
        const at = std.mem.indexOfScalar(*Job, self.jobs.items, job) orelse return null;
        _ = self.jobs.swapRemove(at);
        job.thread.join();
        defer job.destroy();
        const editor_ = self.editor();
        if (job.failure) |err| {
            if (err == error.GitNotFound) self.notInstalled() else editor_.notify("git failed: {t}", .{err});
        }
        const ok = job.succeeded();
        switch (job.task) {
            .status => {
                self.refreshing = false;
                if (ok) self.setStatus(job.take()) else if (job.output) |output| editor_.notify("git: {s}", .{output.message()});
                // A commit or a switch made outside the editor.
                if (ok) if (self.head) |*head| {
                    if (!std.mem.eql(u8, head.items, job.head)) self.forgetHeads();
                    head.clearRetainingCapacity();
                    head.appendSlice(self.allocator, job.head) catch {};
                } else {
                    self.head = .empty;
                    self.head.?.appendSlice(self.allocator, job.head) catch {};
                };
                if (self.again) {
                    self.again = false;
                    self.refresh();
                }
            },
            .head => |id| if (editor_.fileById(id)) |file| file.tracking.setHead(self.allocator, if (ok) job.take() else null),
            .blame => |id| if (editor_.fileById(id)) |file| {
                if (!ok) {
                    file.tracking.blame = .missing;
                } else file.tracking.setBlame(self.allocator, &file.doc, job.take()) catch {
                    file.tracking.blame = .missing;
                };
            },
            .history => |generation| if (generation == self.history.generation) {
                const history = &self.history;
                history.loading = false;
                history.complete = true;
                if (!ok) return null;
                const page = job.take();
                history.pages.append(self.allocator, page) catch {
                    self.allocator.free(page);
                    return null;
                };
                const before = history.commits.items.len;
                log.parseLog(self.allocator, page, &history.commits) catch {};
                history.complete = history.commits.items.len - before < log.page;
            },
            .branches => if (ok) {
                self.branches.clearRetainingCapacity();
                self.allocator.free(self.branches_text);
                self.branches_text = job.take();
                log.parseBranches(self.allocator, self.branches_text, &self.branches) catch {};
            },
            .amend => if (ok) {
                editor_.openCommitMessage(std.mem.trimEnd(u8, job.output.?.stdout, "\n"), true);
            } else if (job.output) |output| editor_.notify("git: {s}", .{output.message()}),
            .action => |action| {
                if (job.output) |output| {
                    if (!output.ok) editor_.notify("git: {s}", .{output.message()}) else if (action.done.len > 0) editor_.notify("{s}", .{action.done});
                }
                if (ok and action.commit) editor_.closeCommitMessage();
                self.refresh();
                if (ok and action.moves_head) return self.headMoved();
            },
            .diff => if (job.failure == null) {
                const file = editor_.openView(job.title, job.view.text.items, job.like) orelse return null;
                viewMarks(self.allocator, file, job.view.kinds.items) catch {};
                editor_.afterEdit();
            },
        }
        return null;
    }

    /// After a commit or a switch: files are read again from disk, and
    /// their HEAD text and blame from git.
    fn headMoved(self: *Git) ?Request {
        self.forgetHeads();
        if (self.branches.items.len > 0) self.loadBranches();
        if (self.history.commits.items.len > 0) self.loadHistory(null);
        return self.editor().checkDisk();
    }

    fn forgetHeads(self: *Git) void {
        for (self.editor().files.items) |file| {
            file.tracking.forgetHead(self.allocator);
            file.tracking.forgetBlame(self.allocator);
        }
    }
};

/// The line backgrounds of a diff view, and `+` and `-` in its gutter.
fn viewMarks(allocator: std.mem.Allocator, file: *File, kinds: []const diff.Line) !void {
    const buffer = &file.doc.buffer;
    for (kinds, 0..) |kind, line| {
        if (line >= buffer.lineCount()) break;
        const start = buffer.lineStart(line);
        const range: @import("../core/buffer.zig").Range = .{ .start = start, .end = start };
        switch (kind) {
            .same => {},
            .header => try file.marks.append(allocator, .{ .range = range, .kind = .{ .line_background = .diff_header } }),
            .added, .removed => try file.marks.appendSlice(allocator, &.{
                .{ .range = range, .kind = .{ .line_background = if (kind == .added) .diff_added else .diff_removed } },
                .{ .range = range, .kind = .{ .gutter_text = if (kind == .added) "+" else "-" } },
            }),
        }
    }
}
