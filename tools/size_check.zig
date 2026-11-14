//! Fails the build when a release exe is bigger than the size budget.
//! Usage: size_check <limit_bytes> (<name> <exe_path>)...
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const limit = try std.fmt.parseInt(u64, args[1], 10);

    var over = false;
    var i: usize = 2;
    while (i + 1 < args.len) : (i += 2) {
        const name, const path = .{ args[i], args[i + 1] };
        const size = (try std.Io.Dir.cwd().statFile(init.io, path, .{})).size;
        if (size > limit) {
            over = true;
            std.debug.print("FAIL {s}: {d} bytes, {d} over the {d} byte limit\n", .{ name, size, size - limit, limit });
        } else {
            std.debug.print("ok   {s}: {d} bytes, {d} left\n", .{ name, size, limit - size });
        }
    }
    if (over) std.process.exit(1);
}
