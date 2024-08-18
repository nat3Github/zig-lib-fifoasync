const std = @import("std");
pub const delegator_gen = @import("src/delegator_gen.zig");
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
    //

    const example_exe = b.addExecutable(.{
        .name = "meta example",
        .root_source_file = b.path("src/example.zig"),
        .target = target,
        .optimize = optimize,
    });
    // add ziggen module:
    const ziggen_dependency = b.dependency("ziggen", .{
        .target = target,
        .optimize = optimize,
    });
    const ziggen_module = ziggen_dependency.module("ziggen");
    example_exe.root_module.addImport("ziggen", ziggen_module);
    b.installArtifact(example_exe);

    // run step for example_exe
    const run_cmd = b.addRunArtifact(example_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // test step
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const msgbird_test = b.addTest(.{
        .root_source_file = b.path("src/delegator_gen.zig"),
        .target = target,
        .optimize = optimize,
    });

    const msgbird_test_run = b.addRunArtifact(msgbird_test);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&msgbird_test_run.step);

    // make this a dependable module
    const module = b.addModule("fifoasync", .{ .root_source_file = b.path("src/lib.zig") });
    _ = module;
}
