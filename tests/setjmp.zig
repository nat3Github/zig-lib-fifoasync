const std = @import("std");
const root = @import("fifoasync");
const c = @cImport({
    @cInclude("setjmp.h");
});

/// idea per thread per core architecture
///
/// IO
///
/// try yield() -> intant cancelation
///
/// - simple polling scheduler
/// - can use high priority threads
const Allocator = std.mem.Allocator;
const ResetEvent = std.Thread.ResetEvent;
const Task = root.sched.Task;
const thread = root.thread;
const Spinlock = root.prim.Spinlock;
const Timer = std.time.Timer;
const Atomic = root.util.atomic.AcqRelAtomic;
const AsyncExecutor = root.sched.AsyncExecutor;

const assert = std.debug.assert;
const expect = std.testing.expect;

const default_start_fn = thread.prio.set_realtime_critical_highest;
pub const Config = struct {
    N_threads: usize,
    N_queue_capacity: usize = std.math.powi(usize, 2, 12) catch unreachable,
    startup_fn: *const fn () anyerror!void = default_start_fn,
    sleep_ns: u64 = 250,
};

const ThreadControl = root.thread.ThreadControl;

pub const RtSched2 = @This();
pub const Fifo = root.spsc.FlexFifo(Task, true, true);

threads: []ThreadControl = undefined,
time_critical: Fifo = undefined,
semi_critical: Fifo = undefined,

ll_exec: AsyncExecutor = undefined,
read_exec: AsyncExecutor = undefined,

task_context: Task.Context = undefined,

fn push_semi_critical(self_: *anyopaque, t: Task) !void {
    const self: *RtSched2 = @ptrCast(@alignCast(self_));
    try self.semi_critical.push(t);
}
fn push_time_critical(self_: *anyopaque, t: Task) !void {
    const self: *RtSched2 = @ptrCast(@alignCast(self_));
    try self.time_critical.push(t);
}
fn yield(self_: *anyopaque) Task.Context.CanceledError!void {
    const self: *RtSched2 = @ptrCast(@alignCast(self_));
    _ = self;
    @panic("check if critical stuff needs to run");
}

pub fn init(self: *RtSched2, alloc: Allocator, cfg: Config) !void {
    self.* = .{};
    self.time_critical = try Fifo.init(alloc, cfg.N_queue_capacity);
    errdefer self.time_critical.deinit(alloc);
    self.semi_critical = try Fifo.init(alloc, cfg.N_queue_capacity);
    errdefer self.time_critical.deinit(alloc);

    const wthandle: []ThreadControl = try alloc.alloc(ThreadControl, cfg.N_threads);
    errdefer alloc.free(wthandle);
    for (wthandle) |*w| w.* = ThreadControl{};
    assert(cfg.N_threads > 0);

    self.threads[0].spawn(alloc, "RtSched2 main thread", .{}, polling_worker, .{
        &self.time_critical,
        &self.semi_critical,
        cfg.startup_fn(),
        cfg.sleep_ns,
    });

    self.ll_exec.ptr = @ptrCast(self);
    self.ll_exec.execute = push_time_critical;
    self.read_exec.ptr = @ptrCast(self);
    self.read_exec.execute = push_semi_critical;
    self.task_context.ptr = @ptrCast(self);
    self.task_context.yield_fn = yield;
}

pub fn deinit(self: *RtSched2, alloc: Allocator) void {
    for (self.sched.threads) |*j| {
        j.join(alloc);
    }
    alloc.free(self.threads);
    self.semi_critical.deinit();
    self.time_critical.deinit();
}

const CRITICAL_RATIO = 16;

pub fn polling_worker(
    ctrl: thread.ThreadStatus,
    self: *RtSched2,
    start_up_fn: anytype,
    sleep_ns: u64,
) !void {
    if (true) @panic("finish coroutine style switching");
    var rt_timer = root.thread.sleep.Timer.init() catch return;
    try start_up_fn();
    while (true) {
        try ctrl.check_stop_signal();
        try self.do_critical_tasks(ctrl);
        rt_timer.rt_sleep(sleep_ns);
    }
}

fn do_critical_tasks(self: *RtSched2, ctrl: thread.ThreadStatus) thread.StopError!void {
    for (0..CRITICAL_RATIO) |_| {
        if (self.time_critical.pop()) |task| {
            task.call(self.task_context);
            try ctrl.check_stop_signal();
        } else break;
    }
}

var g_cb: struct {
    scheduler_env: c.jmp_buf = undefined,
    scheduler_env2: c.jmp_buf = undefined,
    task_one_env: c.jmp_buf = undefined,
} = undefined;

fn task_one() void {
    std.debug.print("Task ONE: Started.\n", .{});
    std.debug.print("Task ONE: Yielding back to Main...\n", .{});
    if (c.setjmp(&g_cb.task_one_env) == 0) {
        c.longjmp(&g_cb.scheduler_env, 1);
    }

    std.debug.print("Task Finishing: Started.\n", .{});
    c.longjmp(&g_cb.scheduler_env, 3);
}

pub fn main() void {
    std.debug.print("Main: Starting test.\n", .{});

    if (c.setjmp(&g_cb.scheduler_env) == 0) {
        task_one();
    }
    std.debug.print("Main: Scheduler resumed.\n", .{});

    if (c.setjmp(&g_cb.scheduler_env) == 0) {
        c.longjmp(&g_cb.task_one_env, 2);
    }

    std.debug.print("Main: Scheduler resumed. Test finished.\n", .{});
}
test {
    main();
}
