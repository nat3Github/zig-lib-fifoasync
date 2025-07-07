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

const default_start_fn = thread.prio.set_realtime_critical_high;

pub const Config = struct {
    N_threads: usize,
    N_queues: usize,
    N_queue_capacity: usize = std.math.powi(usize, 2, 12) catch unreachable,
    startup_fn: *const fn () anyerror!void = default_start_fn,
};

pub const Sched = @This();

sched: BaseSched,
lock: []Spinlock,
arena: std.heap.ArenaAllocator,

pub fn waiting_worker(
    ctrl: thread.ThreadStatus,
    spsc: []BaseSched.SPSC,
    lock: []Spinlock,
    start_up_fn: anytype,
    wakeup_next: ?*ResetEvent,
) !void {
    try start_up_fn();
    var nothing_count: u8 = 0;
    while (ctrl.signal.load() != .stop_signal) {
        for (spsc, lock) |*q, *l| {
            var popped: ?Task = null;
            if (l.try_lock()) {
                defer l.unlock();
                popped = q.pop();
            } else continue;
            if (popped) |task| {
                nothing_count = 0;
                task.call();
            } else {
                nothing_count += 1;
                if (nothing_count >= spsc.len * 2) {
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
    assert(cfg.N_queues != 0);
    assert(cfg.N_threads > 0);
    const lock = try alloc.alloc(Spinlock, cfg.N_queues);
    errdefer alloc.free(lock);
    for (lock) |*s| s.* = Spinlock{};

    var bsched = try BaseSched.init(alloc, cfg.N_queues, cfg.N_threads, cfg.N_queue_capacity);
    errdefer bsched.deinit(alloc);
    var arena = std.heap.ArenaAllocator.init(alloc);
    for (bsched.threads, 0..) |*j, i| {
        var next: ?*ResetEvent = null;
        if (i != 0) {
            next = &bsched.threads[i - 1].handle_sets_thread_waits;
        }
        const dbg_name = try std.fmt.allocPrint(arena.allocator(), "gp task thread {}", .{i});
        const th = try j.spawn(alloc, dbg_name, waiting_worker, .{ bsched.spsc, lock, cfg.startup_fn, next });
        errdefer {
            j.stop_or_timeout(3_000_000_000) catch {};
        }
        th.detach();
        j.spinwait_for_startup();
    }
    return Sched{
        .arena = arena,
        .sched = bsched,
        .lock = lock,
    };
}
pub fn deinit(self: *Sched, alloc: Allocator) void {
    for (self.sched.threads) |*j| {
        j.stop_or_timeout(3_000_000_000) catch {
            std.log.err("stop thread failed", .{});
        };
    }
    self.sched.deinit(alloc);
    alloc.free(self.lock);
    self.arena.deinit();
}

const Executor = struct {
    sched: *Sched,
    que_idx: usize,
};
fn exe(self: *Executor, task: Task) anyerror!void {
    try self.sched.sched.spsc[self.que_idx].push(task);
    self.sched.wake_sched();
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

pub fn wake_sched(self: *Sched) void {
    const len = self.sched.threads.len;
    self.sched.threads[len - 1].wakeup();
}

fn recast(T: type, ptr: *anyopaque) *T {
    return @as(*T, @alignCast(@ptrCast(ptr)));
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
