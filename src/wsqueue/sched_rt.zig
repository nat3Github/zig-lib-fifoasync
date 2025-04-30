/// data is generally on the heap because it is shared between threads (most parts of it)
/// in an nondeterministic os thread does not know when it gets woken up (+- a few milli secods)
/// we need some polling approach to minimize latency
/// if we wake up only to spin we are wasting a lot of resources
/// idea:
/// bounded mpmc high priority task queue, 1 or more bounded mpmc low priority task queues, N threads;
/// algo simple:
/// a thread wakes up, checks the highest priority task queue,
///     if it finds a task it does it, go to top
///     else
///         check lower priority queue fetch a task after that go to top
///
/// optimize efficiency: measure load if load is low threads can be reduced
///
///
///
///
/// Multiple MPMC QUE TIER for different priority TASKS
/// threads always check TIER 1 first -> low latency tasks
/// when there are no TIER 1 tasks -> check TIER 2 tasks
///
/// if the system is overloaded lower TIER tasks could starve
///
///
const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("../root.zig");
const Task = root.sched.Task;
const thread = root.thread;
const Thread = thread.Thread;
const Control = thread.Control;
const Timer = std.time.Timer;

const assert = std.debug.assert;
const expect = std.testing.expect;

// const rtsp = root.threads.rtschedule;
const Atomic = std.atomic.Value;
const AtomicOrder = std.builtin.AtomicOrder;
const AtomicU8 = Atomic(u8);
const AtomicU32 = Atomic(u32);
const ResetEvent = std.Thread.ResetEvent;

const fifoasync = @import("fifoasync");
const lib_mpmc = @import("mpmc");

/// NOTE improvements for later: how does one realize begin date and due date?
///  -> planning of tasks
///  -> do tasks dependent on there due date
///
const MPMC = lib_mpmc.MPMC_SQC(.{ .order = 16, .slot_count = 16384, .T = Task });

pub const Sched = @This();
tier_list: []*AtomicU32,
threads: []Thread,
mpmc: []MPMC,
free_slot: AtomicU32,
arena: std.heap.ArenaAllocator,

pub fn polling_tier_based_worker(
    ctrl: Control,
    mpmc: []MPMC,
    tier_thread_count: []*AtomicU32,
) !void {
    var tier: usize = 0;
    var t = try Timer.start();
    while (ctrl.is_running()) {
        t.reset();
        var queue = mpmc[tier];
        const popped = queue.pop();
        if (popped) |task| {
            task.call();
            switch_to_tier(tier_thread_count, &tier, 0);
        } else {
            if (tier + 1 == tier_thread_count.len) {
                switch_to_tier(tier_thread_count, &tier, 0);
            } else {
                switch_to_tier(tier_thread_count, &tier, tier + 1);
            }
        }
    }
}

/// correclty adjusts the tier counts
fn switch_to_tier(tier_thread_count: []*AtomicU32, current_tier: *usize, tier: usize) void {
    assert(tier >= 0 and tier < tier_thread_count.len);
    if (current_tier.* == tier) return;
    _ = tier_thread_count[current_tier.*].fetchSub(1, .acq_rel);
    current_tier.* = tier;
    _ = tier_thread_count[current_tier.*].fetchAdd(1, .acq_rel);
}

pub fn init_stack(arena: std.heap.ArenaAllocator, N_threads: usize, N_tiers: usize) !Sched {
    assert(N_tiers != 0);
    assert(N_threads > 0);
    var xarena = arena;
    const alloc = xarena.allocator();

    const mpmc: []MPMC = try alloc.alloc(MPMC, N_tiers);
    const tier_thread_count: []*AtomicU32 = try alloc.alloc(*AtomicU32, N_tiers);
    const wthandle: []Thread = try alloc.alloc(Thread, N_threads);

    for (mpmc) |*j| j.* = try MPMC.init(alloc);
    for (tier_thread_count) |*j| j.* = try alloc.create(AtomicU32);
    tier_thread_count[0].* = AtomicU32.init(@intCast(N_threads)); // all threads start on tier 0
    for (tier_thread_count[1..]) |j| j.* = AtomicU32.init(0);
    for (wthandle, 0..) |*j, i| j.* = try thread.thread(alloc, try std.fmt.allocPrint(alloc, "gp task thread {}", .{i}), polling_tier_based_worker, .{
        mpmc, tier_thread_count,
    });
    return Sched{
        .mpmc = mpmc,
        .tier_list = tier_thread_count,
        .threads = wthandle,
        .free_slot = AtomicU32.init(0),
        .arena = xarena,
    };
}
pub fn init(alloc: Allocator, N_threads: usize, N_tiers: usize) !*Sched {
    var arena = std.heap.ArenaAllocator.init(alloc);
    const p = try arena.allocator().create(Sched);
    const t = try init_stack(arena, N_threads, N_tiers);
    p.* = t;
    return p;
}
pub fn deinit(self: *Sched) void {
    self.arena.deinit();
}
pub fn spinwait_for_startup(self: *Sched) !void {
    for (self.threads) |*j| j.spinwait_for_startup();
}
pub fn shutdown(self: *Sched) !void {
    for (self.threads) |*j| j.spinwait_for_startup();
    for (self.threads) |*j| j.set_stop_signal();
    for (self.threads) |*j| try j.stop_or_timeout(1e9);
}
/// tier 0 is highest prio queue
pub fn push_task(self: *Sched, slot: usize, tier: usize, task: *Task) !void {
    assert(tier < self.mpmc.len);
    try self.mpmc[tier].push(slot, task);
}
pub fn get_free_slot(self: *Sched) usize {
    const x = self.free_slot.fetchAdd(1, .acq_rel);
    return @intCast(x);
}
pub fn get_async_executor(self: *Sched, tier_index: usize, slot: usize) AsyncExecutor {
    if (tier_index >= self.mpmc.len) @panic("given tier index out of bounds for given PrioritySchedularConfig");
    return AsyncExecutor{
        .sched = self,
        .tier = tier_index,
        .slot = slot,
    };
}
pub const AsyncExecutor = struct {
    sched: *Sched,
    slot: usize,
    tier: usize,
    pub fn exe(self: AsyncExecutor, task: *Task) void {
        self.sched.push_task(
            self.slot,
            self.tier,
            task,
        ) catch unreachable;
    }
};

pub fn recast(T: type, ptr: *anyopaque) *T {
    return @as(*T, @alignCast(@ptrCast(ptr)));
}

const ExampleStruct = struct {
    const This = @This();
    age: usize = 99,
    name: []const u8,
    timer: Timer,
    pub fn say_my_name(self: *This) void {
        self.time();
        // std.log.warn("my name is {s} and my age is {}", .{ self.name, self.age });
    }
    pub fn say_my_name_lie(self: *This) void {
        self.time();
        self.age -= 10;
        // std.log.warn("my name is peter schmutzig and my age is {}", .{self.age});
    }
    pub fn say_my_name_type_erased(any_self: *anyopaque) void {
        const self = recast(This, any_self);
        self.say_my_name();
    }
    fn time(self: *This) void {
        const t = self.timer.read();
        const t_f: f64 = @floatFromInt(t);
        _ = t_f;
        // std.log.warn("elapsed: {d:.3} ms", .{t_f / 1e6});
    }

    pub fn say_my_name_lie_type_erased(any_self: *anyopaque) void {
        const self = recast(This, any_self);
        self.say_my_name_lie();
    }
};
test "prio sched init test" {
    const alloc = std.testing.allocator;
    var ps = try Sched.init(alloc, 1, 1);

    const ex_struct = try alloc.create(ExampleStruct);
    defer alloc.destroy(ex_struct);
    const ex_struct2 = try alloc.create(ExampleStruct);
    defer alloc.destroy(ex_struct2);

    var task = try Task.init(alloc);
    defer task.deinit(alloc);
    var task2 = try Task.init(alloc);
    defer task2.deinit(alloc);
    std.Thread.sleep(10e6);

    for (0..10) |i| {
        ex_struct.* = ExampleStruct{
            .age = 90,
            .name = "peter kunz",
            .timer = Timer.start() catch unreachable,
        };
        task.set(ExampleStruct, ex_struct, ExampleStruct.say_my_name_type_erased);
        ps.push_task(0, 0, task) catch {
            std.log.warn("pushing task 1 in iteration {} failed", .{i});
        };

        ex_struct2.* = ExampleStruct{
            .age = 90,
            .name = "peter kunz",
            .timer = Timer.start() catch unreachable,
        };
        // task2.set(ExampleStruct, ex_struct, ExampleStruct.say_my_name_lie_type_erased);
        // ps.push_task(0, 0, task2) catch |e| {
        //     std.log.warn("slot is occupied {}", .{e});
        // };
        task2.set(ExampleStruct, ex_struct, ExampleStruct.say_my_name_lie_type_erased);
        ps.push_task(1, 0, task2) catch {
            std.log.warn("pushing task 2 in iteration {} failed", .{i});
        };
        std.Thread.sleep(200e6);
    }

    std.Thread.sleep(20e6);

    ps.shutdown() catch unreachable;
    ps.deinit();
}

test "test all refs" {
    std.testing.refAllDecls(@This());
}
