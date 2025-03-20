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
/// TODO: define how a Task looks like
///
const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("../lib.zig");
const WThread = root.threads.wthread.WThread;
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

const PrioritySchedularConfig = struct {
    order: usize = 16,
    slot_count: usize = 2048,
    tier_count: usize = 3,
    thread_count: usize = 8,
};
/// Generic type erased Task
/// if arguments ore return values are needed they must be somehow stored in the instance
pub const Task = struct {
    const This = @This();
    instance: ?*anyopaque = null,
    task: ?*const fn (*anyopaque) void = null,

    pub fn init(alloc: Allocator) !*This {
        const t = try alloc.create(This);
        t.* = Task{};
        return t;
    }
    pub fn deinit(self: *This, alloc: Allocator) void {
        alloc.destroy(self);
    }
    /// the t_fn must re-cast the *anyopaque pointer to *T
    pub fn set(self: *This, T: type, t_ptr: *T, t_fn: *const fn (*anyopaque) void) void {
        const cast: *anyopaque = @ptrCast(t_ptr);
        self.instance = cast;
        self.task = t_fn;
    }
    fn call(self: *This) void {
        if (self.instance) |inst| {
            @call(.auto, self.task.?, .{inst});
        }
    }
};

/// NOTE improvements for later: how does one realize begin date and due date?
///  -> planning of tasks
///  -> do tasks dependent on there due date
///
///
pub fn PrioritySchedular(cfg: PrioritySchedularConfig) type {
    const N_threads: usize = cfg.thread_count;
    const N_tiers: usize = cfg.tier_count;
    if (N_threads >= std.math.maxInt(u32)) @compileError("way to many threads");
    if (N_threads == 0 or N_tiers == 0 or N_tiers > 100) @compileError("wrong config values");
    return struct {
        const This = @This();
        const MPMC = lib_mpmc.MPMC_SQC(.{ .order = cfg.order, .slot_count = cfg.slot_count, .T = Task });
        const TWthread = WThread(.{ .debug_name = "prio sched", .T_stack_type = TaskThread });
        const TaskThread = struct {
            mpmc: [N_tiers]MPMC,
            tier_list: [N_tiers]*AtomicU32,
            tier: usize = 0,
            fn f(Self: TaskThread, thread: TWthread.ArgumentType) !void {
                var self = @constCast(&Self);
                var t = try Timer.start();
                while (true) {
                    t.reset();
                    var queue = self.mpmc[self.tier];
                    const popped = queue.pop();
                    if (popped) |task| {
                        task.call();
                        self.switch_to_tier(0);
                    } else {
                        if (self.tier + 1 == N_tiers) {
                            self.switch_to_tier(0);
                        } else {
                            self.switch_to_tier(self.tier + 1);
                        }
                    }
                    if (!thread.should_run()) break;
                }
            }
            fn switch_to_tier(self: *TaskThread, tier: usize) void {
                assert(tier >= 0 and tier < N_tiers);
                if (self.tier == tier) return;
                _ = self.tier_list[self.tier].fetchSub(1, .acq_rel);
                self.tier = tier;
                _ = self.tier_list[self.tier].fetchAdd(1, .acq_rel);
            }
        };
        tier_list: [N_tiers]*AtomicU32,
        wthandle: [N_threads]TWthread.InitReturnType,
        mpmc: [N_tiers]MPMC,

        pub fn init(alloc: Allocator) !This {
            var mpmc: [N_tiers]MPMC = undefined;
            for (&mpmc) |*j| j.* = try MPMC.init(alloc);
            var tier_list: [N_tiers]*AtomicU32 = undefined;
            for (&tier_list) |*j| j.* = try alloc.create(AtomicU32);
            tier_list[0].* = AtomicU32.init(N_threads); // all threads start on tier 0
            for (tier_list[1..]) |j| j.* = AtomicU32.init(0);
            var wthandle: [N_threads]TWthread.InitReturnType = undefined;
            for (&wthandle) |*j| j.* = try TWthread.init(alloc, TaskThread{
                .mpmc = mpmc,
                .tier_list = tier_list,
            }, TaskThread.f);
            return This{
                .mpmc = mpmc,
                .tier_list = tier_list,
                .wthandle = wthandle,
            };
        }
        pub fn shutdown(self: *This) !void {
            for (&self.wthandle) |*j| j.spinwait_for_startup();
            for (&self.wthandle) |*j| j.set_stop_signal();
            for (&self.wthandle) |*j| try j.stop_or_timeout(1e9);
        }
        pub fn deinit(self: *This, alloc: Allocator) void {
            for (&self.mpmc) |*j| j.deinit(alloc);
            for (&self.tier_list) |j| alloc.destroy(j);
            for (&self.wthandle) |*j| j.deinit(alloc);
        }
        /// tier 0 is highest prio queue
        pub fn push_task(self: *This, slot: usize, tier: usize, task: *Task) !void {
            assert(tier < self.mpmc.len);
            try self.mpmc[tier].push(slot, task);
        }
    };
}
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
        std.log.warn("my name is {s} and my age is {}", .{ self.name, self.age });
    }
    pub fn say_my_name_lie(self: *This) void {
        self.time();
        self.age -= 10;
        std.log.warn("my name is peter schmutzig and my age is {}", .{self.age});
    }
    pub fn say_my_name_type_erased(any_self: *anyopaque) void {
        const self = recast(This, any_self);
        self.say_my_name();
    }
    fn time(self: *This) void {
        const t = self.timer.read();
        const t_f: f64 = @floatFromInt(t);
        std.log.warn("elapsed: {d:.3} ms", .{t_f / 1e6});
    }

    pub fn say_my_name_lie_type_erased(any_self: *anyopaque) void {
        const self = recast(This, any_self);
        self.say_my_name_lie();
    }
};
const PrioSched = PrioritySchedular(.{
    .order = 16,
    .slot_count = 2048,
    .thread_count = 8,
    .tier_count = 1,
});
test "prio sched init test" {
    const alloc = std.testing.allocator;
    // var ps = try PrioSched.init(alloc);
    std.log.warn("size of PrioritySchedular:{}", .{@sizeOf(PrioritySchedular(.{
        .order = 16,
        .slot_count = 2048,
        .thread_count = 8,
        .tier_count = 3,
    }))});

    const ex_struct = try alloc.create(ExampleStruct);
    defer alloc.destroy(ex_struct);
    const ex_struct2 = try alloc.create(ExampleStruct);
    defer alloc.destroy(ex_struct2);

    var task = try Task.init(alloc);
    defer task.deinit(alloc);
    var task2 = try Task.init(alloc);
    defer task2.deinit(alloc);
    // std.Thread.sleep(10e6);

    // for (0..10) |i| {
    //     ex_struct.* = ExampleStruct{
    //         .age = 90,
    //         .name = "peter kunz",
    //         .timer = Timer.start() catch unreachable,
    //     };
    //     task.set(ExampleStruct, ex_struct, ExampleStruct.say_my_name_type_erased);
    //     ps.push_task(0, 0, task) catch {
    //         std.log.warn("pushing task 1 in iteration {} failed", .{i});
    //     };

    //     ex_struct2.* = ExampleStruct{
    //         .age = 90,
    //         .name = "peter kunz",
    //         .timer = Timer.start() catch unreachable,
    //     };
    //     // task2.set(ExampleStruct, ex_struct, ExampleStruct.say_my_name_lie_type_erased);
    //     // ps.push_task(0, 0, task2) catch |e| {
    //     //     std.log.warn("slot is occupied {}", .{e});
    //     // };
    //     task2.set(ExampleStruct, ex_struct, ExampleStruct.say_my_name_lie_type_erased);
    //     ps.push_task(1, 0, task2) catch {
    //         std.log.warn("pushing task 2 in iteration {} failed", .{i});
    //     };
    //     std.Thread.sleep(200e6);
    // }

    // std.Thread.sleep(20e6);

    // ps.shutdown() catch unreachable;
    // ps.deinit(alloc);
}
