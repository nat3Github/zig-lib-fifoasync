/// - simple scheduler using notification with resetEvents
/// - can use high priority threads
const std = @import("std");
const Allocator = std.mem.Allocator;
const ResetEvent = std.Thread.ResetEvent;
const root = @import("../root.zig");
const Task = root.sched.Task;
const thread = root.thread;
const Spinlock = root.prim.Spinlock;
const Timer = std.time.Timer;
const Atomic = root.util.atomic.AcqRelAtomic;
const AsyncExecutor = root.sched.AsyncExecutor;

const BaseSched = @import("base_sched.zig");
pub const Fifo = BaseSched.Fifo;

const assert = std.debug.assert;
const expect = std.testing.expect;

fn nothing() !void {}
pub const Config = struct {
    N_threads: usize,
    N_queue_capacity: usize = std.math.powi(usize, 2, 12) catch unreachable,
    startup_fn: *const fn () anyerror!void = nothing,
};

pub const Sched = @This();

sched: BaseSched = .{},

pub fn waiting_worker(
    ctrl: thread.ThreadStatus,
    self: *@This(),
    start_up_fn: anytype,
    wakeup_next: ?*ResetEvent,
) !void {
    try start_up_fn();
    const spsc = self.sched.spsc;
    var nothing_count: u8 = 0;
    while (ctrl.signal.load() != .stop_signal) {
        for (spsc) |*q| {
            const pop = q.pop();
            if (pop) |task| {
                nothing_count = 0;
                task.call(self.async_executor());
            } else {
                nothing_count += 1;
                for (0..nothing_count) |_| {
                    root.prim.yield_cpu();
                }
                if (nothing_count >= 16) {
                    nothing_count = 0;
                    ctrl.wait(std.math.maxInt(u64)) catch {};
                    ctrl.reset();
                    if (ctrl.signal.load() == .stop_signal) return;
                    if (wakeup_next) |wn| {
                        wn.set();
                    }
                    continue;
                }
            }
        }
    }
}

pub fn init(self: *@This(), alloc: Allocator, cfg: Config) !void {
    self.* = .{};
    assert(cfg.N_threads > 0);
    try self.sched.init(alloc, 1, cfg.N_threads, cfg.N_queue_capacity);
    errdefer self.sched.deinit(alloc);
    for (self.sched.threads, 0..) |*j, i| {
        var next: ?*ResetEvent = null;
        if (i != 0) {
            next = &self.sched.threads[i - 1].handle_sets_thread_waits;
        }
        try j.spawn(alloc, "GP task thread {}", .{i + 1}, waiting_worker, .{ self, cfg.startup_fn, next });
        errdefer j.join(alloc);
    }
}

pub fn deinit(self: *Sched, alloc: Allocator) void {
    for (self.sched.threads) |*j| {
        j.join(alloc);
    }
    self.sched.deinit(alloc);
}

fn exe(self: *Sched, task: Task) anyerror!void {
    try self.sched.push(0, task);
    self.wake_sched();
}

fn exe_opaque(self_ptr: *anyopaque, task: Task) anyerror!void {
    const self: *Sched = @alignCast(@ptrCast(self_ptr));
    try self.exe(task);
}
pub fn async_executor(self: *Sched) AsyncExecutor {
    return AsyncExecutor{ .ptr = @ptrCast(self), .vtable = &.{
        .execute_task_fn = exe_opaque,
    } };
}

pub fn wake_sched(self: *Sched) void {
    const len = self.sched.threads.len;
    self.sched.threads[len - 1].wakeup();
}

fn recast(T: type, ptr: *anyopaque) *T {
    return @as(*T, @alignCast(@ptrCast(ptr)));
}
