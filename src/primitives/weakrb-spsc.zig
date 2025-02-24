const std = @import("std");
const AtomicV = std.atomic.Value;
const AtomicOrder = std.builtin.AtomicOrder;
const AtomicUsize = AtomicV(usize);
const Allocator = std.mem.Allocator;

/// Single Producer Single Consumer Lockfree Queue Algorithm according to:
/// https://www.irif.fr/~guatto/papers/sbac13.pdf WeakRB Algorithm
pub fn Fifo(comptime T: type, comptime capacity: comptime_int) type {
    return struct {
        const Self = @This();
        back: AtomicUsize = AtomicUsize.init(0),
        cback: usize = 0,
        front: AtomicUsize = AtomicUsize.init(0),
        pfront: usize = 0,
        data: []T,
        gpa: Allocator,
        // this somehow doesnt work in threaded context so its privat for now
        fn init(alloc: Allocator) !Self {
            const data = try alloc.alloc(T, capacity);
            return .{
                .gpa = alloc,
                .data = data,
            };
        }
        pub fn init_on_heap(alloc: Allocator) !*Self {
            const data = try alloc.alloc(T, capacity);
            const this = try alloc.create(Self);
            this.* = .{
                .gpa = alloc,
                .data = data,
            };
            return this;
        }
        pub fn deinit(self: *Self) void {
            self.gpa.free(self.data);
        }
        pub fn push_slice(self: *Self, items: []const T) !void {
            const n = items.len;
            const b = self.back.load(AtomicOrder.unordered);
            if ((self.pfront + capacity - b) < n) {
                self.pfront = self.front.load(AtomicOrder.acquire);
                if ((self.pfront + capacity - b) < n) {
                    return error.NotEnoughSpace;
                }
            }
            for (0..n) |i| {
                self.data[(b + i) % capacity] = items[i];
            }
            self.back.store(b + n, AtomicOrder.release);
        }
        pub fn pop_slice(self: *Self, items: []T) !void {
            const n = items.len;
            const f = self.front.load(AtomicOrder.unordered);
            if ((self.cback - f) < n) {
                self.cback = self.back.load(AtomicOrder.acquire);
                if ((self.cback - f) < n) {
                    return error.NotEnoughItems;
                }
            }
            for (items, 0..) |*e, i| {
                e.* = self.data[(f + i) % capacity];
            }
            self.front.store(f + n, AtomicOrder.release);
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
    // var heapalloc = std.heap.GeneralPurposeAllocator(.{}){};
    // const test_gpa = heapalloc.allocator();
    const test_gpa = std.testing.allocator;
    var fifo = try Fifo(u32, 4).init(test_gpa);
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
pub fn get_bidirectional_linked_channels(gpa: Allocator, comptime A: type, comptime B: type, capacity: comptime_int) !std.meta.Tuple(&.{ LinkedChannel(A, B, capacity), LinkedChannel(B, A, capacity) }) {
    const fifoA = try Fifo(A, capacity).init_on_heap(gpa);
    const fifoB = try Fifo(B, capacity).init_on_heap(gpa);
    const c1 = LinkedChannel(A, B, capacity).init(fifoA, fifoB);
    const c2 = LinkedChannel(B, A, capacity).init(fifoB, fifoA);
    return .{ c1, c2 };
}

test "2way channel basic test" {
    const test_gpa = std.testing.allocator;
    const channels = try get_bidirectional_linked_channels(test_gpa, u32, i32, 4);
    var base = channels[0];
    var server = channels[1];
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
