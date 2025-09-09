/// - simple polling scheduler
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

const BaseSched = @import("base_sched.zig");

const assert = std.debug.assert;
const expect = std.testing.expect;

const default_start_fn = thread.prio.set_realtime_critical_highest;
pub const Config = struct {
    N_threads: usize,
    N_queue_capacity: usize = std.math.powi(usize, 2, 12) catch unreachable,
    startup_fn: *const fn () anyerror!void = default_start_fn,
    sleep_ns: u64 = 250,
};

pub const Sched = @This();

sched: BaseSched = .{},

pub fn polling_worker(
    ctrl: thread.ThreadStatus,
    self: *@This(),
    start_up_fn: anytype,
    sleep_ns: u64,
) !void {
    var t = root.thread.Timer.init() catch return;
    try start_up_fn();
    while (ctrl.signal.is_running()) {
        for (self.sched.spsc) |*q| {
            while (q.pop()) |task| {
                task.call(self.async_executor());
                if (ctrl.signal.is_stop_signal()) {
                    // clear queue and return
                    for (self.sched.spsc) |*q_| {
                        while (q_.pop()) |task_| {
                            task_.call(self.async_executor());
                        }
                    }
                    return;
                }
            }
        }
        t.rt_sleep(sleep_ns);
    }
}

pub fn init(self: *@This(), alloc: Allocator, cfg: Config) !void {
    assert(cfg.N_threads > 0);
    self.* = .{};
    try self.sched.init(alloc, 1, cfg.N_threads, cfg.N_queue_capacity);
    errdefer self.sched.deinit(alloc);
    for (self.sched.threads, 0..) |*j, i| {
        j.spawn(alloc, "RT task thread {}", .{i + 1}, polling_worker, .{ self, cfg.startup_fn, cfg.sleep_ns }) catch unreachable;
    }
}

pub fn deinit(self: *Sched, alloc: Allocator) void {
    for (self.sched.threads) |*j| {
        j.join(alloc);
    }
    self.sched.deinit(alloc);
}

pub fn async_executor(self: *Sched) root.sched.AsyncExecutor {
    return self.sched.async_executor();
}

const ExampleStruct = BaseSched.TestStruct;
