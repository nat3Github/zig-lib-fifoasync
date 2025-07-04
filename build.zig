// auto gen code
// const struct_mod = b.addModule("examplestruct", .{ .root_source_file = b.path("test/some_struct.zig") });
// const src_generator = b.addExecutable(.{
//     .name = "dev-src-gen",
//     .root_source_file = b.path("tools/src_generator.zig"),
//     .target = target,
//     .optimize = .Debug,
// });

// src_generator.root_module.addImport("fifoasync", fifoasync_module);
// src_generator.root_module.addImport("examplestruct", struct_mod);
// const src_generator_run = b.addRunArtifact(src_generator);

// const generated_zig = src_generator_run.addOutputFileArg("delegator.zig");
// const auto_generated_mod = b.addModule("delegator", .{ .root_source_file = generated_zig });
// auto_generated_mod.addImport("examplestruct", struct_mod);
const std = @import("std");
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run unit tests");
    const opts = .{ .target = target, .optimize = optimize };

    const fifoasync_module = b.addModule("fifoasync", .{
        .root_source_file = b.path("src/root.zig"),
        .optimize = optimize,
        .target = target,
    });

    const mpmc_dep = b.dependency("mpmc", opts);
    const mpmc_module = mpmc_dep.module("mpmc");
    fifoasync_module.addImport("mpmc", mpmc_module);

    const zigwin_mod = b.dependency("zigwin32", .{}).module("win32");
    fifoasync_module.addImport("win32", zigwin_mod);

    fifoasync_module.addIncludePath(b.path("src/include/"));

    const fifoasync_test = b.addTest(.{
        .root_module = fifoasync_module,
        .target = target,
        .optimize = optimize,
    });
    const lib_test_run = b.addRunArtifact(fifoasync_test);
    test_step.dependOn(&lib_test_run.step);
}
