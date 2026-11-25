const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const run_step = b.step("run", "Run rex-gtk");
    const test_step = b.step("test", "Run unit tests");

    // Link the system's font libraries rather than building them from
    // source. Ghostty's wrapper packages read these options. Pass
    // -fno-sys=NAME to build one from source instead.
    for ([_][]const u8{ "freetype", "harfbuzz", "fontconfig", "libpng", "zlib" }) |name| {
        _ = b.systemIntegrationOption(name, .{ .default = true });
    }

    const ghostty = b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    }) orelse return;
    const vt_mod = ghostty.module("ghostty-vt");

    // Modules that don't depend on GTK. Kept separate so `zig build test`
    // and the headless tools never need a display.
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_mod.addImport("ghostty-vt", vt_mod);

    const ghostty_render = addGhosttyRender(b, ghostty, vt_mod, target, optimize) orelse return;
    const render_mod = b.createModule(.{
        .root_source_file = b.path("src/render/render.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ghostty-render", .module = ghostty_render },
            .{ .name = "ghostty-vt", .module = vt_mod },
            .{ .name = "core", .module = core_mod },
        },
    });

    // The GTK application.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("core", core_mod);
    exe_mod.addImport("render", render_mod);
    if (b.lazyDependency("gobject", .{
        .target = target,
        .optimize = optimize,
    })) |gobject| {
        const imports = .{
            .{ "adw", "adw1" },
            .{ "gdk", "gdk4" },
            .{ "gio", "gio2" },
            .{ "glib", "glib2" },
            .{ "gobject", "gobject2" },
            .{ "graphene", "graphene1" },
            .{ "gsk", "gsk4" },
            .{ "gtk", "gtk4" },
            .{ "pango", "pango1" },
        };
        inline for (imports) |import| {
            const name, const module = import;
            exe_mod.addImport(name, gobject.module(module));
        }
    }

    const exe = b.addExecutable(.{
        .name = "rex-gtk",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Desktop integration, for `zig build install --prefix ~/.local` and packages.
    b.installFile("dist/dev.ligabloo.RexGtk.desktop", "share/applications/dev.ligabloo.RexGtk.desktop");
    b.installFile("dist/dev.ligabloo.RexGtk.metainfo.xml", "share/metainfo/dev.ligabloo.RexGtk.metainfo.xml");
    b.installFile(
        "dist/icons/hicolor/scalable/apps/dev.ligabloo.RexGtk.svg",
        "share/icons/hicolor/scalable/apps/dev.ligabloo.RexGtk.svg",
    );
    // rex-gtk includes code derived from Ghostty, under Ghostty's MIT license.
    b.getInstallStep().dependOn(&b.addInstallFile(ghostty.path("LICENSE"), "share/licenses/rex-gtk/LICENSE.ghostty").step);
    b.installFile("LICENSE", "share/licenses/rex-gtk/LICENSE");

    // The headless tools are for development; packages can leave them out.
    const install_tools = b.option(bool, "tools", "Install rexcat, rexshot and fontcheck (default: true)") orelse true;

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    // Headless tools.
    const rexcat = b.addExecutable(.{
        .name = "rexcat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/rexcat.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "core", .module = core_mod }},
        }),
    });
    if (install_tools) b.installArtifact(rexcat);

    const fontcheck = b.addExecutable(.{
        .name = "fontcheck",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/fontcheck.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "render", .module = render_mod }},
        }),
    });
    if (install_tools) b.installArtifact(fontcheck);

    const rexshot = b.addExecutable(.{
        .name = "rexshot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/rexshot.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "render", .module = render_mod },
                .{ .name = "core", .module = core_mod },
            },
        }),
    });
    if (install_tools) b.installArtifact(rexshot);

    // Unit tests run against the GTK-free core only.
    const core_tests = b.addTest(.{ .root_module = core_mod });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    // GTK-free parts of the UI.
    const keymap_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/ui/keymap.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(keymap_tests).step);
}

/// The Ghostty source files the font stack and the OpenGL renderer need,
/// copied from the pinned Ghostty package. Everything else they would pull
/// in is replaced by the shims in src/render/ghostty_shim.
const ghostty_dirs = [_][]const u8{
    "font",
    "datastruct",
    "unicode",
    "lib/compat",
    "renderer/opengl",
    "renderer/shaders",
};
const ghostty_files = [_][]const u8{
    "fastmem.zig",
    "quirks.zig",
    "tripwire.zig",
    "math.zig",
    "stb/main.zig",
    "renderer/size.zig",
    "renderer/cell.zig",
    "renderer/row.zig",
    "renderer/cursor.zig",
    "renderer/Dmabuf.zig",
    "input/keycodes.zig",
};
const shim_files = [_][]const u8{
    "root.zig",
    "config.zig",
    "global.zig",
    "build_config.zig",
    "renderer.zig",
    "renderer/OpenGL.zig",
    "input/key.zig",
    "terminal/main.zig",
    "terminal/size.zig",
    "os/main.zig",
    "os/wasm.zig",
    "os/wasm/target.zig",
};

/// Build the `ghostty-render` module: Ghostty's font discovery, fallback,
/// shaping, rasterizing, glyph atlas and OpenGL drawing code. See
/// src/render/ghostty_shim/root.zig.
fn addGhosttyRender(
    b: *std.Build,
    ghostty: *std.Build.Dependency,
    vt_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ?*std.Build.Module {
    const gb = ghostty.builder;
    const src = ghostty.path("src");

    const wf = b.addWriteFiles();
    for (ghostty_dirs) |dir| {
        _ = wf.addCopyDirectory(src.path(b, dir), dir, .{});
    }
    for (ghostty_files) |file| {
        _ = wf.addCopyFile(src.path(b, file), file);
    }
    for (shim_files) |file| {
        _ = wf.addCopyFile(b.path(b.fmt("src/render/ghostty_shim/{s}", .{file})), file);
    }
    const stb_h = wf.add("stb_c.h",
        \\#include <stb_image.h>
        \\#include <stb_image_resize.h>
        \\
    );

    const mod = b.createModule(.{
        .root_source_file = wf.getDirectory().path(b, "root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    mod.addImport("ghostty-vt", vt_mod);

    // Generated modules the copied sources import. ghostty-vt already has them.
    for ([_][]const u8{ "uucode", "unicode_tables", "symbols_tables", "terminal_options", "wuffs" }) |name| {
        const dep_mod = vt_mod.import_table.get(name) orelse
            std.debug.panic("ghostty-vt has no {s} import; the pin's build layout changed", .{name});
        mod.addImport(name, dep_mod);
    }

    // Ghostty's Zig wrappers for the C font libraries.
    // Same arguments as Ghostty's harfbuzz package uses, so both get the
    // same instance of the freetype module.
    const freetype = gb.lazyDependency("freetype", .{
        .target = target,
        .optimize = optimize,
        .@"enable-libpng" = true,
    }) orelse return null;
    const harfbuzz = gb.lazyDependency("harfbuzz", .{
        .target = target,
        .optimize = optimize,
        .@"enable-freetype" = true,
        .@"enable-coretext" = false,
    }) orelse return null;
    const fontconfig = gb.lazyDependency("fontconfig", .{ .target = target, .optimize = optimize }) orelse return null;
    const z2d = gb.lazyDependency("z2d", .{ .target = target, .optimize = optimize }) orelse return null;
    mod.addImport("freetype", freetype.module("freetype"));
    mod.addImport("harfbuzz", harfbuzz.module("harfbuzz"));
    mod.addImport("fontconfig", fontconfig.module("fontconfig"));
    mod.addImport("z2d", z2d.module("z2d"));
    for ([_][]const u8{ "freetype2", "harfbuzz", "fontconfig" }) |lib| {
        mod.linkSystemLibrary(lib, .{ .use_pkg_config = .yes });
    }

    // Fonts Ghostty embeds as fallbacks (src/font/embedded.zig).
    const jb_mono = gb.lazyDependency("jetbrains_mono", .{}) orelse return null;
    const nf_symbols = gb.lazyDependency("nerd_fonts_symbols_only", .{}) orelse return null;
    const embedded = [_]struct { []const u8, std.Build.LazyPath }{
        .{ "jetbrains_mono_regular", jb_mono.path("fonts/ttf/JetBrainsMono-Regular.ttf") },
        .{ "jetbrains_mono_bold", jb_mono.path("fonts/ttf/JetBrainsMono-Bold.ttf") },
        .{ "jetbrains_mono_italic", jb_mono.path("fonts/ttf/JetBrainsMono-Italic.ttf") },
        .{ "jetbrains_mono_bold_italic", jb_mono.path("fonts/ttf/JetBrainsMono-BoldItalic.ttf") },
        .{ "jetbrains_mono_variable", jb_mono.path("fonts/variable/JetBrainsMono[wght].ttf") },
        .{ "jetbrains_mono_variable_italic", jb_mono.path("fonts/variable/JetBrainsMono-Italic[wght].ttf") },
        .{ "nerd_fonts_symbols_only", nf_symbols.path("SymbolsNerdFont-Regular.ttf") },
    };
    for (embedded) |entry| {
        const name, const path = entry;
        mod.addAnonymousImport(name, .{ .root_source_file = path });
    }

    // stb_image / stb_image_resize, used for color emoji.
    const stb = b.addTranslateC(.{
        .root_source_file = stb_h,
        .target = target,
        .optimize = optimize,
    });
    stb.addIncludePath(src.path(b, "stb"));
    mod.addImport("stb_c", stb.createModule());
    mod.addIncludePath(src.path(b, "stb"));
    mod.addCSourceFile(.{ .file = src.path(b, "stb/stb.c") });

    // OpenGL and EGL: Ghostty's bindings, the glad loaders it vendors, and
    // the system EGL. The renderer uses a surfaceless EGL context, so it
    // needs no window system.
    const opengl = gb.lazyDependency("opengl", .{}) orelse return null;
    mod.addImport("opengl", opengl.module("opengl"));
    mod.addIncludePath(ghostty.path("vendor/glad/include"));
    mod.addCSourceFiles(.{
        .root = ghostty.path("vendor/glad/src"),
        .files = &.{ "gl.c", "glad_egl.c" },
    });
    mod.linkSystemLibrary("egl", .{ .use_pkg_config = .yes });

    return mod;
}
