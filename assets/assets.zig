//! Built-in data files, compiled into the exe as one deflated blob that the
//! first `get` unpacks. Names have no `.zon`. build.zig lists the files.
const std = @import("std");
const bundle = @import("bundle");

/// The app logo: light bars on a transparent background. PNG is deflated already.
pub const logo = @embedFile("icons/b-logo-light-512.png");

const index: std.StaticStringMap([2]u32) = .initComptime(bundle.files);
var unpacked: [bundle.size]u8 = undefined;
var ready = false;

/// A built-in file, or null. The fonts are `fonts/code` (JetBrains Mono)
/// and `fonts/ui` (Inter), OFL, see fonts/. Main thread only.
pub fn get(name: []const u8) ?[:0]const u8 {
    const at = index.get(name) orelse return null;
    if (!ready) {
        var input: std.Io.Reader = .fixed(bundle.deflated);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var inflate: std.compress.flate.Decompress = .init(&input, .raw, &window);
        inflate.reader.readSliceAll(&unpacked) catch @panic("bad built-in data");
        ready = true;
    }
    return unpacked[at[0]..][0..at[1] :0];
}

/// The names of every built-in file.
pub fn names() []const []const u8 {
    return index.keys();
}
