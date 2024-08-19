const std = @import("std");
pub const delegator_gen = @import("src/delegator-gen.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // make this a dependable module
    const example_module = b.addModule("example", .{ .root_source_file = b.path("src/example.zig") });

    const ziggen = b.dependency("ziggen", .{
        .target = target,
        .optimize = optimize,
    });
    const ziggen_module = ziggen.module("ziggen");

    const src_generator = b.addExecutable(.{
        .name = "dev-src-gen",
        .root_source_file = b.path("src/devtools.zig"),
        .target = target,
        .optimize = .Debug,
    });
    src_generator.root_module.addImport("ziggen", ziggen_module);
    src_generator.root_module.addImport("example", example_module);

    const src_generator_run = b.addRunArtifact(src_generator);

    const generated_zig = src_generator_run.addOutputFileArg("xx.zig");
    const xx_module = b.addModule("xx", .{ .root_source_file = generated_zig });
    xx_module.addImport("example", example_module);

    const example_exe = b.addExecutable(.{
        .name = "meta example",
        .root_source_file = b.path("src/example.zig"),
        .target = target,
        .optimize = optimize,
    });
    // example_exe.root_module.addIncludePath(generated_zig);
    // example_exe.step.dependOn(&generate_source_code_run.step);

    // add ziggen module to example_exe:
    example_exe.root_module.addImport("ziggen", ziggen_module);

    example_exe.root_module.addImport("example", example_module);
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
        .root_source_file = b.path("src/delegator-gen.zig"),
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
