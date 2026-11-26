//! Native dialogs: open file, save file, open folder, and the
//! message boxes that ask a question.
const std = @import("std");
const c = @import("sdl.zig").c;
const Window = @import("window.zig").Window;
const editor = @import("../editor/editor.zig");
const Pick = editor.Pick;
const Posted = editor.Posted;

const Mailbox = editor.Mailbox;

/// Where dialog results go. Set once, before the first `show`.
var results: *Mailbox = undefined;

const picks = std.enums.values(Pick);

pub fn init(mailbox: *Mailbox) void {
    results = mailbox;
}

/// Shows a dialog and returns at once. The result is posted to the mailbox,
/// because SDL may call back on another thread.
pub fn show(pick: Pick, window: *const Window) void {
    const context: ?*anyopaque = @constCast(&picks[@backingInt(pick)]);
    switch (pick) {
        .open_file => c.SDL_ShowOpenFileDialog(onResult, context, window.handle, null, 0, null, false),
        .save_file => c.SDL_ShowSaveFileDialog(onResult, context, window.handle, null, 0, null),
        .open_folder => c.SDL_ShowOpenFolderDialog(onResult, context, window.handle, null, false),
    }
}

/// `files` is null on an error. When the user cancelled it is empty, or
/// holds one empty path (zenity).
fn onResult(context: ?*anyopaque, files: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
    const pick: *const Pick = @ptrCast(@alignCast(context));
    const allocator = results.allocator;
    const posted: Posted = if (files == null)
        .dialog_failed
    else if (files[0] == null or files[0][0] == 0)
        .cancelled
    else
        .{ .picked = .{ .pick = pick.*, .path = allocator.dupe(u8, std.mem.span(files[0])) catch return } };
    results.post(posted) catch switch (posted) {
        .picked => |picked| allocator.free(picked.path),
        else => {},
    };
}

const Button = struct { answer: editor.Answer, text: [*:0]const u8 };

/// Asks a question about `name`. Blocks until the user answers. Null when
/// no message box could be shown.
pub fn ask(window: *const Window, question: editor.Question, name: []const u8) ?editor.Answer {
    var text: [256]u8 = undefined;
    const message = switch (question) {
        .save => std.fmt.bufPrint(&text, "Save changes to {s}?\x00", .{name}),
        .reload => std.fmt.bufPrint(&text, "{s} changed on disk. Reload it and lose your changes?\x00", .{name}),
        .delete => std.fmt.bufPrint(&text, "Delete {s}?\x00", .{name}),
        .discard => std.fmt.bufPrint(&text, "Discard the changes to {s}?\x00", .{name}),
    } catch "Are you sure?\x00";
    const buttons: []const Button = switch (question) {
        .save => &.{ .{ .answer = .yes, .text = "Save" }, .{ .answer = .no, .text = "Don't save" }, .{ .answer = .cancel, .text = "Cancel" } },
        .reload => &.{ .{ .answer = .yes, .text = "Reload" }, .{ .answer = .no, .text = "Keep mine" } },
        .delete => &.{ .{ .answer = .yes, .text = "Delete" }, .{ .answer = .cancel, .text = "Cancel" } },
        .discard => &.{ .{ .answer = .yes, .text = "Discard" }, .{ .answer = .cancel, .text = "Cancel" } },
    };
    var data: [3]c.SDL_MessageBoxButtonData = undefined;
    for (buttons, 0..) |button, i| data[i] = .{
        .flags = if (i == 0) c.SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT else if (i == buttons.len - 1) c.SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT else 0,
        .buttonID = @intCast(i),
        .text = button.text,
    };
    const box: c.SDL_MessageBoxData = .{
        .flags = c.SDL_MESSAGEBOX_WARNING,
        .window = window.handle,
        .title = "8-Bit",
        .message = message.ptr,
        .numbuttons = @intCast(buttons.len),
        .buttons = &data,
        .colorScheme = null,
    };
    var pressed: c_int = -1;
    if (!c.SDL_ShowMessageBox(&box, &pressed)) return null;
    // Closing the box without a button counts as Cancel.
    return if (pressed >= 0 and pressed < buttons.len) buttons[@intCast(pressed)].answer else .cancel;
}
