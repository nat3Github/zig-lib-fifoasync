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
    N_queues: usize,
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
        j.spawn(alloc, "gp task thread {}", .{i}, polling_worker, .{
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

const Executor = struct {
    sched: *Sched,
    que_idx: usize,
};
fn exe(self: *Executor, task: Task) anyerror!void {
    try self.sched.sched.spsc[self.que_idx].push(task);
}

pub fn get_executor(self: *Sched, queue_index: usize) root.sched.GenericAsyncExecutor(Executor, exe) {
    if (queue_index >= self.sched.spsc.len) @panic("oob");
    return .{
        .inner = Executor{
            .sched = self,
            .que_idx = queue_index,
        },
    };
}

const ExampleStruct = BaseSched.TestStruct;

test "sched test" {
    const alloc = std.testing.allocator;
    var ps = try Sched.init(alloc, .{
        .N_queues = 1,
        .N_threads = 2,
    });
    defer ps.deinit(alloc);
    const as_exe = ps.get_executor(0);

    var ex_struct = ExampleStruct{
        .age = 90,
        .name = "peter kunz",
        .timer = Timer.start() catch unreachable,
    };

    var ex_struct2 = ExampleStruct{
        .age = 90,
        .name = "peter kunz",
        .timer = Timer.start() catch unreachable,
    };

    var task = Task{};
    var task2 = Task{};

    std.Thread.sleep(10e6);

    for (0..2) |i| {
        _ = i;
        ex_struct.timer = Timer.start() catch unreachable;
        task.set(ExampleStruct, &ex_struct, ExampleStruct.say_my_name_type_erased);
        as_exe.exe(task);

        ex_struct2.timer = Timer.start() catch unreachable;
        task2.set(ExampleStruct, &ex_struct2, ExampleStruct.say_my_name_lie_type_erased);
        as_exe.exe(task2);

        std.Thread.sleep(200e6);
    }

    std.Thread.sleep(20e6);
}
test "test all refs" {
    std.testing.refAllDecls(@This());
}
