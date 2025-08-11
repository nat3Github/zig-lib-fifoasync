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
    N_queues: usize = 1,
    N_queue_capacity: usize = std.math.powi(usize, 2, 12) catch unreachable,
    startup_fn: *const fn () anyerror!void = default_start_fn,
};

pub const Sched = @This();

sched: BaseSched,

pub fn polling_worker(
    ctrl: thread.ThreadStatus,
    spsc: []BaseSched.SPSC,
    start_up_fn: anytype,
) !void {
    try start_up_fn();
    while (ctrl.signal.load() != .stop_signal) {
        for (spsc) |*q| {
            const pop = q.pop();
            if (pop) |task| task.call();
        }
    }
}

pub fn init(alloc: Allocator, cfg: Config) !Sched {
    assert(cfg.N_queues != 0);
    assert(cfg.N_threads > 0);
    var bsched = try BaseSched.init(alloc, cfg.N_queues, cfg.N_threads, cfg.N_queue_capacity);
    errdefer bsched.deinit(alloc);
    for (bsched.threads, 0..) |*j, i| {
        j.spawn(alloc, "RT task thread {}", .{i + 1}, polling_worker, .{
            bsched.spsc, cfg.startup_fn,
        }) catch unreachable;
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

const Exe = struct {
    sched: *Sched,
    que_idx: usize,
};
fn exe(self: *Exe, task: Task) anyerror!void {
    try self.sched.sched.spsc[self.que_idx].push(task);
}

fn exe_opaque(self_ptr: *anyopaque, task: Task) anyerror!void {
    const self: *Sched = @ptrCast(self_ptr);
    try self.exe(task);
}
pub fn async_executor(self: *Sched) root.sched.AsyncExecutor {
    return .{
        .ptr = @ptrCast(self),
        .f = exe_opaque,
    };
}

const ExampleStruct = BaseSched.TestStruct;
