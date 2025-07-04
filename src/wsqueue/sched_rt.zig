/// polling schedular using high priority threads
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

const Atomic = std.atomic.Value;
const AtomicOrder = std.builtin.AtomicOrder;
const AtomicU8 = Atomic(u8);
const AtomicU32 = Atomic(u32);
const ResetEvent = std.Thread.ResetEvent;

const fifoasync = @import("fifoasync");
const lib_mpmc = @import("mpmc");

const MPMC = lib_mpmc.MPMC_SQC(.{ .order = 16, .slot_count = 16384, .T = Task });

const default_start_fn = thread.prio.set_realtime_critical_highest;
pub const Config = struct {
    alloc: Allocator,
    N_threads: usize,
    N_tiers: usize,
    startup_fn: *const fn () anyerror!void = default_start_fn,
};

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
    start_up_fn: anytype,
) !void {
    // TODO: yield when no task available
    try start_up_fn();
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

pub fn init_stack(arena: std.heap.ArenaAllocator, cfg: Config) !Sched {
    assert(cfg.N_tiers != 0);
    assert(cfg.N_threads > 0);
    var xarena = arena;
    const alloc = xarena.allocator();

    const mpmc: []MPMC = try alloc.alloc(MPMC, cfg.N_tiers);
    const tier_thread_count: []*AtomicU32 = try alloc.alloc(*AtomicU32, cfg.N_tiers);
    const wthandle: []Thread = try alloc.alloc(Thread, cfg.N_threads);

    for (mpmc) |*j| j.* = try MPMC.init(alloc);
    for (tier_thread_count) |*j| j.* = try alloc.create(AtomicU32);
    tier_thread_count[0].* = AtomicU32.init(@intCast(cfg.N_threads)); // all threads start on tier 0
    for (tier_thread_count[1..]) |j| j.* = AtomicU32.init(0);
    for (wthandle, 0..) |*j, i| j.* = try thread.thread(alloc, try std.fmt.allocPrint(alloc, "gp task thread {}", .{i}), polling_tier_based_worker, .{
        mpmc, tier_thread_count, cfg.startup_fn,
    });
    return Sched{
        .mpmc = mpmc,
        .tier_list = tier_thread_count,
        .threads = wthandle,
        .free_slot = AtomicU32.init(0),
        .arena = xarena,
    };
}
/// startup fn will be run on each thread for setting thread priority
pub fn init(cfg: Config) !*Sched {
    var arena = std.heap.ArenaAllocator.init(cfg.alloc);
    const p = try arena.allocator().create(Sched);
    const t = try init_stack(arena, cfg);
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
