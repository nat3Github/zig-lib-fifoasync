/// - scheduler using polling and notification
/// - can use high priority threads
/// - only one thread is polling
/// - do not move this data structure after initialization
const std = @import("std");
const Allocator = std.mem.Allocator;
const ResetEvent = std.Thread.ResetEvent;
const root = @import("../root.zig");
const Task = root.sched.Task;
const thread = root.thread;
const Spinlock = root.prim.Spinlock;
const Timer = std.time.Timer;
const Atomic = root.util.atomic.AcqRelAtomic;

const SchedGP = @import("sched_gp.zig");

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

sched_gp: SchedGP = undefined,
polling_thread: root.thread.ThreadControl = .{},

pub fn hybrid_poller(
    ctrl: thread.ThreadStatus,
    self: *@This(),
    start_up_fn: anytype,
    sleep_ns: u64,
) !void {
    const sched_gp = &self.sched_gp;
    const spsc = self.sched_gp.sched.spsc;
    var t = root.thread.Timer.init() catch return;
    try start_up_fn();
    var is_awake: bool = false;
    while (ctrl.signal.is_running()) {
        const q = &spsc[0];
        while (q.pop()) |task| {
            if (!is_awake) {
                is_awake = true;
                sched_gp.wake_sched();
            }
            task.call(self.async_executor());
            if (!ctrl.signal.is_running()) {
                // clear queue and return
                for (spsc) |*q_| {
                    while (q_.pop()) |task_| {
                        task_.call(self.async_executor());
                    }
                }
                return;
            }
        }
        is_awake = false;
        t.rt_sleep(sleep_ns);
    }
}

/// - do not move this data structure after initialization
pub fn init(self: *Sched, alloc: Allocator, cfg: Config) !void {
    self.* = Sched{};
    assert(cfg.N_threads > 0);
    try self.sched_gp.init(alloc, .{
        .N_queue_capacity = cfg.N_queue_capacity,
        .N_threads = cfg.N_threads - 1,
        .startup_fn = cfg.startup_fn,
    });
    errdefer self.sched_gp.deinit(alloc);
    try self.polling_thread.spawn(alloc, "hybrid sched polling thread", .{}, hybrid_poller, .{ self, cfg.startup_fn, cfg.sleep_ns });
    errdefer self.polling_thread.join(alloc);
}

pub fn deinit(self: *Sched, alloc: Allocator) void {
    self.polling_thread.join(alloc);
    self.sched_gp.deinit(alloc);
}

fn exe(self: *Sched, task: Task) anyerror!void {
    try self.sched_gp.sched.push(0, task);
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
