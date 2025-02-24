const std = @import("std");
const AtomicOrder = std.builtin.AtomicOrder;
const Allocator = std.mem.Allocator;

/// Single Producer Single Consumer Lockfree Queue Algorithm according to:
/// https://www.irif.fr/~guatto/papers/sbac13.pdf WeakRB Algorithm
pub fn Fifo(comptime T: type, comptime capacity: comptime_int) type {
    return struct {
        const Self = @This();
        back: usize = 0,
        cback: usize = 0,
        front: usize = 0,
        pfront: usize = 0,
        data: []T,
        gpa: Allocator,
        /// allocates its data and itself on the heap (cant be stack local)
        pub fn init(alloc: Allocator) !*Self {
            const data = try alloc.alloc(T, capacity);
            const this = try alloc.create(Self);
            this.* = .{
                .gpa = alloc,
                .data = data,
            };
            return this;
        }
        /// cleans up all data allocated by This including the pointer to itself (dont use the pointer after this)
        pub fn deinit(self: *Self) void {
            self.gpa.free(self.data);
            self.gpa.destroy(self);
        }
        pub fn push_slice(self: *Self, items: []const T) !void {
            const n = items.len;
            const b = @atomicLoad(usize, &self.back, .unordered);
            // const b = self.back.load(AtomicOrder.unordered);
            if ((self.pfront + capacity - b) < n) {
                self.pfront = @atomicLoad(usize, &self.front, .acquire);
                // self.pfront = self.front.load(AtomicOrder.acquire);
                if ((self.pfront + capacity - b) < n) {
                    return error.NotEnoughSpace;
                }
            }
            for (0..n) |i| {
                self.data[(b + i) % capacity] = items[i];
            }
            @atomicStore(usize, &self.back, b + n, .release);
            // self.back.store(b + n, AtomicOrder.release);
        }
        pub fn pop_slice(self: *Self, items: []T) !void {
            const n = items.len;
            const f = @atomicLoad(usize, &self.front, .unordered);
            // const f = self.front.load(AtomicOrder.unordered);
            if ((self.cback - f) < n) {
                self.cback = @atomicLoad(usize, &self.back, .acquire);
                // self.cback = self.back.load(AtomicOrder.acquire);
                if ((self.cback - f) < n) {
                    return error.NotEnoughItems;
                }
            }
            for (items, 0..) |*e, i| {
                e.* = self.data[(f + i) % capacity];
            }
            @atomicStore(usize, &self.front, f + n, .release);
            // self.front.store(f + n, AtomicOrder.release);
        }
        pub fn push(self: *Self, item: T) !void {
            const xitem: [1]T = .{item};
            try self.push_slice(&xitem);
        }
        pub fn pop(self: *Self) ?T {
            var empty: [1]T = undefined;
            self.pop_slice(&empty) catch {
                return null;
            };
            return empty[0];
        }
    };
}
test "spsc basic test" {
    const test_gpa = std.testing.allocator;
    var fifo = try Fifo(u32, 4).init(test_gpa);
    defer fifo.deinit();
    for (0..10) |i| {
        const casted: u32 = @intCast(i);
        fifo.push(casted) catch unreachable;
        const ret = fifo.pop().?;
        try std.testing.expect((ret == casted));
    }
}
pub fn LinkedChannel(
    comptime SendT: type,
    comptime ReturnT: type,
    comptime capacity: comptime_int,
) type {
    return struct {
        const Self = @This();
        sender: *Fifo(SendT, capacity),
        receiver: *Fifo(ReturnT, capacity),
        pub fn send(self: *Self, msg: SendT) !void {
            try self.sender.push(msg);
        }
        pub fn receive(self: *Self) ?ReturnT {
            return self.receiver.pop();
        }
        pub fn init(sender: *Fifo(SendT, capacity), receiver: *Fifo(ReturnT, capacity)) Self {
            return Self{
                .sender = sender,
                .receiver = receiver,
            };
        }
        pub fn deinit(self: *Self) void {
            self.sender.deinit();
        }
    };
}

pub fn BiLinkedChannels(A: type, B: type, capacity: comptime_int) type {
    return struct {
        A_to_B_channel: LinkedChannel(A, B, capacity),
        B_to_A_channel: LinkedChannel(B, A, capacity),
    };
}
pub fn get_bidirectional_linked_channels(gpa: Allocator, comptime A: type, comptime B: type, capacity: comptime_int) !BiLinkedChannels(A, B, capacity) {
    const fifoA = try Fifo(A, capacity).init(gpa);
    const fifoB = try Fifo(B, capacity).init(gpa);
    return BiLinkedChannels(A, B, capacity){
        .A_to_B_channel = LinkedChannel(A, B, capacity).init(fifoA, fifoB),
        .B_to_A_channel = LinkedChannel(B, A, capacity).init(fifoB, fifoA),
    };
}

test "2way channel basic test" {
    const test_gpa = std.testing.allocator;
    const channels = try get_bidirectional_linked_channels(test_gpa, u32, i32, 4);
    var base = channels.A_to_B_channel;
    var server = channels.B_to_A_channel;
    defer base.deinit();
    defer server.deinit();
    for (0..10) |i| {
        const casted: u32 = @intCast(i);
        try base.send(casted);
        const ret: u32 = server.receive().?;
        try std.testing.expect((ret == casted));
    }
}

test "test all refs" {
    std.testing.refAllDecls(@This());
}
