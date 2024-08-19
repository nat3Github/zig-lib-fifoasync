const std = @import("std");
pub const delegator_gen = @import("src/delegator-gen.zig");
const MyStruct = @import("src/example.zig").MyStruct;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // this generates an delegator with struct MyStruct from example.zig and writes it to src/generated.zig:
    const fs = std.fs;
    const src = delegator_gen.code_gen(
        MyStruct,
        "MyStruct",
        "NewStruct",
        delegator_gen.ziggen.fmt(true).fImport("src", "example.zig"),
    );
    const file = try fs.createFileAbsolute(b.path("src/generated.zig").getPath(b), .{});
    try file.writeAll(src);

    const ziggen_dependency = b.dependency("ziggen", .{
        .target = target,
        .optimize = optimize,
    });

    const example_exe = b.addExecutable(.{
        .name = "meta example",
        .root_source_file = b.path("src/example.zig"),
        .target = target,
        .optimize = optimize,
    });
    // add ziggen module to example_exe:
    const ziggen_module = ziggen_dependency.module("ziggen");
    example_exe.root_module.addImport("ziggen", ziggen_module);
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

    // make this a dependable module
    const module = b.addModule("fifoasync", .{ .root_source_file = b.path("src/server.zig") });
    _ = module;
}
