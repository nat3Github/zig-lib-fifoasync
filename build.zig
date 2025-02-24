const std = @import("std");
// pub const delegator_gen = @import("src/delegator.zig");
// notes: when using a dependency in a generated file
// - generate the file
// lets say the generated file imports("xyz");
// - make a module x with addModule with the generated file as the root_source_file
// - make x depend on module xyz
// - add x to your executable with addImport
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run unit tests");
    const run_step = b.step("run", "Run the app");

    const ziggen = b.dependency("ziggen", .{
        .target = target,
        .optimize = std.builtin.OptimizeMode.ReleaseFast,
    });
    const ziggen_module = ziggen.module("ziggen");
    // make library module
    const fifoasync_module = b.addModule("fifoasync", .{
        .root_source_file = b.path("src/lib.zig"),
        .optimize = optimize,
        .target = target,
    });
    fifoasync_module.addImport("ziggen", ziggen_module);

    const struct_mod = b.addModule("examplestruct", .{ .root_source_file = b.path("test/some_struct.zig") });
    const src_generator = b.addExecutable(.{
        .name = "dev-src-gen",
        .root_source_file = b.path("tools/src_generator.zig"),
        .target = target,
        .optimize = .Debug,
    });
    src_generator.root_module.addImport("fifoasync", fifoasync_module);
    src_generator.root_module.addImport("examplestruct", struct_mod);
    const src_generator_run = b.addRunArtifact(src_generator);

    const generated_zig = src_generator_run.addOutputFileArg("delegator.zig");
    const auto_generated_mod = b.addModule("delegator", .{ .root_source_file = generated_zig });
    auto_generated_mod.addImport("examplestruct", struct_mod);

    const example_exe = b.addExecutable(.{
        .name = "meta example",
        .root_source_file = b.path("test/example.zig"),
        .target = target,
        .optimize = optimize,
    });

    example_exe.root_module.addImport("fifoasync", fifoasync_module);
    example_exe.root_module.addImport("examplestruct", struct_mod);
    example_exe.root_module.addImport("delegator", auto_generated_mod);
    b.installArtifact(example_exe);

    const run_cmd = b.addRunArtifact(example_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    const lib_test = b.addTest(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib_test_run = b.addRunArtifact(lib_test);
    test_step.dependOn(&lib_test_run.step);
}
