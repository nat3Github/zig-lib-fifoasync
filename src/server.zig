const std = @import("std");
const testing = std.testing;
const Atomic = std.atomic.Value;
const spsc = @import("weakrb-spsc.zig");
pub const codegen = @import("delegator.zig");
pub const ziggen = @import("ziggen");
pub const LinkedChannel = spsc.LinkedChannelWeakRB;
pub const get_bidirectional_channels = spsc.get_bidirectional_linked_channels_rb;
pub const Fifo = spsc.FifoWeakRB;
const AtomicOrder = std.builtin.AtomicOrder;
const Allocator = std.mem.Allocator;

const AtomicBool = Atomic(bool);
var heapalloc = std.heap.GeneralPurposeAllocator(.{}){};
const test_gpa = heapalloc.allocator();

pub const ThreadAction = enum {
    SleepInterval,
    WaitOrTimeOut,
};
pub const ThreadTimeOutNanoSecs = union(ThreadAction) {
    SleepInterval: u64,
    WaitOrTimeOut: u64,
};

pub fn CallLoop(comptime T: type) type {
    return struct {
        const Self = @This();
        running: Atomic(bool),
        reset: *std.Thread.ResetEvent,
        /// return of f determines if thread will sleep for the returned interval before the next call to f
        /// or sleep till it's woken up through the condvar
        /// if error is returned from f the thread terminates
        pub fn init(alloc: Allocator, instance: T, f: fn (*T) anyerror!ThreadTimeOutNanoSecs) !Self {
            const thr = struct {
                fn exe(instancex: T, fx: fn (*T) anyerror!ThreadTimeOutNanoSecs, running: *Atomic(bool), reset: *std.Thread.ResetEvent) void {
                    running.store(true, AtomicOrder.seq_cst);
                    var t: T = instancex;
                    var action = ThreadTimeOutNanoSecs{ .SleepInterval = 0 * 1_000_000 };
                    std.log.debug("call loop started", .{});
                    while (running.load(AtomicOrder.unordered)) {
                        switch (action) {
                            .SleepInterval => |sleep_ns| {
                                std.time.sleep(sleep_ns);
                            },
                            .WaitOrTimeOut => |timeout_ns| {
                                reset.reset();
                                std.log.debug("call loop will go to sleep", .{});
                                reset.timedWait(timeout_ns) catch |e| {
                                    std.log.debug("wait timed out {any}", .{e});
                                };
                                std.log.debug("call loop woke up", .{});
                            },
                        }
                        action = fx(&t) catch |e| {
                            std.log.err("thread will exit with error: {any}", .{e});
                            return;
                        };
                    }
                    std.log.warn("call loop has exited\n", .{});
                }
            };
            const reset = try alloc.create(std.Thread.ResetEvent);
            reset.* = std.Thread.ResetEvent{};
            var running: AtomicBool = AtomicBool.init(false);
            const thread = try std.Thread.spawn(.{ .allocator = alloc }, thr.exe, .{ instance, f, &running, reset });
            thread.detach();
            return Self{
                .running = running,
                .reset = reset,
            };
        }
        pub fn deinit(
            self: *Self,
        ) void {
            self.running.store(false, std.builtin.AtomicOrder.unordered);
        }
    };
}
test "simple call loop" {
    const TestingFn = struct {
        const Self = @This();
        counter: u32 = 0,
        fn f(self: *Self) anyerror!ThreadTimeOutNanoSecs {
            if (self.counter == 10) {
                return error.FinishedTest;
            }
            std.debug.print("call loop: {}\n", .{self.counter});
            self.counter += 1;
            return ThreadTimeOutNanoSecs{ .SleepInterval = 1 * 1_000_000 };
        }
    };
    const x = TestingFn{};
    var calloop = try CallLoop(TestingFn).init(test_gpa, x, TestingFn.f);
    for (0..6) |i| {
        std.time.sleep(1 * 1_000_000);
        std.debug.print("base thread: {}\n", .{i});
    }
    calloop.deinit();
}

// server implementation using fifo's and condition variables + mmutexes: for non blocking realtimesafe work with blocking background threads

// server 1 (actual server)
// - has sendreceive channels (2waychannel)
// while running:
// wait on condition
// unset condition
// spin n times:
// if event handle event return result through channel

const ChannelWrapper = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        alloc: *const fn (
            self: *anyopaque,
        ) ?[*]u8,
    };
};

/// the Channel used by Delegator Thread, its also compatible with auto generated Delegators.
pub const DelegatorChannel = LinkedChannel;
/// A Blocking thread for auto generated Delegators.
pub fn DelegatorThread(comptime D: type, comptime Args: type, comptime Ret: type, comptime capacity: comptime_int) type {
    return struct {
        const Self = @This();
        const T = D.Type;
        const Channel = LinkedChannel(Args, Ret, capacity);
        pub const ServerChannel = LinkedChannel(Ret, Args, capacity);
        const ThreadT = CallLoop(S);
        thread: ThreadT,
        fifo: Channel,
        const S = struct {
            inst: T,
            channel: ServerChannel,
        };
        /// launches a background thread with the instances T
        /// the instance then can be called through an Delegator instance
        pub fn init(alloc: Allocator, instance: T) !Self {
            const bichannel = try get_bidirectional_channels(alloc, Args, Ret, capacity);
            const basefifo = bichannel[0];
            const serverfifo = bichannel[1];
            const wrapper = S{ .inst = instance, .channel = serverfifo };
            const ff = struct {
                fn f(
                    self: *S,
                ) !ThreadTimeOutNanoSecs {
                    while (self.channel.receive()) |msg| {
                        const ret = D.__message_handler(&self.inst, msg);
                        try self.channel.send(ret);
                    }
                    return ThreadTimeOutNanoSecs{ .WaitOrTimeOut = 3000 * 1_000_000 };
                }
            };
            return Self{ .thread = try ThreadT.init(alloc, wrapper, ff.f), .fifo = basefifo };
        }
        /// get a channel to instantiate a Delegator Instance
        pub fn get_channel(self: *Self) *DelegatorChannel(Args, Ret, capacity) {
            return &self.fifo;
        }
        /// returns a ResetEvent which wakes up the Delegator Thread when its sleeping
        /// waking is not considered realtime safe
        /// (use WakeUpThread for that)
        pub fn get_wake_handle(self: *Self) *std.Thread.ResetEvent {
            return self.thread.reset;
        }
        /// this wakes up the background thread: this is a blocking operation
        pub fn wake_up(self: *Self) void {
            self.get_wake_handle().set();
        }
        pub fn deinit(self: *Self) void {
            self.fifo.deinit();
            self.thread.deinit();
        }
    };
}
// server 2 (polling server)
// has a list of *atomic_bools + condvars
// busy loop:
// if bool is set:
// unset bool
// set and potentially wake up thread waiting on condvar

/// capacity = how many handles can be handled by / added to this Struct at runtime
pub fn WakeUpThread(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const ABoolResetEvent = struct { if_wakeup: AtomicBool = false, wake_up: *std.Thread.ResetEvent };

        counter: usize = 0,
        thread: CallLoop(WakeStruct),
        fifo: Fifo(ABoolResetEvent, capacity),
        cleanup_server_slots: []ABoolResetEvent,
        alloc: Allocator,

        const WakeStruct = struct {
            const wSelf = @This();
            fifo_ptr: *Fifo(ABoolResetEvent, capacity),
            counter: usize = 0,
            slots: []ABoolResetEvent,
            timer_ns: u64,
            fn f(self: *wSelf) !ThreadTimeOutNanoSecs {
                while (self.fifo_ptr.pop()) |b| {
                    self.slots[self.counter] = b;
                    self.counter += 1;
                }
                for (self.slots[0..self.counter]) |*x| {
                    if (x.if_wakeup.load(AtomicOrder.acquire)) {
                        x.if_wakeup.store(false, AtomicOrder.release);
                        x.wake_up.set();
                    }
                }
                return ThreadTimeOutNanoSecs{ .SleepInterval = self.timer_ns };
            }
        };

        pub fn init(alloc: Allocator, poll_interval_ns: u64) !Self {
            const server_slots = try alloc.alloc(Self.ABoolResetEvent, capacity);
            errdefer alloc.free(server_slots);
            var fifo = try Fifo(ABoolResetEvent, capacity).init(alloc);
            errdefer fifo.deinit();
            const wakestruct = WakeStruct{ .fifo_ptr = &fifo, .slots = server_slots, .timer_ns = poll_interval_ns };
            const thread = try CallLoop(WakeStruct).init(alloc, wakestruct, WakeStruct.f);
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
            self.alloc.free(self.cleanup_server_slots);
        }
        pub fn add(self: *Self, wakeup_handle: *std.Thread.ResetEvent) !*AtomicBool {
            if (self.counter + 1 == capacity) {
                return error.AllWakeUpSlotsAreOccupied;
            }
            var wake_up_atb: AtomicBool = AtomicBool(false);
            const rsevent = ABoolResetEvent{ .if_wakeup = wake_up_atb, .wake_up = wakeup_handle };
            self.fifo.enqueue(rsevent);
            self.counter += 1;
            return &wake_up_atb;
        }
        pub fn get_delegator_thread(gpa: Allocator, comptime ParamUnion: type, comptime RetUnion: type) !DelegatorThread(ParamUnion, RetUnion) {
            _ = gpa;
        }
    };
}
