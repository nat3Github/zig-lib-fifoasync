const std = @import("std");
pub const MyStruct = @import("some_struct2.zig").MyStruct;

pub const MyStructOG = struct {
    const Self = @This();
    pub fn void_fn(x: i32, y: f32) void {
        _ = x;
        _ = y;
        std.debug.print("void fn was called\n", .{});
    }
    pub fn i32_fn(x: i32, y: i32) i32 {
        std.debug.print("takes two i32 returns sum \n", .{});
        return x + y;
    }
    pub fn self_u32_fn(self: *Self) !u32 {
        std.debug.print("takes self returns 41_u32\n", .{});
        _ = self;
        return 41;
    }
    pub fn self_f32_fn(self: *MyStructOG, k: f32) f32 {
        std.debug.print("takes self and f32 returns f32\n", .{});
        _ = self;
        return k;
    }
};
