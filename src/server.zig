const std = @import("std");
const testing = std.testing;
const Atomic = std.atomic.Value;
pub const generate_delegator = @import("delegator-gen.zig").code_gen;
const spsc = @import("weakrb-spsc.zig");
pub const LinkedChannel = spsc.LinkedChannelWeakRB;
pub const get_bidirectional_channels = spsc.get_bidirectional_linked_channels_rb;
pub const Fifo = spsc.FifoWeakRB;

const NanoSeconds = enum {
    SleepNow,
    WaitForWakeUpOrTimeOut,
};
pub const ThreadAction = union(NanoSeconds) {
    SleepNow: u64,
    WaitForWakeUpOrTimeOut: u64,
};

const CallLoop =
    struct {
    const Self = @This();
    running: *Atomic(bool),
    reset: *std.Thread.ResetEvent,
    /// return of f determines if thread will sleep for the returned interval before the next call to f
    /// or sleep till it's woken up through the condvar
    /// if error is returned from f the thread terminates
    pub fn init(alloc: std.mem.Allocator, comptime T: anytype, f: fn (*@TypeOf(T)) anyerror!ThreadAction) Self {
        const server = struct {
            fn exe(comptime TX: anytype, poll_fnx: fn (*@TypeOf(TX)) anyerror!ThreadAction, running: *Atomic(bool), reset: *std.Thread.ResetEvent) void {
                var t: @TypeOf(TX) = TX;
                var action = ThreadAction.SleepNanoSeconds(1000);
                while (running) {
                    switch (action) {
                        .SleepNow => |sleep_ns| {
                            std.time.sleep(sleep_ns);
                        },
                        .WaitForWakeUpOrTimeOut => |timeout_ns| {
                            reset.reset();
                            reset.timedWait(timeout_ns) catch {};
                        },
                    }
                    action = poll_fnx(&t) catch |e| {
                        std.log.err("thread will exit with error: {any}", .{e});
                        return;
                    };
                }
            }
        };
        const reset = std.Thread.ResetEvent{};
        const running: Atomic(bool) = true;
        std.Thread.spawn(.{ .allocator = alloc }, server.exe, .{ T, f, &running, &reset });
        return Self{
            .running = &running,
            .reset = &reset,
        };
    }
    pub fn deinit(
        self: *Self,
    ) void {
        self.running.store(false, std.builtin.AtomicOrder.unordered);
    }
};

test "simple call loop" {}

// server implementation using fifo's and condition variables + mmutexes: for non blocking realtimesafe work with blocking background threads

// server 1 (actual server)
// - has sendreceive channels (2waychannel)
// while running:
// wait on condition
// unset condition
// spin n times:
// if event handle event return result through channel

/// A Background server for auto generated Delegators
/// to make one pass the generated Param and Return Unions
pub fn DelegatorServer(comptime ParamUnion: type, comptime RetUnion: type) type {
    const Self = @This()(ParamUnion, RetUnion);
    return struct {
        thread: CallLoop,
        register_fifo: LinkedChannel(ParamUnion, RetUnion),
        pub fn init(alloc: std.mem.Allocator, worker: anytype, delegator: anytype) Self {
            const wf: fn (*@TypeOf(worker), ParamUnion) RetUnion = delegator.message_handler;
            const W = struct {
                const WSelf = @This();
                worker: @TypeOf(worker),
                channel: LinkedChannel(RetUnion, ParamUnion),
                fn f(self: *WSelf) !ThreadAction {
                    while (self.channel.receive()) |msg| {
                        wf(&self.worker, msg);
                    }
                    return ThreadAction.wait_for_wakeup_or_timeout_ns(3000 * 1_000_000);
                }
            };
            const wrapper = W{ .worker = worker };

            return Self{ .thread = CallLoop.init(alloc, wrapper, wrapper.f) };
        }
    };
}

// server 2 (polling server)
// has a list of *atomic_bools + condvars
// busy loop:
// if bool is set:
// unset bool
// set and potentially wake up thread waiting on condvar

const WakeUpThread = struct {
    thread: CallLoop,
    fifo_data: []*std.Thread.ResetEvent,
    register_fifo: Fifo(Self.ABoolResetEvent),
    alloc: std.mem.Allocator,
    counter: usize = 0,
    const ABoolResetEvent = struct { if_wakeup: Atomic(bool) = false, wake_up: *std.Thread.ResetEvent };
    const Self = @This();
    const WakeStruct = struct {
        register_fifo: *Fifo(Self.ABoolResetEvent),
        counter: usize = 0,
        slots: []Self.ABoolResetEvent,
        fn f(self: *Self.WakeStruct) !ThreadAction {
            while (self.register_fifo.dequeue()) |msg| {
                self.slots[self.counter] = msg;
                self.counter += 1;
            }
            // check all atomics up to counter
            for (self.slots[0..self.counter]) |x| {
                if (x.if_wakeup) {
                    x.if_wakeup.store(false, std.builtin.AtomicOrder.acq_rel);
                    x.wake_up.set();
                }
            }
            return ThreadAction;
        }
    };
    pub fn init(alloc: std.mem.Allocator, comptime slots: comptime_int) !Self {
        const data = try alloc.alloc(Self.ABoolResetEvent, slots);
        errdefer alloc.free(data);
        const xslots = try alloc.alloc(Self.ABoolResetEvent, slots);
        errdefer alloc.free(xslots);
        const fifo = Fifo(*std.Thread.ResetEvent).init(data);
        const wakestruct = Self.WakeStruct{ .register_fifo = &fifo, .slots = xslots };
        const thread = CallLoop.init(alloc, wakestruct, Self.WakeStruct.f);
        return Self{ .thread = thread, .fifo_data = data, .register_fifo = fifo, .alloc = alloc };
    }
    pub fn deinit(self: *Self) void {
        self.thread.deinit();
        self.alloc.free(self.fifo_data);
    }
    pub fn add(self: *Self, wakeup_handle: *std.Thread.ResetEvent) *Atomic(bool) {
        var wake_up_atb: Atomic(bool) = false;
        const rsevent = ABoolResetEvent{ .if_wakeup = wake_up_atb, .wake_up = wakeup_handle };
        self.register_fifo.enqueue(rsevent);
        self.counter += 1;
        return &wake_up_atb;
    }
};
