pub const ASNode = @import("as_type_wrapper.zig").ASNode;
pub const ASFunction = @import("as_fn_wrapper.zig").ASFuture;
test "test submodules" {
    _ = .{
        ASNode,
        ASFunction,
    };
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("../root.zig");

const assert = std.debug.assert;
const expect = std.testing.expect;

/// Generic type erased Task
/// if arguments ore return values are needed they must be somehow stored in the instance
pub const Task = struct {
    const This = @This();
    instance: ?*anyopaque = null,
    task: ?*const fn (*anyopaque) void = null,

    pub fn init(alloc: Allocator) !*This {
        const t = try alloc.create(This);
        t.* = Task{};
        return t;
    }
    pub fn deinit(self: *This, alloc: Allocator) void {
        alloc.destroy(self);
    }
    /// the t_fn must re-cast the *anyopaque pointer to *T
    pub fn set(self: *This, T: type, t_ptr: *T, t_fn: *const fn (*anyopaque) void) void {
        const cast: *anyopaque = @ptrCast(t_ptr);
        self.instance = cast;
        self.task = t_fn;
    }
    pub fn call(self: *This) void {
        if (self.instance) |inst| {
            @call(.auto, self.task.?, .{inst});
        }
    }
};
