/// simple sched using high priority threads and condition variables
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

fn nothing() !void {}
pub const Config = struct {
    N_threads: usize,
    N_queue_capacity: usize = std.math.powi(usize, 2, 12) catch unreachable,
    startup_fn: *const fn () anyerror!void = nothing,
};

pub const Sched = @This();

sched: BaseSched,

pub fn waiting_worker(
    ctrl: thread.ThreadStatus,
    spsc: []BaseSched.SPSC,
    start_up_fn: anytype,
    wakeup_next: ?*ResetEvent,
) !void {
    try start_up_fn();
    var nothing_count: u8 = 0;
    while (ctrl.signal.load() != .stop_signal) {
        for (spsc) |*q| {
            const pop = q.pop();
            if (pop) |task| {
                nothing_count = 0;
                task.call();
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

pub fn init(alloc: Allocator, cfg: Config) !Sched {
    assert(cfg.N_threads > 0);
    var bsched = try BaseSched.init(alloc, 1, cfg.N_threads, cfg.N_queue_capacity);
    errdefer bsched.deinit(alloc);
    for (bsched.threads, 0..) |*j, i| {
        var next: ?*ResetEvent = null;
        if (i != 0) {
            next = &bsched.threads[i - 1].handle_sets_thread_waits;
        }
        try j.spawn(alloc, "GP task thread {}", .{i + 1}, waiting_worker, .{ bsched.spsc, cfg.startup_fn, next });
        errdefer j.join(alloc);
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
    self.wake_sched();
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

pub fn wake_sched(self: *Sched) void {
    const len = self.sched.threads.len;
    self.sched.threads[len - 1].wakeup();
}

fn recast(T: type, ptr: *anyopaque) *T {
    return @as(*T, @alignCast(@ptrCast(ptr)));
}
