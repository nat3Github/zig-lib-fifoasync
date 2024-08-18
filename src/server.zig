const std = @import("std");
const Fifo = @import("lock-free-fifo.zig").Ring;

pub fn Channel2Way(
    comptime SendT: type,
    comptime ReturnT: type,
) type {
    const Self = @This()(SendT, ReturnT);
    return struct {
        sender: Fifo(SendT),
        sender_underlying_data: []SendT,
        receiver: *Fifo(ReturnT),
        alloc: std.mem.Allocator,
        fn send(self: *Self, msg: SendT) !void {
            if (!self.sender.enqueue(msg)) {
                return error.SendFifoFull;
            }
        }
        fn receive(self: *Self) ?ReturnT {
            return self.receiver.dequeue();
        }
        fn init(sender: Fifo(SendT), sender_heap: []SendT, heap_allocator: std.mem.Allocator, receiver: *Fifo(ReturnT)) Self {
            return Self{
                .sender = sender,
                .alloc = heap_allocator,
                .sender_underlying_data = sender_heap,
                .receiver = receiver,
            };
        }
        fn deinit(self: *Self) void {
            self.alloc.free(self.sender_underlying_data);
        }
    };
}
// Fifo Data will be allocated in heap because channels are potentially used on different threads and can potentially need a lot of space -> stack overflow
pub fn get_channel2way(gpa: std.mem.Allocator, comptime A: type, comptime B: type, len: comptime_int) !std.meta.Tuple(.{ Channel2Way(A, B), Channel2Way(B, A) }) {
    const memA = try gpa.alloc(A, len);
    const fifoA = Fifo(A).init(memA);
    const memB = try gpa.alloc(B, len);
    const fifoB = Fifo(B).init(memB);
    return .{ Channel2Way(A, B).init(fifoA, memA, gpa, &fifoB), Channel2Way(B, A).init(fifoB, memB, gpa, &fifoA) };
}

const Atomic = std.atomic.Value;

const Action = enum {
    sleep_for_interval_ns,
    wait_for_wakeup_or_timeout_ns,
};
pub const ThreadAction = union(Action) {
    sleep_for_interval_ns: u64,
    wait_for_wakeup_or_timeout_ns: u64,
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
                        .SleepNanoSeconds => |sleep_ns| {
                            std.time.sleep(sleep_ns);
                        },
                        .WaitForWakeup => |timeout_ns| {
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

// server implementation using fifo's and condition variables + mmutexes: for non blocking realtimesafe work with blocking background threads

// server 1 (actual server)
// - has sendreceive channels (2waychannel)
// while running:
// wait on condition
// unset condition
// spin n times:
// if event handle event return result through channel

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
