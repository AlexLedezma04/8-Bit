//! Native dialogs: open file, save file, open folder, and the
//! Save / Don't save / Cancel message box.
const std = @import("std");
const c = @import("sdl.zig").c;
const Window = @import("window.zig").Window;
const editor = @import("../editor/editor.zig");
const Pick = editor.Pick;
const Posted = editor.Posted;

pub const Mailbox = @import("mailbox.zig").Mailbox(Posted);

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

/// `files` is null on an error and empty when the user cancelled.
fn onResult(context: ?*anyopaque, files: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
    const pick: *const Pick = @ptrCast(@alignCast(context));
    const allocator = results.allocator;
    const posted: Posted = if (files == null)
        .dialog_failed
    else if (files[0] == null)
        .cancelled
    else
        .{ .picked = .{ .pick = pick.*, .path = allocator.dupe(u8, std.mem.span(files[0])) catch return } };
    results.post(posted) catch switch (posted) {
        .picked => |picked| allocator.free(picked.path),
        else => {},
    };
}

/// Asks what to do with unsaved changes. Blocks until the user answers.
/// Null when no message box could be shown.
pub fn confirmSave(window: *const Window, name: []const u8) ?editor.Choice {
    var text: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&text, "Save changes to {s}?\x00", .{name}) catch "Save changes?\x00";
    const choices = std.enums.values(editor.Choice);
    const buttons = [_]c.SDL_MessageBoxButtonData{
        .{ .flags = c.SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT, .buttonID = @backingInt(editor.Choice.save), .text = "Save" },
        .{ .flags = 0, .buttonID = @backingInt(editor.Choice.discard), .text = "Don't save" },
        .{ .flags = c.SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT, .buttonID = @backingInt(editor.Choice.cancel), .text = "Cancel" },
    };
    const box: c.SDL_MessageBoxData = .{
        .flags = c.SDL_MESSAGEBOX_WARNING,
        .window = window.handle,
        .title = "8-Bit",
        .message = message.ptr,
        .numbuttons = buttons.len,
        .buttons = &buttons,
        .colorScheme = null,
    };
    var pressed: c_int = -1;
    if (!c.SDL_ShowMessageBox(&box, &pressed)) return null;
    // Closing the box without a button counts as Cancel.
    return if (pressed >= 0 and pressed < choices.len) choices[@intCast(pressed)] else .cancel;
}
