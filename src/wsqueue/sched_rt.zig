/// simple polling schedular using high priority threads
/// uses spsc queues
const std = @import("std");
const Allocator = std.mem.Allocator;
const ResetEvent = std.Thread.ResetEvent;
const root = @import("../root.zig");
const Task = root.sched.Task;
const thread = root.thread;
const Spinlock = root.prim.Spinlock;
const Timer = std.time.Timer;
const Atomic = root.util.atomic.AcqRelAtomic;

const BaseSched = @import("sched.zig");

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

sched: BaseSched,

pub fn polling_worker(
    ctrl: thread.ThreadStatus,
    spsc: []BaseSched.SPSC,
    start_up_fn: anytype,
    sleep_ns: u64,
) !void {
    var t = root.thread.sleep.Timer.init() catch return;
    try start_up_fn();
    while (ctrl.signal.load() != .stop_signal) {
        for (spsc) |*q| {
            while (q.pop()) |task| {
                task.call();
                if (ctrl.signal.load() == .stop_signal) return;
            }
        }
        t.rt_sleep(sleep_ns);
    }
}

pub fn init(alloc: Allocator, cfg: Config) !Sched {
    assert(cfg.N_threads > 0);
    var bsched = try BaseSched.init(alloc, 1, cfg.N_threads, cfg.N_queue_capacity);
    errdefer bsched.deinit(alloc);
    for (bsched.threads, 0..) |*j, i| {
        j.spawn(alloc, "RT task thread {}", .{i + 1}, polling_worker, .{ bsched.spsc, cfg.startup_fn, cfg.sleep_ns }) catch unreachable;
    }
    return Sched{
        .sched = bsched,
    };
}

pub fn deinit(self: *Sched, alloc: Allocator) void {
    for (self.sched.threads) |*j| {
        j.join(alloc);
    }
    self.sched.deinit(alloc);
}

fn exe(self: *Sched, task: Task) anyerror!void {
    try self.sched.spsc[0].push(task);
}

fn exe_opaque(self_ptr: *anyopaque, task: Task) anyerror!void {
    const self: *Sched = @alignCast(@ptrCast(self_ptr));
    try self.exe(task);
}
pub fn async_executor(self: *Sched) root.sched.AsyncExecutor {
    return .{
        .ptr = @ptrCast(self),
        .f = exe_opaque,
    };
}

const ExampleStruct = BaseSched.TestStruct;
