/// polling schedular using high priority threads
const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("../root.zig");
const Task = root.sched.Task;
const ThreadControl = root.thread.ThreadControl;
const Spinlock = root.prim.Spinlock;

const assert = std.debug.assert;
const expect = std.testing.expect;

pub const Sched = @This();
pub const Fifo = root.spsc.FlexFifo(Task, true, true);

threads: []ThreadControl = &.{},
spsc: []Fifo = &.{},

pub fn init(self: *Sched, alloc: Allocator, queues: usize, threads: usize, spsc_capacity: usize) !void {
    self.spsc = try alloc.alloc(Fifo, queues);
    errdefer alloc.free(self.spsc);
    for (self.spsc) |*j| {
        const q = try Fifo.init(alloc, spsc_capacity);
        errdefer q.deinit(alloc);
        j.* = q;
    }
    self.threads = try alloc.alloc(ThreadControl, threads);
    errdefer alloc.free(self.threads);
    for (self.threads) |*w| w.* = ThreadControl{};
}

pub fn deinit(self: *Sched, alloc: Allocator) void {
    for (self.spsc) |*q| {
        // cleanup leftover tasks
        while (q.pop()) |t| {
            // just use first queue
            t.call(self.async_executor());
        }
        q.deinit(alloc);
    }
    defer alloc.free(self.spsc);
    defer alloc.free(self.threads);
}

pub fn push(self: *Sched, que: usize, t: Task) !void {
    try self.spsc[que].push(t);
}

fn exe(self: *Sched, task: Task) anyerror!void {
    try self.push(0, task);
}

fn exe_opaque(self_ptr: *anyopaque, task: Task) anyerror!void {
    const self: *Sched = @ptrCast(@alignCast(self_ptr));
    try self.exe(task);
}
pub fn async_executor(self: *Sched) root.sched.AsyncExecutor {
    return .{
        .ptr = @ptrCast(self),
        .vtable = &.{
            .execute_task_fn = exe_opaque,
        },
    };
}

pub const TestStruct = struct {
    fn recast(T: type, ptr: *anyopaque) *T {
        return @as(*T, @ptrCast(@alignCast(ptr)));
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
