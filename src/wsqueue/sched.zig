/// polling schedular using high priority threads
const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("../root.zig");
const Task = root.sched.Task;
const ThreadControl = root.thread.ThreadControl;

const assert = std.debug.assert;
const expect = std.testing.expect;

pub const Sched = @This();
pub const SPSC = root.spsc.Fifo2(Task);

threads: []ThreadControl,
spsc: []root.spsc.Fifo2(Task),

pub fn init(alloc: Allocator, queues: usize, threads: usize, spsc_capacity: usize) !Sched {
    const spsc: []SPSC = try alloc.alloc(SPSC, queues);
    errdefer alloc.free(spsc);
    const wthandle: []ThreadControl = try alloc.alloc(ThreadControl, threads);
    errdefer alloc.free(wthandle);
    for (wthandle) |*w| w.* = ThreadControl{};
    for (spsc) |*j| {
        const q = try SPSC.init(alloc, spsc_capacity);
        errdefer q.deinit(alloc);
        j.* = q;
    }
    return Sched{
        .spsc = spsc,
        .threads = wthandle,
    };
}

pub fn deinit(self: *Sched, alloc: Allocator) void {
    for (self.spsc) |*q| {
        q.deinit(alloc);
    }
    defer alloc.free(self.spsc);
    defer alloc.free(self.threads);
}

pub const AsyncExecutor = struct {
    sched: *Sched,
    que_idx: usize,
    pub fn exe(self: AsyncExecutor, task: Task) void {
        self.sched.spsc[self.que_idx].push(task) catch unreachable;
    }
};

pub fn get_async_executor(self: *Sched, que_index: usize) AsyncExecutor {
    if (que_index >= self.mpmc.len) @panic("oob");
    return AsyncExecutor{
        .sched = self,
        .que_idx = que_index,
    };
}

pub const TestStruct = struct {
    fn recast(T: type, ptr: *anyopaque) *T {
        return @as(*T, @alignCast(@ptrCast(ptr)));
    }
    const This = @This();
    age: usize = 99,
    name: []const u8,
    timer: std.time.Timer,
    pub fn say_my_name(self: *This) void {
        self.time();
        // std.log.warn("my name is {s} and my age is {}", .{ self.name, self.age });
    }
    pub fn say_my_name_lie(self: *This) void {
        self.time();
        self.age -= 10;
        // std.log.warn("my name is peter schmutzig and my age is {}", .{self.age});
    }
    pub fn say_my_name_type_erased(any_self: *anyopaque) void {
        const self = recast(This, any_self);
        self.say_my_name();
    }
    fn time(self: *This) void {
        const t = self.timer.read();
        const t_f: f64 = @floatFromInt(t);
        _ = t_f;
        // std.log.warn("elapsed: {d:.3} ms", .{t_f / 1e6});
    }

    pub fn say_my_name_lie_type_erased(any_self: *anyopaque) void {
        const self = recast(This, any_self);
        self.say_my_name_lie();
    }
};
