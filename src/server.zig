const std = @import("std");
const testing = std.testing;
const Atomic = std.atomic.Value;
pub const generate_delegator = @import("delegator-gen.zig").code_gen;
const spsc = @import("weakrb-spsc.zig");
pub const LinkedChannel = spsc.LinkedChannelWeakRB;
pub const get_bidirectional_channels = spsc.get_bidirectional_linked_channels_rb;
pub const Fifo = spsc.FifoWeakRB;
const AtomicOrder = std.builtin.AtomicOrder;
const Allocator = std.mem.Allocator;

const AtomicBool = Atomic(bool);
var heapalloc = std.heap.GeneralPurposeAllocator(.{}){};
const test_gpa = heapalloc.allocator();

const ThreadAction = enum {
    SleepNow,
    WaitForWakeUpOrTimeOut,
};
pub const ThreadTimeOutNanoSecs = union(ThreadAction) {
    SleepNow: u64,
    WaitForWakeUpOrTimeOut: u64,
};

pub fn CallLoop(comptime T: type) type {
    return struct {
        const Self = @This();
        running: Atomic(bool),
        reset: std.Thread.ResetEvent,
        /// return of f determines if thread will sleep for the returned interval before the next call to f
        /// or sleep till it's woken up through the condvar
        /// if error is returned from f the thread terminates
        pub fn init(alloc: Allocator, instance: T, f: fn (*T) anyerror!ThreadTimeOutNanoSecs) !Self {
            const thr = struct {
                fn exe(instancex: T, fx: fn (*T) anyerror!ThreadTimeOutNanoSecs, running: *Atomic(bool), reset: *std.Thread.ResetEvent) void {
                    running.store(true, AtomicOrder.seq_cst);
                    var t: T = instancex;
                    var action = ThreadTimeOutNanoSecs{ .SleepNow = 0 * 1_000_000 };
                    while (running.load(AtomicOrder.unordered)) {
                        switch (action) {
                            .SleepNow => |sleep_ns| {
                                std.time.sleep(sleep_ns);
                            },
                            .WaitForWakeUpOrTimeOut => |timeout_ns| {
                                reset.reset();
                                reset.timedWait(timeout_ns) catch {};
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
            var reset = std.Thread.ResetEvent{};
            var running: AtomicBool = AtomicBool.init(false);
            // std.debug.print("running var is: {any}\n", .{running.load(AtomicOrder.seq_cst)});
            const thread = try std.Thread.spawn(.{ .allocator = alloc }, thr.exe, .{ instance, f, &running, &reset });
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
            return ThreadTimeOutNanoSecs{ .SleepNow = 1 * 1_000_000 };
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

/// A Blocking thread for auto generated Delegators
const DelegatorChannel = LinkedChannel;
pub fn DelegatorThread(comptime D: type, comptime Args: type, comptime Ret: type, comptime capacity: comptime_int) type {
    return struct {
        const Self = @This();
        const T = D.Type;
        const Channel = LinkedChannel(Args, Ret, capacity);
        pub const ServerChannel = LinkedChannel(Ret, Args, capacity);
        thread: CallLoop(S),
        fifo: Channel,
        const S = struct {
            inst: T,
            channel: ServerChannel,
        };
        /// launches a background thread with the instances T
        /// the instance then can be called through an Delegator instance
        pub fn init(alloc: Allocator, instance: T) !Self {
            const wrapper = S{
                .inst = instance,
            };
            const xf = struct {
                fn f(
                    self: *S,
                ) !ThreadTimeOutNanoSecs {
                    while (self.channel.receive()) |msg| {
                        const ret = D.message_handler(&self.inst, msg);
                        self.channel.send(ret);
                    }
                    return ThreadTimeOutNanoSecs.wait_for_wakeup_or_timeout_ns(3000 * 1_000_000);
                }
            };
            return Self{ .thread = try CallLoop.init(alloc, wrapper, xf.f) };
        }
        /// get a channel to instantiate a Delegator Instance
        pub fn get_channel(self: *Self) *DelegatorChannel(Args, Ret, capacity) {
            return &self.fifo;
        }
        /// returns a ResetEvent which wakes up the Delegator Thread when its sleeping
        /// waking is not considered realtime safe
        /// (use WakeUpThread for that)
        pub fn get_wake_handle(self: *Self) *std.Thread.ResetEvent {
            return &self.thread.reset;
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
                return ThreadTimeOutNanoSecs{ .SleepNow = self.timer_ns };
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
