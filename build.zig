const std = @import("std");

const builtin = @import("builtin");
const config = @import("src/config.zig");

pub fn build(b: *std.Build) void {
    const options = b.addOptions();

    const examples = b.option(bool, "examples", "Compiles example projects") orelse false;
    _ = examples; // autofix

    const build_sdl3 = b.option(bool, "build-sdl3", "Compiles SDL3 from source") orelse false;

    const platform = b.option(config.Platform, "platform", "Force use of specific platform implementation") orelse .default;
    options.addOption(config.Platform, "platform", platform);

    const graphics = b.option(config.Graphics, "graphics", "Force use of spesific graphics implementation") orelse .default;
    options.addOption(config.Graphics, "graphics", graphics);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.addModule("root", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    root_module.addOptions("saturn_config", options);

    if (platform == .default or platform == .force_sdl3) {
        if (build_sdl3) {
            const sdl3 = b.lazyDependency("sdl", .{
                .target = target,
                .optimize = optimize,
                .preferred_linkage = .dynamic,
            }).?;
            root_module.linkLibrary(sdl3.artifact("SDL3"));
        } else {
            root_module.link_libc = true;
            root_module.linkSystemLibrary("SDL3", .{ .preferred_link_mode = .dynamic });
        }
    }

    if (graphics == .default or graphics == .force_vulkan) {
        const vulkan_headers = b.lazyDependency("vulkan_headers", .{}).?;
        const vulkan = b.lazyDependency("vulkan", .{ .registry = vulkan_headers.path("registry/vk.xml") }).?;
        root_module.addImport("vulkan", vulkan.module("vulkan-zig"));
    }

    const mod_tests = b.addTest(.{ .root_module = root_module });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const use_llvm: ?bool = b.option(bool, "use-llvm", "Compile using llvm");
    buildExample(b, target, optimize, root_module, "triangle", "examples/triangle/main.zig", use_llvm);
    buildExample(b, target, optimize, root_module, "cube", "examples/cube/main.zig", use_llvm);
}

fn buildExample(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    saturn: *std.Build.Module,
    comptime exe_name: []const u8,
    root_path: []const u8,
    use_llvm: ?bool,
) void {
    const exe_mod = b.createModule(.{
        .root_source_file = b.path(root_path),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("saturn", saturn);

    const zmath = b.dependency("zmath", .{});
    exe_mod.addImport("zmath", zmath.module("root"));

    const zstbi = b.dependency("zstbi", .{});
    exe_mod.addImport("zstbi", zstbi.module("root"));

    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = exe_mod,
        .use_llvm = use_llvm,
    });
    b.installArtifact(exe);

    const run_string = "run-" ++ exe_name;
    const run_desc = "Run the " ++ exe_name ++ "example";
    const run_step = b.step(run_string, run_desc);
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
}
