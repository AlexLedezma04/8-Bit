//! The one way for a background thread to hand a result to the main loop.
const std = @import("std");

/// A thread-safe queue of `T`. `post` stores an item and calls `wake`, which
/// makes the main loop's event wait return; the main loop then calls `take`
/// until it is empty. The main thread owns every item it takes and frees
/// what the item holds.
pub fn Mailbox(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        /// Must be safe to call from any thread.
        wake: *const fn () void,
        mutex: std.Io.Mutex = .init,
        items: std.ArrayList(T) = .empty,

        const Self = @This();

        pub fn deinit(self: *Self) void {
            self.items.deinit(self.allocator);
        }

        /// Any thread. On failure the caller still owns `item`.
        pub fn post(self: *Self, item: T) !void {
            {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                try self.items.append(self.allocator, item);
            }
            self.wake();
        }

        /// Main thread. The oldest item, or null when the mailbox is empty.
        pub fn take(self: *Self) ?T {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return if (self.items.items.len > 0) self.items.orderedRemove(0) else null;
        }
    };
}

const testing = std.testing;

var wake_count: std.atomic.Value(usize) = .init(0);

fn countWake() void {
    _ = wake_count.fetchAdd(1, .monotonic);
}

fn postRange(mailbox: *Mailbox(usize), first: usize, count: usize) void {
    for (first..first + count) |n| mailbox.post(n) catch unreachable;
}

test "items posted from other threads arrive on the main thread" {
    var mailbox: Mailbox(usize) = .{ .allocator = testing.allocator, .io = testing.io, .wake = countWake };
    defer mailbox.deinit();
    wake_count.store(0, .monotonic);
    try testing.expectEqual(@as(?usize, null), mailbox.take());

    const per_thread = 100;
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| thread.* = try std.Thread.spawn(.{}, postRange, .{ &mailbox, i * per_thread, per_thread });
    for (threads) |thread| thread.join();

    try testing.expectEqual(threads.len * per_thread, wake_count.load(.monotonic));
    var seen: [threads.len * per_thread]bool = @splat(false);
    var last_of_thread: [threads.len]?usize = @splat(null);
    while (mailbox.take()) |n| {
        try testing.expect(!seen[n]);
        seen[n] = true;
        // Items of one thread keep their order.
        const thread = n / per_thread;
        if (last_of_thread[thread]) |last| try testing.expect(n > last);
        last_of_thread[thread] = n;
    }
    for (seen) |was_seen| try testing.expect(was_seen);
}
