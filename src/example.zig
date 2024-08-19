const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const heap = std.heap;
const Ast = std.zig.Ast;
const server = @import("server.zig");

pub const MyStruct = struct {
    const Self = @This();
    pub fn nothing() f32 {}
    pub fn something(x: i32, y: f32) void {
        _ = x;
        _ = y;
        std.debug.print("Something\n", .{});
    }
    pub fn selfFunction(self: *Self, self2: *Self) u32 {
        _ = self;
        _ = self2;
        return 41;
    }
    pub fn kkkk(self: *Self, self2: *Self) []const u8 {
        _ = self;
        _ = self2;
        return "kkkk";
    }
};

// pub fn main(b: *std.Build) !void {
pub fn main() !void {
    // const gen_out = b.path("src/generated/person.zig");
    var heapalloc = heap.GeneralPurposeAllocator(.{}){};
    const gpa = heapalloc.allocator();
    // we generated the generated.zig file in the build.zig now import it
    const AutoGen = @import("xx");
    const capacity = 16;
    const Channel = server.DelegatorChannel(AutoGen.NewStructArgs, AutoGen.NewStructRet, capacity);
    const MyStructAS = AutoGen.NewStruct(*Channel);
    const MyStructServerAS = server.DelegatorThread(MyStructAS, AutoGen.NewStructArgs, AutoGen.NewStructRet, capacity);
    const instance = MyStruct{};
    const server_as = try MyStructServerAS.init(gpa, instance);
    defer server_as.deinit();
    const channel = server_as.get_channel();

    const my_struct_as = MyStructAS{ .channel = channel };
    const handle = server_as.get_wake_handle();

    try my_struct_as.something(&MyStruct{});
    handle.set();
    std.time.sleep(100 * 1_000_000);
    try my_struct_as.kkkk(&MyStruct{});
    handle.set();
    std.time.sleep(100 * 1_000_000);
    try my_struct_as.nothing(&MyStruct{});
    handle.set();
    std.time.sleep(100 * 1_000_000);
    try my_struct_as.selfFunction(&MyStruct{});
    handle.set();
    std.time.sleep(100 * 1_000_000);
}

// const str = delegator.code_gen(
//     MyStruct,
//     "MyStruct",
//     "NewStruct",
//     ziggen.fmt(true).fImport("main", "main.zig"),
// );
// std.debug.print("{s}", .{str});

// const input = try fs.openFileAbsolute(gen_out.getPath(b), .{});
// const source = try zig.readSourceFileToEndAlloc(gpa, input, 0);
// var ast = try zig.Ast.parse(gpa, source, .zig);
// defer ast.deinit(gpa);
// std.debug.print("AST:\n{any}\n", .{ast});
// const rendered_ast = try ast.render(gpa);
// std.debug.print("AST => SRC\n{s}", .{rendered_ast});
// const list = comptime meta_toolkit.struct_fn_names(MyStruct);
// inline for (list) |item| {
//     std.debug.print("{s}\n", .{item});
//     const xfn = meta_toolkit.struct_fn(MyStruct, item);
//     std.debug.print("return type: {any}\n", .{xfn.return_type});
// }

// var writer = std.io.getStdOut().writer();
