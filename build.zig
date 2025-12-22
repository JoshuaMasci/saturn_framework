const std = @import("std");

const builtin = @import("builtin");
const config = @import("src/config.zig");

pub fn build(b: *std.Build) void {
    const options = b.addOptions();

    const platform = b.option(config.Platform, "platform", "Force use of specific platform implementation") orelse .default;
    options.addOption(config.Platform, "platform", platform);

    const graphics = b.option(config.Graphics, "graphics", "Force use of spesific graphics implementation") orelse .default;
    options.addOption(config.Graphics, "graphics", graphics);

    const single_threaded = b.option(bool, "single_threaded", "Compiles implimentatiosn without locks") orelse false;
    options.addOption(bool, "single_threaded", single_threaded);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.addModule("root", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    root_module.addOptions("saturn_config", options);

    if (platform == .default or platform == .force_sdl3) {
        const sdl3 = b.lazyDependency("sdl", .{
            .target = target,
            .optimize = optimize,
            .preferred_linkage = .dynamic,
        }).?;
        root_module.linkLibrary(sdl3.artifact("SDL3"));

        //TODO: link system lib when avalible
        //root_module.linkSystemLibrary("SDL3", .{ .preferred_link_mode = .dynamic });
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

    //Triangle test
    {
        const use_llvm: ?bool = b.option(bool, "use-llvm", "Compile using llvm") orelse null;

        const exe_mod = b.createModule(.{
            .root_source_file = b.path("examples/triangle/triangle.zig"),
            .target = target,
            .optimize = optimize,
        });
        exe_mod.addImport("saturn", root_module);

        const exe = b.addExecutable(.{
            .name = "triangle",
            .root_module = exe_mod,
            .use_llvm = use_llvm,
        });
        b.installArtifact(exe);

        const run_step = b.step("run", "Run the triangle exampl");
        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);
        run_cmd.step.dependOn(b.getInstallStep());
    }
}
