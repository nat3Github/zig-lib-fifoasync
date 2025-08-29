const std = @import("std");
const update = @import("update_tool");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    if (update.updateDependencies(b, &.{
        .{
            .branch = "main",
            .url = "https://github.com/nat3Github/zig-lib-update",
        },
        .{
            // win32
            .url = "https://github.com/marlersoft/zigwin32",
            .branch = "main",
        },
    }, .{
        .name = "update",
        .optimize = optimize,
        .target = target,
    })) return;

    const fifoasync_module = b.addModule("fifoasync", .{
        .root_source_file = b.path("src/root.zig"),
        .optimize = optimize,
        .target = target,
        .link_libc = true,
    });

    const zigwin_mod = b.dependency("zigwin32", .{}).module("win32");
    fifoasync_module.addImport("win32", zigwin_mod);

    fifoasync_module.addIncludePath(b.path("src/include/"));

    try update.addTestFolder(b, "tests", optimize, target, &.{
        .{ .name = "fifoasync", .mod = fifoasync_module },
    }, "test");
}
