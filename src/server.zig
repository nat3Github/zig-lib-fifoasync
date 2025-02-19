const std = @import("std");
const testing = std.testing;
const Atomic = std.atomic.Value;
const spsc = @import("weakrb-spsc.zig");
const delegator_mod = @import("delegator.zig");
pub const Codegen = delegator_mod.CodeGen;
pub const CodeGenConfig = delegator_mod.CodeGenConfig;
pub const ziggen = @import("ziggen");
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
pub fn LThreadHandle(comptime T: type) type {
    return struct {
        const Self = @This();
        running: *AtomicBool,
        reset_event: *std.Thread.ResetEvent,
        alloc: Allocator,
        pub fn get_reset_event(self: *const Self) *std.Thread.ResetEvent {
            return self.reset_event;
        }
        pub fn init(alloc: Allocator, instance: T, f: fn (*T) anyerror!SleepNanoSeconds) !Self {
            const thr = struct {
                fn exe(instancex: T, fx: fn (*T) anyerror!SleepNanoSeconds, running: *Atomic(bool), reset: *std.Thread.ResetEvent) void {
                    running.store(true, AtomicOrder.seq_cst);
                    var t: T = instancex;
                    var action: SleepNanoSeconds = 0;
                    std.log.debug("call loop started", .{});
                    while (running.load(AtomicOrder.unordered)) {
                        reset.reset();
                        std.log.debug("call loop will go to sleep", .{});
                        reset.timedWait(action) catch {};
                        std.log.debug("call loop woke up", .{});
                    }
                    action = fx(&t) catch |e| {
                        std.log.err("thread will exit with error: {any}", .{e});
                        return;
                    };
                    std.log.warn("call loop has exited\n", .{});
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
                .reset_event = reset,
                .alloc = alloc,
            };
        }
    };
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
    const calloop = try LThreadHandle(TestingFn).init(test_gpa, x, TestingFn.f);
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
/// internal channel:
/// uses Messages for communication:
/// Args: the Send Type
/// Ret: the Return Type
/// capacity the internal capacity of the channel (how many functions do you call at once on a delegator? set this number accordingly)
///
pub fn DelegatorThread(D: type, T: type, DServerChannel: type) type {
    return struct {
        const Self = @This();
        const ThreadT = LThreadHandle(S);
        thread: ThreadT,
        const S = struct {
            inst: T,
            channel: DServerChannel,
        };
        /// launches a background thread with the instances T
        /// the instance then can be called through an Delegator instance
        pub fn init(alloc: Allocator, instance: T, serverfifo: DServerChannel) !Self {
            const wrapper = S{ .inst = instance, .channel = serverfifo };
            const ff = struct {
                fn f(
                    self: *S,
                ) !SleepNanoSeconds {
                    while (self.channel.receive()) |msg| {
                        const ret = D.__message_handler(&self.inst, msg);
                        try self.channel.send(ret);
                    }
                    // sleep maximum amount
                    return std.math.maxInt(u64);
                }
            };
            return Self{
                .thread = try ThreadT.init(alloc, wrapper, ff.f),
            };
        }
        /// returns a ResetEvent which wakes up the Delegator Thread when its sleeping
        /// waking is not considered realtime safe
        /// (use WakeUpThread for that)
        pub fn get_wake_handle(self: *const Self) *std.Thread.ResetEvent {
            return self.thread.reset_event;
        }
        pub fn wake_up_blocking(self: *Self) void {
            self.get_wake_handle().set();
        }
        pub fn deinit(self: *Self) void {
            self.fifo.deinit();
            self.thread.deinit();
        }
    };
}

/// Handle that is used by the WakeThread
pub const WakeUpHandle = struct {
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
        thread: LThreadHandle(WakeStruct),
        fifo: *Fifo(ABoolResetEvent, capacity),
        cleanup_server_slots: []ABoolResetEvent,
        alloc: Allocator,

        const WakeStruct = struct {
            const wSelf = @This();
            fifo_ptr: *Fifo(ABoolResetEvent, capacity),
            counter: usize = 0,
            slots: []ABoolResetEvent,
            timer_ns: u64,
            fn f(self: *wSelf) !SleepNanoSeconds {
                while (self.fifo_ptr.pop()) |b| {
                    self.slots[self.counter] = b;
                    self.counter += 1;
                }
                for (self.slots[0..self.counter]) |*reset_event| {
                    if (reset_event.if_wakeup.load(AtomicOrder.acquire)) {
                        reset_event.if_wakeup.store(false, AtomicOrder.release);
                        reset_event.wake_up.set();
                    }
                }
                return self.timer_ns;
            }
        };
        // poll interval specifies how long the thread sleeps after it checked all wakeup slots
        pub fn init(alloc: Allocator, poll_interval_ns: u64) !Self {
            const server_slots = try alloc.alloc(Self.ABoolResetEvent, capacity);
            errdefer alloc.free(server_slots);
            var fifo = try Fifo(ABoolResetEvent, capacity).init_on_heap(alloc);
            errdefer fifo.deinit();
            const wakestruct = WakeStruct{
                .fifo_ptr = fifo,
                .slots = server_slots,
                .timer_ns = poll_interval_ns,
            };
            const thread = try LThreadHandle(WakeStruct).init(alloc, wakestruct, WakeStruct.f);
            errdefer thread.deinit();
            return Self{
                .thread = thread,
                .fifo = fifo,
                .alloc = alloc,
                .cleanup_server_slots = server_slots,
            };
        }
        pub fn deinit(self: *Self) void {
            self.thread.deinit();
            self.fifo.deinit();
            const fifo_ptr: *Fifo(ABoolResetEvent, capacity) = self.fifo;
            self.alloc.destroy(fifo_ptr);
            self.alloc.free(self.cleanup_server_slots);
        }
        /// returns a WakeUpHandle. you are responsible to deinit it
        pub fn register(self: *Self, gpa: Allocator, wakeup_handle: *std.Thread.ResetEvent) !WakeUpHandle {
            if (self.counter == capacity) {
                return error.AllWakeUpSlotsAreOccupied;
            }
            const atb_ptr = try gpa.create(AtomicBool);
            atb_ptr.* = AtomicBool.init(false);
            const rsevent = ABoolResetEvent{ .if_wakeup = atb_ptr, .wake_up = wakeup_handle };
            try self.fifo.push(rsevent);
            self.counter += 1;
            return WakeUpHandle{ .inner_handle = atb_ptr };
        }
    };
}
pub const RtsDelegatorServerConfig = struct {
    const This = @This();
    max_num_delegators: usize = 16,
    internal_channel_buffersize: usize = 16,
    D: fn (type, type) type,
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
/// Real time safe Server for use with an auto generated Delegator
/// setup your build.zig to autogenerate an Delegator for the struct you want to use asynchronously (look at example.zig and devtools.zig)
///
/// this uses 1 polling server which checks all wake handles and wakes up the respective threads
///
/// max_num_delegators = how often you can call register_delegator
///
/// note: does not free allocated memory
/// has a constant bound of needed memory (wont allocate indefinitely)
pub fn RtsDelegatorServer(config: RtsDelegatorServerConfig) type {
    const Args = config.Args;
    const Ret = config.Ret;
    const CHANNEL_CAP = config.internal_channel_buffersize;
    const INSTANCE_CAP = config.max_num_delegators;
    const T_DChannel = LinkedChannel(Args, Ret, CHANNEL_CAP);
    const T_DServerChannel = LinkedChannel(Ret, Args, CHANNEL_CAP);
    const T_WakeupHandle = WakeUpHandle;
    const T_Delegator = config.D(T_DChannel, T_WakeupHandle);
    const T = T_Delegator.Type;
    const T_Wthread = RtsWakeUp(INSTANCE_CAP);
    const T_DThread = DelegatorThread(T_Delegator, T, T_DServerChannel);
    return struct {
        const This = @This();
        _dcount: usize = 0,
        _alloc: Allocator,
        wakeup_thread: T_Wthread,
        delegator_threads: [INSTANCE_CAP]T_DThread = undefined,
        pub fn init(alloc: Allocator, poll_interval_ns: u64) !This {
            const wkt = try T_Wthread.init(alloc, poll_interval_ns);
            return This{
                .wakeup_thread = wkt,
                ._alloc = alloc,
            };
        }
        // will consume an instance of T and return an Delegator (the autogenerated Delegator)
        pub fn register_delegator(self: *This, inst: T) !T_Delegator {
            if (self._dcount == INSTANCE_CAP) {
                return error.CantRegisterDelegatorLimitIsFull;
            }
            const bichannel = try get_bidirectional_channels(self._alloc, Args, Ret, CHANNEL_CAP);
            const basefifo = bichannel[0];
            const serverfifo = bichannel[1];
            const dthread = try T_DThread.init(self._alloc, inst, serverfifo);
            const re = dthread.get_wake_handle();
            self.delegator_threads[self._dcount] = dthread;
            self._dcount += 1;
            const wh = try self.wakeup_thread.register(self._alloc, re);
            const del = T_Delegator{
                .channel = basefifo,
                .wakeup_handle = wh,
            };
            return del;
        }
    };
}

test "test all refs" {
    std.testing.refAllDeclsRecursive(@This());
}
