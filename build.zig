const std = @import("std");

const sdl_root = "third_party/SDL3-3.4.20";

/// Hard rule: every release exe must be at most 2 MiB.
const size_limit = 2 * 1024 * 1024;

/// Targets checked by `zig build size`.
const size_targets = [_]struct { name: []const u8, query: std.Target.Query }{
    .{ .name = "linux-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu } },
    .{ .name = "windows-x86_64", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows } },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const assets = addAssets(b);
    const exe = addEditor(b, target, optimize, assets);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    b.step("run", "Run the editor").dependOn(&run.step);

    // All SDL-free code. Unit tests live next to it; tests/ imports it as "8-bit".
    const sdl_free = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "assets", .module = assets }},
    });
    addStb(b, sdl_free, target, optimize);
    const integration = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "8-bit", .module = sdl_free }},
    });
    const test_step = b.step("test", "Run SDL-free unit and integration tests");
    for ([_]*std.Build.Module{ sdl_free, integration }) |mod| {
        const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = mod }));
        // Tests read files like tests/samples, so they always run.
        run_tests.has_side_effects = true;
        test_step.dependOn(&run_tests.step);
    }

    const size_check = b.addRunArtifact(b.addExecutable(.{
        .name = "size_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/size_check.zig"),
            .target = b.graph.host,
        }),
    }));
    size_check.addArg(b.fmt("{d}", .{size_limit}));
    for (size_targets) |t| {
        size_check.addArg(t.name);
        size_check.addFileArg(addEditor(b, b.resolveTargetQuery(t.query), .ReleaseSmall, assets).getEmittedBin());
    }
    b.step("size", "Fail if a release exe is over 2 MiB").dependOn(&size_check.step);
}

/// The editor exe with SDL linked in. Used by the normal build and by the size check.
fn addEditor(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, assets: *std.Build.Module) *std.Build.Step.Compile {
    const sdl_c = b.addTranslateC(.{
        .root_source_file = b.path("src/platform/sdl.h"),
        .target = target,
        .optimize = optimize,
    });
    sdl_c.addIncludePath(b.path(sdl_root ++ "/include"));

    const exe = b.addExecutable(.{
        .name = "8-bit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "sdl", .module = sdl_c.createModule() },
                .{ .name = "assets", .module = assets },
            },
        }),
    });
    exe.root_module.linkLibrary(buildSdl(b, target, optimize));
    addStb(b, exe.root_module, target, optimize);
    return exe;
}

/// stb_truetype, which reads the built-in fonts: C code and its Zig import "stb".
fn addStb(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const stb_c = b.addTranslateC(.{
        .root_source_file = b.path("third_party/stb/stb.h"),
        .link_libc = true,
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("stb", stb_c.createModule());
    mod.link_libc = true;
    mod.addCSourceFile(.{ .file = b.path("third_party/stb/stb_truetype.c"), .flags = &.{"-fno-sanitize=undefined"} });
}

/// The built-in data files of assets/, embedded in the exe. Every grammar
/// file is found by `tools/embed_dir.zig`.
fn addAssets(b: *std.Build) *std.Build.Module {
    const embed = b.addRunArtifact(b.addExecutable(.{
        .name = "embed_dir",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/embed_dir.zig"),
            .target = b.graph.host,
        }),
    }));
    // The folder's contents are not hashed, so run every time to see new files.
    embed.has_side_effects = true;
    embed.addArg("grammars");
    embed.addDirectoryArg(b.path("assets/grammars"));
    const grammars = b.createModule(.{ .root_source_file = embed.addOutputFileArg("grammars.zig") });
    const assets = b.createModule(.{ .root_source_file = b.path("assets/assets.zig") });
    assets.addImport("grammars", grammars);
    return assets;
}

fn buildSdl(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const os = target.result.os.tag;
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const lib = b.addLibrary(.{ .name = "SDL3", .root_module = mod, .linkage = .static });
    // One section per function/data, so the linker drops every SDL part we never call.
    lib.link_function_sections = true;
    lib.link_data_sections = true;

    mod.addIncludePath(b.path(sdl_root ++ "/include"));
    mod.addIncludePath(b.path(sdl_root ++ "/include/build_config"));
    mod.addIncludePath(b.path(sdl_root ++ "/src"));
    mod.addIncludePath(b.path(sdl_root ++ "/src/video/khronos"));
    mod.addCMacro("SDL_STATIC_LIB", "1");
    // SDL's own small-build switch: no optimized blitters, RLE, YUV or software renderer.
    mod.addCMacro("SDL_LEAN_AND_MEAN", "1");
    mod.addCMacro("SDL_DISABLE_STB", "1"); // no PNG/JPEG loading

    const flags: []const []const u8 = &.{ "-fno-sanitize=undefined", "-Wno-deprecated-declarations" };
    const root = b.path(sdl_root ++ "/src");

    mod.addCSourceFiles(.{ .root = root, .files = &common_sources, .flags = flags });

    switch (os) {
        .windows => {
            mod.addCSourceFiles(.{ .root = root, .files = &windows_sources, .flags = flags });
            for ([_][]const u8{
                "user32", "gdi32", "shell32", "ole32",    "oleaut32", "advapi32",
                "winmm",  "imm32", "version", "setupapi", "cfgmgr32", "kernel32",
            }) |name| mod.linkSystemLibrary(name, .{});
        },
        .linux => {
            mod.addIncludePath(b.path("third_party/X11/include"));
            mod.addIncludePath(b.path("third_party/wayland/include"));
            mod.addIncludePath(b.path("third_party/wayland/generated"));
            mod.addCSourceFiles(.{ .root = root, .files = &linux_sources, .flags = flags });
            for (wayland_protocols) |name| mod.addCSourceFile(.{
                .file = b.path(b.fmt("third_party/wayland/generated/{s}-protocol.c", .{name})),
                .flags = flags,
            });
        },
        else => @panic("8-Bit supports Windows and Linux only"),
    }

    return lib;
}

const common_sources = [_][]const u8{
    "SDL.c",
    "SDL_assert.c",
    "SDL_error.c",
    "SDL_guid.c",
    "SDL_hashtable.c",
    "SDL_hints.c",
    "SDL_list.c",
    "SDL_log.c",
    "SDL_properties.c",
    "SDL_utils.c",
    "atomic/SDL_atomic.c",
    "atomic/SDL_spinlock.c",
    "cpuinfo/SDL_cpuinfo.c",
    "dialog/SDL_dialog.c",
    "dialog/SDL_dialog_utils.c",
    "events/imKStoUCS.c",
    "events/SDL_categories.c",
    "events/SDL_clipboardevents.c",
    "events/SDL_displayevents.c",
    "events/SDL_dropevents.c",
    "events/SDL_events.c",
    "events/SDL_eventwatch.c",
    "events/SDL_keyboard.c",
    "events/SDL_keymap.c",
    "events/SDL_keysym_to_keycode.c",
    "events/SDL_keysym_to_scancode.c",
    "events/SDL_mouse.c",
    "events/SDL_pen.c",
    "events/SDL_quit.c",
    "events/SDL_scancode_tables.c",
    "events/SDL_touch.c",
    "events/SDL_windowevents.c",
    "filesystem/SDL_filesystem.c",
    "io/SDL_asyncio.c",
    "io/SDL_iostream.c",
    "io/generic/SDL_asyncio_generic.c",
    "main/SDL_main_callbacks.c",
    "main/generic/SDL_sysmain_callbacks.c",
    "locale/SDL_locale.c",
    "misc/SDL_url.c",
    "process/SDL_process.c",
    "render/SDL_render.c",
    "render/opengl/SDL_render_gl.c",
    "render/opengl/SDL_shaders_gl.c",
    "stdlib/SDL_crc16.c",
    "stdlib/SDL_crc32.c",
    "stdlib/SDL_getenv.c",
    "stdlib/SDL_iconv.c",
    "stdlib/SDL_malloc.c",
    "stdlib/SDL_memcpy.c",
    "stdlib/SDL_memmove.c",
    "stdlib/SDL_memset.c",
    "stdlib/SDL_mslibc.c",
    "stdlib/SDL_murmur3.c",
    "stdlib/SDL_qsort.c",
    "stdlib/SDL_random.c",
    "stdlib/SDL_stdlib.c",
    "stdlib/SDL_string.c",
    "stdlib/SDL_strtokr.c",
    "thread/SDL_thread.c",
    "time/SDL_time.c",
    "timer/SDL_timer.c",
    "video/SDL_blit.c",
    "video/SDL_blit_copy.c",
    "video/SDL_blit_slow.c",
    "video/SDL_bmp.c",
    "video/SDL_clipboard.c",
    "video/SDL_egl.c",
    "video/SDL_fillrect.c",
    "video/SDL_pixels.c",
    "video/SDL_rect.c",
    "video/SDL_rotate.c",
    "video/SDL_stb.c",
    "video/SDL_stretch.c",
    "video/SDL_surface.c",
    "video/SDL_video.c",
    "video/SDL_yuv.c",
};

const windows_sources = [_][]const u8{
    "core/windows/SDL_hid.c",
    "core/windows/SDL_windows.c",
    "dialog/windows/SDL_windowsdialog.c",
    "filesystem/windows/SDL_sysfilesystem.c",
    "filesystem/windows/SDL_sysfsops.c",
    "loadso/windows/SDL_sysloadso.c",
    "process/dummy/SDL_dummyprocess.c",
    "locale/windows/SDL_syslocale.c",
    "misc/windows/SDL_sysurl.c",
    "thread/windows/SDL_syscond_cv.c",
    "thread/windows/SDL_sysmutex.c",
    "thread/windows/SDL_sysrwlock_srw.c",
    "thread/windows/SDL_syssem.c",
    "thread/windows/SDL_systhread.c",
    "thread/windows/SDL_systls.c",
    "thread/generic/SDL_syscond.c",
    "thread/generic/SDL_sysrwlock.c",
    "time/windows/SDL_systime.c",
    "timer/windows/SDL_systimer.c",
    "video/windows/SDL_windowsclipboard.c",
    "video/windows/SDL_windowsevents.c",
    "video/windows/SDL_windowsframebuffer.c",
    "video/windows/SDL_windowsgameinput.cpp",
    "video/windows/SDL_windowskeyboard.c",
    "video/windows/SDL_windowsmessagebox.c",
    "video/windows/SDL_windowsmodes.c",
    "video/windows/SDL_windowsmouse.c",
    "video/windows/SDL_windowsopengl.c",
    "video/windows/SDL_windowsopengles.c",
    "video/windows/SDL_windowsrawinput.c",
    "video/windows/SDL_windowsshape.c",
    "video/windows/SDL_windowsvideo.c",
    "video/windows/SDL_windowswindow.c",
};

const linux_sources = [_][]const u8{
    "core/unix/SDL_appid.c",
    "core/unix/SDL_gtk.c",
    "core/unix/SDL_poll.c",
    "core/linux/SDL_threadprio.c",
    "dialog/unix/SDL_portaldialog.c",
    "dialog/unix/SDL_unixdialog.c",
    "dialog/unix/SDL_zenitydialog.c",
    "filesystem/posix/SDL_sysfsops.c",
    "filesystem/unix/SDL_sysfilesystem.c",
    "loadso/dlopen/SDL_sysloadso.c",
    "process/posix/SDL_posixprocess.c",
    "locale/unix/SDL_syslocale.c",
    "misc/unix/SDL_sysurl.c",
    "thread/generic/SDL_sysrwlock.c",
    "thread/pthread/SDL_syscond.c",
    "thread/pthread/SDL_sysmutex.c",
    "thread/pthread/SDL_syssem.c",
    "thread/pthread/SDL_systhread.c",
    "thread/pthread/SDL_systls.c",
    "time/unix/SDL_systime.c",
    "timer/unix/SDL_systimer.c",
    "video/x11/edid-parse.c",
    "video/x11/SDL_x11clipboard.c",
    "video/x11/SDL_x11dyn.c",
    "video/x11/SDL_x11events.c",
    "video/x11/SDL_x11framebuffer.c",
    "video/x11/SDL_x11keyboard.c",
    "video/x11/SDL_x11messagebox.c",
    "video/x11/SDL_x11modes.c",
    "video/x11/SDL_x11mouse.c",
    "video/x11/SDL_x11opengl.c",
    "video/x11/SDL_x11opengles.c",
    "video/x11/SDL_x11pen.c",
    "video/x11/SDL_x11settings.c",
    "video/x11/SDL_x11shape.c",
    "video/x11/SDL_x11toolkit.c",
    "video/x11/SDL_x11touch.c",
    "video/x11/SDL_x11video.c",
    "video/x11/SDL_x11window.c",
    "video/x11/SDL_x11xfixes.c",
    "video/x11/SDL_x11xtest.c",
    "video/x11/SDL_x11xinput2.c",
    "video/x11/xsettings-client.c",
    "dialog/unix/SDL_zenitymessagebox.c",
    "video/wayland/SDL_waylandclipboard.c",
    "video/wayland/SDL_waylandcolor.c",
    "video/wayland/SDL_waylanddatamanager.c",
    "video/wayland/SDL_waylanddyn.c",
    "video/wayland/SDL_waylandevents.c",
    "video/wayland/SDL_waylandkeyboard.c",
    "video/wayland/SDL_waylandmessagebox.c",
    "video/wayland/SDL_waylandmouse.c",
    "video/wayland/SDL_waylandopengles.c",
    "video/wayland/SDL_waylandshmbuffer.c",
    "video/wayland/SDL_waylandutil.c",
    "video/wayland/SDL_waylandvideo.c",
    "video/wayland/SDL_waylandwindow.c",
};

/// Wayland protocols SDL uses. Their code is pre-generated with wayland-scanner
/// into third_party/wayland/generated, so building needs no extra tools.
const wayland_protocols = [_][]const u8{
    "alpha-modifier-v1",
    "color-management-v1",
    "cursor-shape-v1",
    "fractional-scale-v1",
    "frog-color-management-v1",
    "idle-inhibit-unstable-v1",
    "input-timestamps-unstable-v1",
    "keyboard-shortcuts-inhibit-unstable-v1",
    "pointer-constraints-unstable-v1",
    "pointer-gestures-unstable-v1",
    "pointer-warp-v1",
    "primary-selection-unstable-v1",
    "relative-pointer-unstable-v1",
    "tablet-v2",
    "text-input-unstable-v3",
    "viewporter",
    "wayland",
    "xdg-activation-v1",
    "xdg-decoration-unstable-v1",
    "xdg-dialog-v1",
    "xdg-foreign-unstable-v2",
    "xdg-output-unstable-v1",
    "xdg-shell",
    "xdg-toplevel-icon-v1",
};
