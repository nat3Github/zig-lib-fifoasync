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
    // const std_module = b.addModule("std", .{ .root_source_file = b.path("src/tools/std.zig") });
    // ziggen
    const ziggen = b.dependency("ziggen", .{
        .target = target,
        .optimize = optimize,
    });
    const ziggen_module = ziggen.module("ziggen");
    // make library module
    const fifoasync_module = b.addModule("fifoasync", .{
        .root_source_file = b.path("src/server.zig"),
    });
    fifoasync_module.addImport("ziggen", ziggen_module);

    const struct_module = b.addModule("examplestruct", .{ .root_source_file = b.path("src/test/example_struct.zig") });

    const src_generator = b.addExecutable(.{
        .name = "dev-src-gen",
        .root_source_file = b.path("src/tools/devtools.zig"),
        .target = target,
        .optimize = .Debug,
    });
    src_generator.root_module.addImport("fifoasync", fifoasync_module);
    src_generator.root_module.addImport("examplestruct", struct_module);
    const src_generator_run = b.addRunArtifact(src_generator);
    const generated_zig = src_generator_run.addOutputFileArg("xx.zig");

    const xx_module = b.addModule("xx", .{ .root_source_file = generated_zig });
    xx_module.addImport("examplestruct", struct_module);

    const example_exe = b.addExecutable(.{
        .name = "meta example",
        .root_source_file = b.path("src/test/example.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_exe.root_module.addImport("fifoasync", fifoasync_module);
    // add generated.zig
    example_exe.root_module.addImport("xx", xx_module);
    b.installArtifact(example_exe);

    // run step for example_exe
    const run_cmd = b.addRunArtifact(example_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // add test
    const codegen_test = b.addTest(.{
        .root_source_file = b.path("src/delegator.zig"),
        .target = target,
        .optimize = optimize,
    });
    const codegen_test_run = b.addRunArtifact(codegen_test);
    const server_test = b.addTest(.{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    const server_test_run = b.addRunArtifact(server_test);
    const spsc_test = b.addTest(.{
        .root_source_file = b.path("src/weakrb-spsc.zig"),
        .target = target,
        .optimize = optimize,
    });
    const spsc_test_run = b.addRunArtifact(spsc_test);

    // run tests
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&codegen_test_run.step);
    test_step.dependOn(&server_test_run.step);
    test_step.dependOn(&spsc_test_run.step);
}
