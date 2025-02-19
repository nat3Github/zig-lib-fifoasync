// in here we are goin to generate the delegator structs
const std = @import("std");
const fifoasync = @import("fifoasync");
const CodeGen = fifoasync.Codegen;
const CodeGenConfig = fifoasync.CodeGenConfig;
const ziggenfmt = fifoasync.ziggen.SourcePub;
const example = @import("examplestruct");

pub fn main() !void {
    // this generates an delegator with struct MyStruct from example.zig and writes it to src/generated.zig:
    // const fs = std.fs;
    const config = comptime CodeGenConfig{
        .T = example.MyStruct,
        .imports = &.{
            ziggenfmt.Import_comptime("example_struct", "examplestruct"),
        },
    };

    const TCodeGen = CodeGen(config).init();
    // const src = codegen(MyStruct, "MyStruct", "NewStruct", ziggenfmt.Import("example_struct", "examplestruct"));
    const src = TCodeGen.generate();

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
