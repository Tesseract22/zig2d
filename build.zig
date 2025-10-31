const std = @import("std");
const Build = std.Build;
const LazyPath = Build.LazyPath;

var target: std.Build.ResolvedTarget = undefined;
var optimize: std.builtin.OptimizeMode = undefined;

var gl_mod: *Build.Module = undefined;


fn add_ui(b: *Build, mod: *Build.Module, is_windows: bool) void {
    mod.addCSourceFile(.{
        .flags = &.{ "-DRGFW_IMPLEMENTATION", "-DRGFW_OPENGL", "-DRGFW_ADVANCED_SMOOTH_RESIZE" },
        .language = .c,
        .file = b.path("thirdparty/RGFW/RGFW.h"),
    });
    mod.addCSourceFile(.{
        .flags = &.{ "-DGLAD_GL_IMPLEMENTATION", "-DGLAD_MALLOC=malloc", "-DGLAD_FREE=free" },
        .language = .c,
        .file = b.path("thirdparty/glad.h"),
    });
    mod.addCSourceFile(.{
        // .flags = &.{ "-D"}
        .language = .c,
        .file = b.path("thirdparty/lodepng/lodepng.c"),
    });
    mod.addCSourceFile(.{
        .flags = &.{ "-DSTB_TRUETYPE_IMPLEMENTATION" },
        .language = .c,
        .file = b.path("thirdparty/stb_truetype.h"),
    });
    if (is_windows) {
        mod.linkSystemLibrary("gdi32", .{});
        mod.linkSystemLibrary("opengl32", .{});
    }
}

fn add_exe(b: *Build, root: LazyPath, mod_name: []const u8, exe_name: []const u8) void {
    const mod = b.addModule(mod_name, .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .root_source_file = root,

    });
    mod.addIncludePath(b.path("."));
    mod.addImport("gl", gl_mod);

    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = mod
    });
    b.installArtifact(exe);

}

pub fn build(b: *std.Build) void {
    target = b.standardTargetOptions(.{});
    optimize = b.standardOptimizeOption(.{});

    gl_mod = b.addModule("gl", .{
        .optimize = optimize,
        .target = target,
        .root_source_file = b.path("src/gl/gl.zig"),
    });
    gl_mod.addIncludePath(b.path("."));
    add_ui(b, gl_mod, target.result.os.tag == .windows);

    add_exe(b, b.path("src/gl_ref.zig"), "gl_ref", "gl_ref");
    add_exe(b, b.path("src/demo.zig"), "demo", "demo");
    add_exe(b, b.path("src/ui.zig"), "ui", "ui");
    add_exe(b, b.path("src/truetype.zig"), "truetype", "truetype");
    
    // const tests = b.addTest(.{
    //    .root_module = main_mod,
    // });

    // const run_tests = b.addRunArtifact(tests);
    // const test_step = b.step("test", "run tests");
    // test_step.dependOn(&run_tests.step);

}
