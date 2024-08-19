const std = @import("std");
const AtomicV = std.atomic.Value;
const O = std.builtin.AtomicOrder;
const AtomicUsize = AtomicV(usize);
const Allocator = std.mem.Allocator;

/// Single Producer Single Consumer Lockfree Queue Algorithm according to:
/// https://www.irif.fr/~guatto/papers/sbac13.pdf WeakRB Algorithm
pub fn FifoWeakRB(comptime T: type, comptime capacity: comptime_int) type {
    return struct {
        const Self = @This();
        back: AtomicUsize = AtomicUsize.init(0),
        cback: usize = 0,
        front: AtomicUsize = AtomicUsize.init(0),
        pfront: usize = 0,

        data: []T,
        gpa: Allocator,
        pub fn init(alloc: Allocator) !Self {
            const data = try alloc.alloc(T, capacity);
            return .{
                .gpa = alloc,
                .data = data,
            };
        }
        pub fn deinit(self: *Self) void {
            self.gpa.free(self.data);
        }
        pub fn push_slice(self: *Self, items: []const T) !void {
            const n = items.len;
            const b = self.back.load(O.unordered);
            if ((self.pfront + capacity - b) < n) {
                self.pfront = self.front.load(O.acquire);
                if ((self.pfront + capacity - b) < n) {
                    return error.NotEnoughSpace;
                }
            }
            for (0..n) |i| {
                self.data[(b + i) % capacity] = items[i];
            }
            self.back.store(b + n, O.release);
            return true;
        }
        pub fn pop_slice(self: *Self, items: []T) !void {
            const n = items.len;
            const f = self.front.load(O.unordered);
            if ((self.cback - f) < n) {
                self.cback = self.back.load(O.acquire);
                if ((self.cback - f) < n) {
                    return error.NotEnoughItems;
                }
            }
            for (&items, 0..) |*e, i| {
                e.* = self.data[(f + i) % capacity];
            }
            self.front.store(f + n, O.release);
            return true;
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

pub fn LinkedChannelWeakRB(
    comptime SendT: type,
    comptime ReturnT: type,
    comptime capacity: comptime_int,
) type {
    return struct {
        const Self = @This();
        sender: FifoWeakRB(SendT),
        receiver: *FifoWeakRB(ReturnT),
        fn send(self: *Self, msg: SendT) !void {
            if (!self.sender.enqueue(msg)) {
                return error.SendFifoFull;
            }
        }
        fn receive(self: *Self) ?ReturnT {
            return self.receiver.dequeue();
        }
        fn init(sender: FifoWeakRB(SendT, capacity), receiver: *FifoWeakRB(ReturnT, capacity)) Self {
            return Self{
                .sender = sender,
                .receiver = receiver,
            };
        }
        fn deinit(self: *Self) void {
            self.alloc.free(self.sender_underlying_data);
        }
    };
}
pub fn get_bidirectional_linked_channels_rb(gpa: std.mem.Allocator, comptime A: type, comptime B: type, capacity: comptime_int) !std.meta.Tuple(&.{ LinkedChannelWeakRB(A, B, capacity), LinkedChannelWeakRB(B, A, capacity) }) {
    var fifoA = try FifoWeakRB(A, capacity).init(gpa);
    var fifoB = try FifoWeakRB(B, capacity).init(gpa);
    const c1 = LinkedChannelWeakRB(A, B, capacity).init(fifoA, &fifoB);
    const c2 = LinkedChannelWeakRB(B, A).init(fifoB, &fifoA);
    return .{ c1, c2 };
}

test "2way channel test" {
    var heapalloc = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = heapalloc.allocator();
    const channels = try get_bidirectional_linked_channels_rb(gpa, u32, i32, 4);
    var base = channels[0];
    var server = channels[1];
    try base.send(2);
    try base.send(2);
    try base.send(2);
    server.receive();
    try base.send(2);
    try base.send(2);
}
