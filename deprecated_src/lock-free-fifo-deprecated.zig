// MIT License
//
// Copyright (c) 2023 Christopher Dolan <chris@codingstream.org>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

// updated to zig version 0.13

const Atomic = std.atomic.Value;
const Ordering = std.builtin.AtomicOrder;

const std = @import("std");

const PaddedConsumer = struct {
    head: Atomic(usize),
    padding: [std.atomic.cache_line - @sizeOf(Atomic(usize))]u8 = undefined,
};

const PaddedProducer = struct {
    tail: Atomic(usize),
    padding: [std.atomic.cache_line - @sizeOf(Atomic(usize))]u8 = undefined,
};

pub fn Ring(comptime T: type) type {
    return struct {
        consumer: PaddedConsumer,
        producer: PaddedProducer,
        items: []T,
        mask: usize,

        const Self = @This();

        pub fn init(items: []T) Self {
            std.debug.assert(std.math.isPowerOfTwo(items.len));

            return Self{
                .consumer = PaddedConsumer{ .head = Atomic(usize).init(0) },
                .producer = PaddedProducer{ .tail = Atomic(usize).init(0) },
                .items = items,
                .mask = items.len - 1,
            };
        }

        pub inline fn enqueue(self: *Self, value: T) bool {
            const consumer = self.consumer.head.load(Ordering.acquire);
            const producer = self.producer.tail.load(Ordering.acquire);
            const delta = producer + 1;

            if (delta & self.mask == consumer & self.mask)
                return false;

            self.items[producer & self.mask] = value;

            std.atomic.fence(Ordering.release);
            self.producer.tail.store(delta, Ordering.release);

            return true;
        }

        pub inline fn dequeue(self: *Self) ?T {
            const consumer = self.consumer.head.load(Ordering.acquire);
            const producer = self.producer.tail.load(Ordering.acquire);

            if (consumer == producer)
                return null;

            std.atomic.fence(Ordering.acquire);

            const value = self.items[consumer & self.mask];

            std.atomic.fence(Ordering.Release);
            self.consumer.head.store(consumer + 1, Ordering.release);

            return value;
        }

        pub inline fn length(self: *Self) usize {
            const consumer = self.consumer.head.load(Ordering.acquire);
            const producer = self.producer.tail.load(Ordering.acquire);
            return (producer - consumer) & self.mask;
        }
    };
}

const expectEqual = std.testing.expectEqual;

test "enqueue" {
    var buf = [4]i32{ 0, 0, 0, 0 };
    var ring = Ring(i32).init(buf[0..]);

    try expectEqual(true, ring.enqueue(2));
    try expectEqual(true, ring.enqueue(3));
    try expectEqual(true, ring.enqueue(5));
    try expectEqual(false, ring.enqueue(7));

    try expectEqual(@as(i32, 2), buf[0]);
    try expectEqual(@as(i32, 3), buf[1]);
    try expectEqual(@as(i32, 5), buf[2]);
    try expectEqual(@as(i32, 0), buf[3]);
}

test "dequeue" {
    var buf: [4]i32 = undefined;
    var ring = Ring(i32).init(buf[0..]);

    _ = ring.enqueue(2);
    _ = ring.enqueue(3);
    _ = ring.enqueue(5);

    try expectEqual(@as(i32, 2), ring.dequeue().?);
    try expectEqual(@as(i32, 3), ring.dequeue().?);
    try expectEqual(@as(i32, 5), ring.dequeue().?);
}

test "length" {
    var buf: [8]i32 = undefined;
    var ring = Ring(i32).init(buf[0..]);

    try expectEqual(@as(usize, 0), ring.length());

    _ = ring.enqueue(2);
    _ = ring.enqueue(3);
    _ = ring.enqueue(5);

    try expectEqual(@as(usize, 3), ring.length());

    _ = ring.dequeue();
    _ = ring.dequeue();

    try expectEqual(@as(usize, 1), ring.length());

    _ = ring.dequeue();

    try expectEqual(@as(usize, 0), ring.length());
}
