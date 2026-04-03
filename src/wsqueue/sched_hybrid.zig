/// - scheduler using polling and notification
/// - can use high priority threads
/// - only one thread is polling
/// - do not move this data structure after initialization
const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("../root.zig");
const Task = root.sched.Task;
const thread = root.thread;
const SchedGP = @import("sched_gp.zig");

const assert = std.debug.assert;

const default_start_fn = thread.prio.set_realtime_critical_highest;
pub const Config = struct {
    N_threads: usize,
    N_queue_capacity: usize = std.math.powi(usize, 2, 12) catch unreachable,
    startup_fn: *const fn () anyerror!void = default_start_fn,
    sleep_ns: u64 = 250,
    yield_cfg: Yield.Config = .{ .alloc = undefined },
};

pub const Sched = @This();
const Yield = @import("yielding_sched.zig").YieldSched;

sched_gp: SchedGP = undefined,
polling_thread: root.thread.ThreadControl = .{},

const Signal = thread.Signal;
pub fn hybrid_poller(
    ctrl: thread.ThreadStatus,
    self: *@This(),
    start_up_fn: anytype,
    sleep_ns: u64,
    ycfg: Yield.Config,
) !void {
    assert(self.sched_gp.sched.spsc.len == 1);
    const sched_gp = &self.sched_gp;
    const spsc = &self.sched_gp.sched.spsc[0];
    var t = root.thread.Timer.init() catch return;
    try start_up_fn();
    var yield: Yield = .{};
    try yield.init(ycfg);
    defer yield.deinit();
    var is_awake: bool = false;
    _ = loop: {
        while (true) {
            if (!ctrl.signal.is_running()) break :loop;
            if (yield.has_backlog()) {
                if (!ctrl.signal.is_running()) break :loop;
                yield.process_backlog();
                if (!ctrl.signal.is_running()) break :loop;
            }
            while (spsc.pop()) |task| {
                if (!is_awake) {
                    is_awake = true;
                    sched_gp.wake_sched();
                }
                try yield.execute(*Signal, ctrl.signal, Signal.is_running, task, self.async_executor());
                if (!ctrl.signal.is_running()) break :loop;
            }
            is_awake = false;
            t.rt_sleep(sleep_ns);
        }
    };
    // this loop clears the rest of the items (important since there could be state left in Yield)
    var max_iterations: u32 = 0;
    _ = loop: {
        while (true) {
            max_iterations += 1;
            // try to unstuck the system if some thread is being starved
            if (max_iterations % 1024 == 1023) std.Thread.sleep(1_000_000);
            if (spsc.pop()) |task| {
                try yield.execute(*Signal, ctrl.signal, Signal.is_running, task, self.async_executor());
                if (max_iterations > 128000) break;
            } else {
                if (yield.has_backlog()) {
                    yield.process_backlog();
                    continue;
                } else break :loop;
            }
        }
    };
}

/// - do not move this data structure after initialization
pub fn init(self: *Sched, alloc: Allocator, cfg: Config) !void {
    self.* = Sched{};
    var ycfg = cfg.yield_cfg;
    ycfg.alloc = alloc;
    assert(cfg.N_threads > 0);
    try self.sched_gp.init(alloc, .{
        .N_queue_capacity = cfg.N_queue_capacity,
        .N_threads = cfg.N_threads - 1,
        .startup_fn = cfg.startup_fn,
    });
    errdefer self.sched_gp.deinit(alloc);
    try self.polling_thread.spawn(alloc, "hybrid sched polling thread", .{}, hybrid_poller, .{ self, cfg.startup_fn, cfg.sleep_ns, ycfg });
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

fn yield_opaque(_: *anyopaque) error{Cancelled}!void {
    Yield.yield();
}
pub fn async_executor(self: *Sched) root.sched.AsyncExecutor {
    return root.sched.AsyncExecutor{ .ptr = @ptrCast(self), .vtable = &.{
        .execute_task_fn = exe_opaque,
        .yield_fn = yield_opaque,
    } };
}
