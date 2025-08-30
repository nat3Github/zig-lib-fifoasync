const std = @import("std");
const AtomicOrder = std.builtin.AtomicOrder;
const Allocator = std.mem.Allocator;
const root = @import("../root.zig");

/// Single Producer Single Consumer Lockfree Queue Algorithm according to:
/// https://www.irif.fr/~guatto/papers/sbac13.pdf WeakRB Algorithm
/// lives on the stack
pub fn Fifo(comptime T: type, comptime capacity: comptime_int) type {
    return struct {
        const Self = @This();
        back: usize = 0,
        cback: usize = 0,
        front: usize = 0,
        pfront: usize = 0,
        data: [capacity]T = undefined,
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

pub fn Fifo2(comptime T: type) type {
    return struct {
        const Self = @This();
        back: usize align(root.cpu_cache_line) = 0,
        cback: usize = 0,
        pfront: usize = 0,
        front: usize align(root.cpu_cache_line) = 0,
        data: []T,
        capacity: usize,

        pub fn init(alloc: Allocator, capacity: usize) !Self {
            const data = try alloc.alloc(T, capacity);
            return Self{
                .capacity = capacity,
                .data = data,
            };
        }
        pub fn deinit(self: *Self, alloc: Allocator) void {
            alloc.free(self.data);
        }
        pub fn push_slice(self: *Self, items: []const T) !void {
            const n = items.len;
            const b = @atomicLoad(usize, &self.back, .unordered);
            if ((self.pfront + self.capacity - b) < n) {
                self.pfront = @atomicLoad(usize, &self.front, .acquire);
                if ((self.pfront + self.capacity - b) < n) {
                    return error.NotEnoughSpace;
                }
            }
            for (0..n) |i| {
                self.data[(b + i) % self.capacity] = items[i];
            }
            @atomicStore(usize, &self.back, b + n, .release);
        }
        pub fn pop_slice(self: *Self, items: []T) !void {
            const n = items.len;
            const f = @atomicLoad(usize, &self.front, .unordered);
            if ((self.cback - f) < n) {
                self.cback = @atomicLoad(usize, &self.back, .acquire);
                if ((self.cback - f) < n) {
                    return error.NotEnoughItems;
                }
            }
            for (items, 0..) |*e, i| {
                e.* = self.data[(f + i) % self.capacity];
            }
            @atomicStore(usize, &self.front, f + n, .release);
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
pub fn FlexFifo(comptime T: type, multi_reader: bool, multi_writer: bool) align(root.cpu_cache_line) type {
    return struct {
        fifo: Fifo2(T),
        reader_lock: root.prim.Spinlock = .{},
        writer_lock: root.prim.Spinlock = .{},
        pub fn init(alloc: Allocator, capacity: usize) !@This() {
            return @This(){
                .fifo = try Fifo2(T).init(alloc, capacity),
            };
        }
        pub fn deinit(self: *@This(), alloc: Allocator) void {
            self.fifo.deinit(alloc);
        }
        pub fn push(self: *@This(), item: T) !void {
            if (comptime multi_writer) {
                self.writer_lock.lock();
                defer self.writer_lock.unlock();
                try self.fifo.push(item);
            } else try self.fifo.push(item);
        }
        pub fn pop(self: *@This()) ?T {
            if (comptime multi_reader) {
                self.reader_lock.lock();
                defer self.reader_lock.unlock();
                return self.fifo.pop();
            } else return self.fifo.pop();
        }
    };
}

pub fn LinkedChannel(
    comptime SendT: type,
    comptime ReturnT: type,
) type {
    return struct {
        const Self = @This();
        sender: Fifo2(SendT),
        receiver: Fifo2(ReturnT),
        pub fn send(self: *Self, msg: SendT) !void {
            try self.sender.push(msg);
        }
        pub fn receive(self: *Self) ?ReturnT {
            return self.receiver.pop();
        }
        pub fn init(sender: Fifo2(SendT), receiver: Fifo2(ReturnT)) Self {
            return Self{
                .sender = sender,
                .receiver = receiver,
            };
        }
        pub fn deinit(self: *Self, alloc: Allocator) void {
            self.sender.deinit(alloc);
        }
    };
}

pub fn BiLinkedChannels(A: type, B: type) type {
    return struct {
        A_to_B_channel: LinkedChannel(A, B),
        B_to_A_channel: LinkedChannel(B, A),
    };
}
pub fn get_bidirectional_linked_channels(gpa: Allocator, comptime A: type, comptime B: type, capacity: comptime_int) !BiLinkedChannels(A, B) {
    const fifoA = try Fifo2(A).init(gpa, capacity);
    const fifoB = try Fifo2(B).init(gpa, capacity);
    return BiLinkedChannels(A, B){
        .A_to_B_channel = LinkedChannel(A, B).init(fifoA, fifoB),
        .B_to_A_channel = LinkedChannel(B, A).init(fifoB, fifoA),
    };
}
