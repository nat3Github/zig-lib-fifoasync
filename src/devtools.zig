// in here we are goin to generate the delegator structs
const std = @import("std");
const gen = @import("delegator-gen.zig");
const example = @import("example");

pub fn main() !void {

    // this generates an delegator with struct MyStruct from example.zig and writes it to src/generated.zig:
    const MyStruct = example.MyStruct;
    // const fs = std.fs;
    const src = gen.code_gen(MyStruct, "MyStruct", "NewStruct", gen.ziggen.fmt(true).fImport("ziggen", "ziggen") ++ "\n" ++ gen.ziggen.fmt(true).fImport("example", "example"));
    // const dir = try fs.cwd().openDir("src", .{});
    // const file = try dir.createFile("generated.zig", .{});
    // const file = try fs.kj(b.path("src/generated.zig").getPath(b), .{});
    // try file.writeAll(src);
    try std.io.getStdOut().writeAll(src);
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    if (args.len != 2) fatal("wrong number of arguments", .{});

    const output_file_path = args[1];

    var output_file = std.fs.cwd().createFile(output_file_path, .{}) catch |err| {
        fatal("unable to open '{s}': {s}", .{ output_file_path, @errorName(err) });
    };
    defer output_file.close();

    try output_file.writeAll(src);
    return std.process.cleanExit();
}
fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}
