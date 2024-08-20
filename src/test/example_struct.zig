const std = @import("std");

pub const MyStruct = struct {
    const Self = @This();
    pub fn nothing() f32 {
        return 0.69;
    }
    pub fn something(x: i32, y: f32) void {
        _ = x;
        _ = y;
        std.debug.print("Something\n", .{});
    }
    pub fn selfFunction(self: *Self) u32 {
        _ = self;
        return 41;
    }
    pub fn selfFunction2(self: *MyStruct, k: f32) f32 {
        _ = self;
        return k;
    }
    pub fn kkkk(self: *Self, self2: *Self) []const u8 {
        _ = self;
        _ = self2;
        return "kkkk";
    }
};
