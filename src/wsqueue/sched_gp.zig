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
    yield_cfg: Yield.Config = .{ .alloc = undefined },
};

pub const Sched = @This();
const Yield = @import("yielding_sched.zig").YieldSched;

sched: BaseSched = .{},

const Signal = thread.Signal;
pub fn waiting_worker(
    ctrl: thread.ThreadStatus,
    self: *@This(),
    start_up_fn: anytype,
    wakeup_next: ?*ResetEvent,
    ycfg: Yield.Config,
) !void {
    try start_up_fn();
    assert(self.sched.spsc.len == 1);
    const spscs = self.sched.spsc;
    const spsc = &spscs[0];
    var nothing_count: u8 = 0;
    var backlog_count: usize = 0;
    var yield: Yield = .{};
    try yield.init(ycfg);
    defer yield.deinit();
    _ = loop: {
        while (true) {
            while (spsc.pop()) |task| {
                nothing_count = 0;
                // NOTE: if this is triggering an error the Maximum Concurrency is reached
                // essentially N number of tasks are yielding but not finishing (which could be a bug)
                try yield.execute(*Signal, ctrl.signal, Signal.is_running, task, self.async_executor());
                if (!ctrl.signal.is_running()) break :loop;
            }
            nothing_count += 1;
            if (yield.has_backlog()) {
                backlog_count += 1;
                if (!ctrl.signal.is_running()) break :loop;
                yield.process_backlog();
                if (backlog_count > 128) ctrl.wait(1_000_000) catch {};
                if (!ctrl.signal.is_running()) break :loop;
                nothing_count -= 1;
            } else backlog_count = 0;
            for (0..nothing_count) |_| {
                root.prim.yield_cpu();
            }
            if (nothing_count >= 16) {
                nothing_count = 0;
                if (!ctrl.signal.is_running()) break :loop;
                ctrl.wait(std.math.maxInt(u64)) catch {};
                ctrl.reset();
                if (!ctrl.signal.is_running()) break :loop;
                if (wakeup_next) |wn| {
                    wn.set();
                }
                continue;
            }
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

pub fn init(self: *@This(), alloc: Allocator, cfg: Config) !void {
    self.* = .{};
    var ycfg = cfg.yield_cfg;
    ycfg.alloc = alloc;
    assert(cfg.N_threads > 0);
    try self.sched.init(alloc, 1, cfg.N_threads, cfg.N_queue_capacity);
    errdefer self.sched.deinit(alloc);
    for (self.sched.threads, 0..) |*j, i| {
        var next: ?*ResetEvent = null;
        if (i != 0) {
            next = &self.sched.threads[i - 1].handle_sets_thread_waits;
        }
        try j.spawn(alloc, "GP task thread {}", .{i + 1}, waiting_worker, .{ self, cfg.startup_fn, next, ycfg });
        errdefer j.join(alloc);
    }
}

pub fn deinit(self: *Sched, alloc: Allocator) void {
    for (self.sched.threads) |*j| {
        j.join(alloc);
    }
    self.sched.deinit(alloc);
}
fn executor_deinit(self: *Sched) AsyncExecutor {
    return AsyncExecutor{ .ptr = @ptrCast(self), .vtable = &.{
        .execute_task_fn = exe_opaque,
        .yield_fn = yield_opaque,
    } };
}

fn exe(self: *Sched, task: Task) anyerror!void {
    try self.sched.push(0, task);
    self.wake_sched();
}

fn exe_opaque(self_ptr: *anyopaque, task: Task) anyerror!void {
    const self: *Sched = @ptrCast(@alignCast(self_ptr));
    try self.exe(task);
}
fn yield_opaque(_: *anyopaque) error{Cancelled}!void {
    Yield.yield();
}
pub fn async_executor(self: *Sched) AsyncExecutor {
    return AsyncExecutor{ .ptr = @ptrCast(self), .vtable = &.{
        .execute_task_fn = exe_opaque,
        .yield_fn = yield_opaque,
    } };
}

pub fn wake_sched(self: *Sched) void {
    const len = self.sched.threads.len;
    self.sched.threads[len - 1].wakeup();
}

fn recast(T: type, ptr: *anyopaque) *T {
    return @as(*T, @ptrCast(@alignCast(ptr)));
}
