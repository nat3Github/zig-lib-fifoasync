const std = @import("std");
const testing = std.testing;
const Atomic = std.atomic.Value;
const spsc = @import("weakrb-spsc.zig");
const delegator_mod = @import("delegator.zig");
pub const Codegen = delegator_mod.CodeGen;
pub const CodeGenConfig = delegator_mod.CodeGenConfig;

const ziggen = @import("ziggen");
pub const sleep = @import("sleep.zig");
pub const LinkedChannel = spsc.LinkedChannelWeakRB;
pub const get_bidirectional_channels = spsc.get_bidirectional_linked_channels_rb;
pub const Fifo = spsc.FifoWeakRB;
const AtomicOrder = std.builtin.AtomicOrder;

const Allocator = std.mem.Allocator;

const AtomicBool = Atomic(bool);
var heapalloc = std.heap.GeneralPurposeAllocator(.{}){};
const test_gpa = heapalloc.allocator();

const SleepNanoSeconds = u64;
/// wraps a thread that owns an instance of T and calls T repeatedly with f
/// if f returns an error this thread will stop!
/// the thread will sleep for the returned nanoseconds value
/// it can be woken up by using the reset_event field of this struct (using reset_event.set())
pub fn WakeAbleThread(comptime T: type) type {
    return struct {
        const Self = @This();
        running: *AtomicBool,
        wake_lthread: *std.Thread.ResetEvent,
        alloc: Allocator,
        pub fn init(alloc: Allocator, instance: T, f: fn (*T) anyerror!SleepNanoSeconds) !Self {
            const thr = struct {
                fn exe(instancex: T, fx: fn (*T) anyerror!SleepNanoSeconds, running: *Atomic(bool), reset: *std.Thread.ResetEvent) void {
                    running.store(true, AtomicOrder.seq_cst);
                    var t: T = instancex;
                    var action: SleepNanoSeconds = 0;
                    std.log.debug("l thread started", .{});
                    while (running.load(AtomicOrder.unordered)) {
                        reset.reset();
                        reset.timedWait(action) catch {};
                        action = fx(&t) catch |e| {
                            std.log.err("l thread will exit with error: {any}", .{e});
                            break;
                        };
                    }
                    std.log.warn("l thread has terminated\n", .{});
                }
            };
            const reset = try alloc.create(std.Thread.ResetEvent);
            reset.* = std.Thread.ResetEvent{};
            const running: *AtomicBool = try alloc.create(AtomicBool);
            running.* = AtomicBool.init(false);
            const thread = try std.Thread.spawn(.{ .allocator = alloc }, thr.exe, .{ instance, f, running, reset });
            thread.detach();
            return Self{
                .running = running,
                .wake_lthread = reset,
                .alloc = alloc,
            };
        }
    };
}
// like LThreadHandle but no control to stop other to return error
// no sleeping
pub fn BusyThread(T: type, alloc: Allocator, instance: T, f: fn (*T) anyerror!void) !void {
    const thr = struct {
        fn exe(instancex: T, fx: fn (*T) anyerror!void) void {
            var t: T = instancex;
            std.log.debug("busy thread started", .{});
            while (true) {
                fx(&t) catch |e| {
                    std.log.err("busy thread will exit with error: {any}", .{e});
                    break;
                };
            }
            std.log.warn("busy thread has terminated\n", .{});
        }
    };
    const thread = try std.Thread.spawn(.{ .allocator = alloc }, thr.exe, .{ instance, f });
    thread.detach();
}
test "simple call loop" {
    const TestingFn = struct {
        const Self = @This();
        counter: u32 = 0,
        fn f(self: *Self) anyerror!SleepNanoSeconds {
            if (self.counter == 10) {
                return error.FinishedTest;
            }
            std.debug.print("call loop: {}\n", .{self.counter});
            self.counter += 1;
            return 1 * 1_000_000;
        }
    };
    const x = TestingFn{};
    const calloop = try WakeAbleThread(TestingFn).init(test_gpa, x, TestingFn.f);
    for (0..6) |i| {
        std.time.sleep(1 * 1_000_000);
        std.debug.print("base thread: {}\n", .{i});
    }
    _ = calloop;
}

// server implementation using fifo's and condition variables + mmutexes: for non blocking realtimesafe work with blocking background threads

// server 1 (actual server)
// - has sendreceive channels (2waychannel)
// while running:
// wait on condition
// unset condition
// spin n times:
// if event handle event return result through channel

/// the Channel used by Delegator Thread, its also compatible with auto generated Delegators.
pub const DelegatorChannel = LinkedChannel;
/// A Blocking thread for auto generated Delegators.
///
/// T: instance Type
/// D: auto generated Delegator type
/// internal channel:
/// uses Messages for communication:
/// Args: the Send Type
/// Ret: the Return Type
/// capacity the internal capacity of the channel (how many functions do you call at once on a delegator? set this number accordingly)
///
/// Delegator Thread ResetEvent
///
pub fn DelegatorThread(D: type, T: type, DServerChannel: type) type {
    return struct {
        const Self = @This();
        const S = struct {
            inst: T,
            channel: DServerChannel,
            re: *std.Thread.ResetEvent,
        };
        const ThreadT = WakeAbleThread(S);

        lthread: ThreadT,
        wait_for_lthread: *std.Thread.ResetEvent,
        /// launches a background thread with the instances T
        /// the instance then can be called through an Delegator instance
        pub fn init(alloc: Allocator, instance: T, serverfifo: DServerChannel) !Self {
            const r = try alloc.create(std.Thread.ResetEvent);
            const wrapper =
                S{
                .inst = instance,
                .channel = serverfifo,
                .re = r,
            };
            const ff = struct {
                fn f(
                    self: *S,
                ) !SleepNanoSeconds {
                    // std.log.debug("\nwoke up will proces now", .{});
                    while (self.channel.receive()) |msg| {
                        const ret = D.__message_handler(&self.inst, msg);
                        try self.channel.send(ret);
                        self.re.set();
                    }
                    // sleep maximum amount
                    return std.math.maxInt(u64);
                }
            };
            const t = try ThreadT.init(alloc, wrapper, ff.f);
            std.log.debug("\nlaunched delegator thread", .{});
            return Self{ .lthread = t, .wait_for_lthread = r };
        }
    };
}

/// Handle that is used by the WakeThread
pub const RtsWakeUpHandle = struct {
    const This = @This();
    inner_handle: *AtomicBool,
    pub fn wake(self: *const This) void {
        self.inner_handle.store(true, AtomicOrder.unordered);
    }
    pub fn deinit(self: *const This, gpa: Allocator) void {
        gpa.destroy(self.inner_handle);
    }
};

/// you can register std.Thread.ResetEvent, the returned WakeUpHandle can be used to set the ResetEvent in a RealTime Safe manner
///
/// this implements a busy loops which checks all wake up handles and calls .set() on the reset Events.
/// capacity = how many handles can be handled by / added to this Struct at runtime
pub fn RtsWakeUp(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const ABoolResetEvent = struct { if_wakeup: *AtomicBool, wake_up: *std.Thread.ResetEvent };
        counter: usize = 0,
        fifo: *Fifo(ABoolResetEvent, capacity),
        cleanup_server_slots: []ABoolResetEvent,
        alloc: Allocator,
        const WakeStruct = struct {
            const wSelf = @This();
            fifo_ptr: *Fifo(ABoolResetEvent, capacity),
            counter: usize = 0,
            slots: []ABoolResetEvent,
            fn f(self: *wSelf) !void {
                if (self.fifo_ptr.pop()) |b| {
                    if (self.counter == self.slots.len) return error.RtsWakupNoSlots;
                    self.slots[self.counter] = b;
                    self.counter += 1;
                }
                for (self.slots[0..self.counter]) |*reset_event| {
                    if (reset_event.if_wakeup.load(AtomicOrder.acquire)) {
                        reset_event.if_wakeup.store(false, AtomicOrder.release);
                        reset_event.wake_up.set();
                    }
                }
            }
        };
        // poll interval specifies how long the thread sleeps after it checked all wakeup slots
        pub fn init(alloc: Allocator) !Self {
            const server_slots = try alloc.alloc(Self.ABoolResetEvent, capacity);
            const fifo = try Fifo(ABoolResetEvent, capacity).init_on_heap(alloc);
            const wakestruct = WakeStruct{
                .fifo_ptr = fifo,
                .slots = server_slots,
            };
            try BusyThread(WakeStruct, alloc, wakestruct, WakeStruct.f);
            return Self{
                .fifo = fifo,
                .alloc = alloc,
                .cleanup_server_slots = server_slots,
            };
        }
        /// returns a WakeUpHandle. you are responsible to deinit it
        pub fn register(self: *Self, gpa: Allocator, wakeup_handle: *std.Thread.ResetEvent) !RtsWakeUpHandle {
            if (self.counter == capacity) return error.AllWakeUpSlotsAreOccupied;
            const atb_ptr = try gpa.create(AtomicBool);
            atb_ptr.* = AtomicBool.init(false);
            const rsevent = ABoolResetEvent{ .if_wakeup = atb_ptr, .wake_up = wakeup_handle };
            try self.fifo.push(rsevent);
            self.counter += 1;
            return RtsWakeUpHandle{ .inner_handle = atb_ptr };
        }
    };
}
pub const DelegatorServerConfig = struct {
    const This = @This();
    max_num_delegators: usize = 16,
    internal_channel_buffersize: usize = 16,
    D: fn (type, type, type) type,
    Args: type,
    Ret: type,
    pub fn init(import: anytype) This {
        return This{
            .Args = @field(import, delegator_mod.RESERVED_ARGS),
            .Ret = @field(import, delegator_mod.RESERVED_RET),
            .D = @field(import, delegator_mod.RESERVED_NAME),
        };
    }
    pub fn init_ex(import: anytype, delegator_cap: usize, channel_msg_cap: usize) This {
        return This{
            .Args = @field(import, delegator_mod.RESERVED_ARGS),
            .Ret = @field(import, delegator_mod.RESERVED_RET),
            .D = @field(import, delegator_mod.RESERVED_NAME),
            .max_num_delegators = delegator_cap,
            .internal_channel_buffersize = channel_msg_cap,
        };
    }
};
/// Real time safe Server for use with auto generated Delegator
/// setup your build.zig to autogenerate an Delegator for the struct you want to use asynchronously (look at example.zig and devtools.zig)
///
/// this uses 1 polling server which checks all wake handles and wakes up the respective threads
/// this uses up to max_num_delegators backround threads that wait to be woken up (through the Delegator)
///
/// max_num_delegators = how often you can call register_delegator
///
///
/// note: does not free allocated memory
/// has a constant bound of needed memory (wont allocate indefinitely)
pub fn RtsDelegatorServer(config: DelegatorServerConfig) type {
    const Args = config.Args;
    const Ret = config.Ret;
    const CHANNEL_CAP = config.internal_channel_buffersize;
    const INSTANCE_CAP = config.max_num_delegators;
    const T_DChannel = LinkedChannel(Args, Ret, CHANNEL_CAP);
    const T_DServerChannel = LinkedChannel(Ret, Args, CHANNEL_CAP);
    const T_WakeupHandle = RtsWakeUpHandle;
    const T_Delegator = config.D(T_DChannel, T_WakeupHandle, *std.Thread.ResetEvent);
    const T = T_Delegator.Type;
    const T_Wthread = RtsWakeUp(INSTANCE_CAP);
    const T_DThread = DelegatorThread(T_Delegator, T, T_DServerChannel);
    return struct {
        const This = @This();
        _dcount: usize = 0,
        _alloc: Allocator,
        wakeup_thread: T_Wthread,
        delegator_threads: [INSTANCE_CAP]T_DThread = undefined,
        pub fn init(alloc: Allocator) !This {
            const wkt = try T_Wthread.init(alloc);
            return This{
                .wakeup_thread = wkt,
                ._alloc = alloc,
            };
        }
        // will consume an instance of T and return an Delegator (the autogenerated Delegator)
        pub fn register_delegator(self: *This, inst: T) !T_Delegator {
            if (self._dcount == INSTANCE_CAP) return error.DelegatorServerLimitIsFull;
            const bichannel = try get_bidirectional_channels(self._alloc, Args, Ret, CHANNEL_CAP);
            const basefifo = bichannel[0];
            const serverfifo = bichannel[1];
            const dthread = try T_DThread.init(self._alloc, inst, serverfifo);
            self.delegator_threads[self._dcount] = dthread;
            self._dcount += 1;
            const wh = try self.wakeup_thread.register(self._alloc, dthread.lthread.wake_lthread);
            const del = T_Delegator{
                .channel = basefifo,
                .wakeup_handle = wh,
                .wait_handle = dthread.wait_for_lthread,
            };
            return del;
        }
    };
}
/// Handle that is used by the WakeThread
pub const BlockingWakeUpHandle = struct {
    const This = @This();
    inner_handle: *std.Thread.ResetEvent,
    pub fn wake(self: *const This) void {
        self.inner_handle.set();
    }
    pub fn deinit(self: *const This, gpa: Allocator) void {
        gpa.destroy(self.inner_handle);
    }
};
pub fn BlockingDelegatorServer(config: DelegatorServerConfig) type {
    const Args = config.Args;
    const Ret = config.Ret;
    const CHANNEL_CAP = config.internal_channel_buffersize;
    const INSTANCE_CAP = config.max_num_delegators;
    const T_DChannel = LinkedChannel(Args, Ret, CHANNEL_CAP);
    const T_DServerChannel = LinkedChannel(Ret, Args, CHANNEL_CAP);
    const T_WakeupHandle = BlockingWakeUpHandle;
    const T_Delegator = config.D(T_DChannel, T_WakeupHandle);
    const T = T_Delegator.Type;
    const T_DThread = DelegatorThread(T_Delegator, T, T_DServerChannel);
    return struct {
        const This = @This();
        _dcount: usize = 0,
        _alloc: Allocator,
        delegator_threads: [INSTANCE_CAP]T_DThread = undefined,
        pub fn init(alloc: Allocator) !This {
            return This{
                ._alloc = alloc,
            };
        }
        // will consume an instance of T and return an Delegator (the autogenerated Delegator)
        pub fn register_delegator(self: *This, inst: T) !T_Delegator {
            if (self._dcount == INSTANCE_CAP) return error.DelegatorServerLimitIsFull;
            const bichannel = try get_bidirectional_channels(self._alloc, Args, Ret, CHANNEL_CAP);
            const basefifo = bichannel[0];
            const serverfifo = bichannel[1];
            const dthread = try T_DThread.init(self._alloc, inst, serverfifo);
            const re = dthread.lthread.wake_lthread;
            self.delegator_threads[self._dcount] = dthread;
            self._dcount += 1;
            const wh = BlockingWakeUpHandle{ .inner_handle = re };
            const del = T_Delegator{
                .channel = basefifo,
                .wakeup_handle = wh,
            };
            return del;
        }
    };
}

const builtin = @import("builtin");
const os_tag = builtin.target.os.tag;

fn sub_or_zero(a: u64, b: u64) u64 {
    return a - @min(a, b);
}
pub const SEC = 1000 * MILLI;
pub const MILLI = 1000 * MICRO;
pub const MICRO = 1_000;
/// use this with buffer sizes that have more leeway (big buffers) -> less spinning, more efficient!
/// use this with tight buffer sizes and rather poll on next event
const RtSleep = struct {
    const This = @This();
    /// i.e. windows sleep cant sleep shorter than 1 ms
    lower_bound: u64,
    /// assumed that
    pos_max_derivation: u64,
    neg_max_derivation: u64,

    fn sleep(nano_seconds: u64) void {
        if (nano_seconds > MILLI) {
            switch (os_tag) {
                .linux, .macos => {
                    // linux sleep is to be assumed correct for sub milliseconds;
                    // i have read that sometime it sleeps longer that that, must test that!
                    std.Thread.sleep(nano_seconds);
                },
                .windows => {
                    // windows clock cant sleep shorter than 1 ms spin-wait
                    const ms = nano_seconds / MILLI;
                    std.Thread(ms);
                },
                else => @compileError("OS is not Supported"),
            }
        } else {
            switch (os_tag) {
                .linux => {
                    // linux sleep is to be assumed correct for sub milliseconds;
                    // i have read that sometime it sleeps longer that that, must test that!
                    const sleep_alt = sub_or_zero(nano_seconds, 500 * MICRO);
                    if (sleep_alt > 0) {
                        std.Thread.sleep(nano_seconds);
                    }
                },
                .windows => {
                    // windows clock cant sleep shorter than 1 ms spin-wait
                    const ms = nano_seconds / MILLI;
                    // const rem = nano_seconds - ms * MILLI;
                    if (ms > 0) {
                        std.Thread(ms);
                    }
                },
                .macos => {
                    // no idea have to test is assumed to be like linux
                    std.Thread.sleep(nano_seconds);
                },
                else => @compileError("OS is not Supported"),
            }
        }
    }
};

// times the sleep function at runtime
const RtsSleepOptimizer = struct {
    const This = @This();
    result: RtSleep,
    /// uses the default timings for the os
    pub fn init_os_default_timings() This {
        const rts = switch (os_tag) {
            .linux => RtSleep{
                .lower_bound = 0,
                .pos_max_derivation = 0,
                .neg_max_derivation = 0,
            },
            .windows => RtSleep{
                .lower_bound = 0,
                .pos_max_derivation = 0,
                .neg_max_derivation = 0,
            },
            else => @compileError("unsupported OS"),
        };
        return This{
            .result = rts,
        };
    }
    /// performs timing measurements of the system
    const PASSES = 128;
    pub fn init_measure_timings_on_local_thread() !This {
        var t = try Timer.start();
        var timings = std.mem.zeroes([PASSES]u64);
        const interval = 1 * MILLI;
        for (0..PASSES) |i| {
            t.reset();
            std.Thread.sleep(interval);
            timings[i] = t.read();
        }
        const test_lower_bound: []const u64 = &.{ 2000, 1000, 500, 250, 100, 50, 5 };
        var lb = test_lower_bound[0] * MILLI;
        for (test_lower_bound) |tlb| {
            const tt = tlb * MICRO;
            lb = tt;
            t.reset();
            std.Thread.sleep(tt);
            const tx = t.read();
            if (tx < (tt * 3) / 4) {
                break;
            }
        }
        const stat = get_pos_max(timings[0..], interval);
        return This{
            .result = RtSleep{
                .lower_bound = lb,
                .pos_max_derivation = stat[0],
                .neg_max_derivation = stat[1],
            },
        };
    }
    fn get_pos_max(dat: []u64, cmp: u64) [2]u64 {
        var pos: u64 = 0;
        var neg: u64 = 0;
        var avg: f64 = 0;
        for (dat) |x| {
            const sp = sub_or_zero(x, cmp);
            const sn = sub_or_zero(cmp, x);
            pos = @max(sp, pos);
            neg = @max(sn, pos);
            const abs = @max(sp, sn);
            avg += @as(f64, @floatFromInt(abs)) / @as(f64, @floatFromInt(dat.len));
        }

        const fmt =
            \\
            \\ stats:
            \\ avg derivation = {d:.3}
            \\
        ;

        std.debug.print(fmt, .{avg / MILLI});
        return .{ pos, neg };
    }
    pub fn create_rt_sleep(self: *const This) RtSleep {
        return self.result;
    }
};

test "test sleeping" {
    std.testing.refAllDecls(@This());
    const rtso = RtsSleepOptimizer.init_measure_timings_on_local_thread() catch unreachable;
    const rst = rtso.create_rt_sleep();
    const fmt =
        \\
        \\RtSleep measurements:
        \\ lower bound : {}
        \\ max derivation negative: {}
        \\ max derivation positive: {}
        \\
    ;
    std.debug.print(fmt, .{
        rst.lower_bound,
        rst.neg_max_derivation,
        rst.pos_max_derivation,
    });
}

/// NOTE:
/// sleeping on windows is absolutlely no serious thing to consider
/// as ist is for now it is in fact not usable at all for timed thread synchronization
/// did not test on linux but with this mess in windows we have to find a better way than just infinetly polling on all threads:
/// NOTE: proposal:
/// schedule waking a thread with sub ms accuracy:
/// use busy thread that wakes up sleeping threads
const ScheduleWakeConfig = struct {
    /// how many wake handles are processed
    slots: usize = 1024,
};
const ResetEvent = std.Thread.ResetEvent;
const Timer = std.time.Timer;
const AtomicScheduleTime = Atomic(ScheduleTime);
const ScheduleTime = struct {
    time_nano: ?u64 = null,
    timer: Timer = undefined,
};
const ScheduleWakeHandle = struct {
    re: *ResetEvent,
    att: *AtomicScheduleTime,
};

/// this is an improvement over just waking the thread through a busy polling thread
/// this has the advantage of waking before time so a Background Thread can be woken up before
/// it receives a task so it can poll on the task till its available
/// this should be lower latency
pub fn ScheduleWake(cfg: ScheduleWakeConfig) type {
    return struct {
        const This = @This();
        const T_Lthread = WakeAbleThread(T);
        thread: T_Lthread,
        const T = struct {
            handles: [cfg.slots]ScheduleWakeHandle,
            compensation: u64 = 0,
            local_timer: Timer = null,
            fn f(self: *T) !u64 {
                if (self.local_timer == null) self.local_timer = Timer.start() catch unreachable;
                for (self.handles) |h| {
                    const x = h.att.load(.unordered);
                    if (x.time_nano) |t| {
                        if (x.timer.read() >= t) h.re.set();
                    }
                }
                const time_to_turn = self.local_timer.lap();
                self.compensation = (time_to_turn + self.compensation) / 2;
                return 0;
            }
        };
        pub fn init(alloc: Allocator, hndles: [cfg.slots]ScheduleWakeHandle) !This {
            const ins = T{ .handles = hndles };
            const t = try T_Lthread.init(alloc, ins, T.f);
            return This{ .thread = t };
        }
    };
}
test "test all refs" {
    std.testing.refAllDeclsRecursive(@This());
}
