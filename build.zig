const std = @import("std");

const sdl_root = "SDL3-3.4.20";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdl = buildSdl(b, target, optimize);

    const sdl_c = b.addTranslateC(.{
        .root_source_file = b.path("src/sdl.h"),
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
            .imports = &.{.{ .name = "sdl", .module = sdl_c.createModule() }},
        }),
    });
    exe.root_module.linkLibrary(sdl);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    b.step("run", "Run the editor").dependOn(&run.step);
}

fn buildSdl(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const os = target.result.os.tag;
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const lib = b.addLibrary(.{ .name = "SDL3", .root_module = mod, .linkage = .static });

    mod.addIncludePath(b.path(sdl_root ++ "/include"));
    mod.addIncludePath(b.path(sdl_root ++ "/include/build_config"));
    mod.addIncludePath(b.path(sdl_root ++ "/src"));
    mod.addIncludePath(b.path(sdl_root ++ "/src/video/khronos"));
    mod.addCMacro("SDL_STATIC_LIB", "1");

    const flags: []const []const u8 = &.{ "-fno-sanitize=undefined", "-Wno-deprecated-declarations" };
    const root = b.path(sdl_root ++ "/src");

    mod.addCSourceFiles(.{ .root = root, .files = &common_sources, .flags = flags });

    switch (os) {
        .windows => {
            mod.addCSourceFiles(.{ .root = root, .files = &windows_sources, .flags = flags });
            for ([_][]const u8{
                "user32",  "gdi32",   "shell32", "ole32",   "oleaut32", "advapi32",
                "winmm",   "imm32",   "version", "setupapi", "cfgmgr32", "kernel32",
            }) |name| mod.linkSystemLibrary(name, .{});
        },
        .linux => {
            mod.addCSourceFiles(.{ .root = root, .files = &linux_sources, .flags = flags });
        },
        .macos => {
            mod.addCSourceFiles(.{ .root = root, .files = &macos_sources, .flags = flags, .language = .objective_c });
            for ([_][]const u8{ "Cocoa", "IOKit", "CoreFoundation", "CoreVideo", "CoreServices", "AppKit", "Foundation", "OpenGL" }) |name|
                mod.linkFramework(name, .{});
        },
        else => @panic("8-Bit supports Windows, macOS and Linux only"),
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
    "libm/e_atan2.c",
    "libm/e_exp.c",
    "libm/e_fmod.c",
    "libm/e_log.c",
    "libm/e_log10.c",
    "libm/e_pow.c",
    "libm/e_rem_pio2.c",
    "libm/e_sqrt.c",
    "libm/k_cos.c",
    "libm/k_rem_pio2.c",
    "libm/k_sin.c",
    "libm/k_tan.c",
    "libm/s_atan.c",
    "libm/s_copysign.c",
    "libm/s_cos.c",
    "libm/s_fabs.c",
    "libm/s_floor.c",
    "libm/s_isinf.c",
    "libm/s_isinff.c",
    "libm/s_isnan.c",
    "libm/s_isnanf.c",
    "libm/s_modf.c",
    "libm/s_scalbn.c",
    "libm/s_sin.c",
    "libm/s_tan.c",
    "locale/SDL_locale.c",
    "misc/SDL_url.c",
    "process/SDL_process.c",
    "process/dummy/SDL_dummyprocess.c",
    "render/SDL_render.c",
    "render/SDL_yuv_sw.c",
    "render/opengl/SDL_render_gl.c",
    "render/opengl/SDL_shaders_gl.c",
    "render/software/SDL_blendfillrect.c",
    "render/software/SDL_blendline.c",
    "render/software/SDL_blendpoint.c",
    "render/software/SDL_drawline.c",
    "render/software/SDL_drawpoint.c",
    "render/software/SDL_render_sw.c",
    "render/software/SDL_triangle.c",
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
    "video/SDL_blit_0.c",
    "video/SDL_blit_1.c",
    "video/SDL_blit_A.c",
    "video/SDL_blit_N.c",
    "video/SDL_blit_auto.c",
    "video/SDL_blit_copy.c",
    "video/SDL_blit_slow.c",
    "video/SDL_bmp.c",
    "video/SDL_clipboard.c",
    "video/SDL_egl.c",
    "video/SDL_fillrect.c",
    "video/SDL_pixels.c",
    "video/SDL_rect.c",
    "video/SDL_RLEaccel.c",
    "video/SDL_rotate.c",
    "video/SDL_stb.c",
    "video/SDL_stretch.c",
    "video/SDL_surface.c",
    "video/SDL_video.c",
    "video/SDL_vulkan_utils.c",
    "video/SDL_yuv.c",
    "video/yuv2rgb/yuv_rgb_lsx.c",
    "video/yuv2rgb/yuv_rgb_sse.c",
    "video/yuv2rgb/yuv_rgb_std.c",
};

const windows_sources = [_][]const u8{
    "core/windows/SDL_hid.c",
    "core/windows/SDL_windows.c",
    "filesystem/windows/SDL_sysfilesystem.c",
    "filesystem/windows/SDL_sysfsops.c",
    "loadso/windows/SDL_sysloadso.c",
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

// TODO: written but unverified, needs the Linux config + X11 headers.
const linux_sources = [_][]const u8{
    "core/unix/SDL_appid.c",
    "core/unix/SDL_poll.c",
    "core/linux/SDL_threadprio.c",
    "filesystem/posix/SDL_sysfsops.c",
    "filesystem/unix/SDL_sysfilesystem.c",
    "loadso/dlopen/SDL_sysloadso.c",
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
    "video/x11/SDL_x11modes.c",
    "video/x11/SDL_x11mouse.c",
    "video/x11/SDL_x11opengl.c",
    "video/x11/SDL_x11opengles.c",
    "video/x11/SDL_x11pen.c",
    "video/x11/SDL_x11settings.c",
    "video/x11/SDL_x11shape.c",
    "video/x11/SDL_x11touch.c",
    "video/x11/SDL_x11video.c",
    "video/x11/SDL_x11window.c",
    "video/x11/SDL_x11xfixes.c",
    "video/x11/SDL_x11xtest.c",
    "video/x11/SDL_x11xinput2.c",
    "video/x11/xsettings-client.c",
};
// TODO: written but unverified, needs macOS SDK.
const macos_sources = [_][]const u8{};
