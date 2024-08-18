const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const heap = std.heap;
const Ast = std.zig.Ast;

const delegator = @import("delegator-gen.zig");
const ziggen = delegator.ziggen;

pub const MyStruct = struct {
    const Self = @This();
    pub fn nothing() f32 {}
    pub fn something(x: i32, y: f32) void {
        _ = x;
        _ = y;
    }
    pub fn selfFunction(self: *Self, self2: *Self) void {
        _ = self;
        _ = self2;
    }
    pub fn kkkk(self: *Self, self2: *Self) void {
        _ = self;
        _ = self2;
    }
};

// pub fn main(b: *std.Build) !void {
pub fn main() !void {
    // const gen_out = b.path("src/generated/person.zig");
    // var heapalloc = heap.GeneralPurposeAllocator(.{}){};
    // const gpa = heapalloc.allocator();
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

    // std.debug.print("{s}", .{try ziggen.make_call_clone(MyStruct, "MyClone", gpa)});
    const str = delegator.code_gen(
        MyStruct,
        "MyStruct",
        "NewStruct",
        ziggen.fmt(true).fImport("main", "main.zig"),
    );
    std.debug.print("{s}", .{str});
}
