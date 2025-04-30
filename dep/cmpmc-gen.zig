const std = @import("std");
const Thread = std.Thread;
const atomic = std.atomic;
const Allocator = std.mem.Allocator;

const thread_count = 4;
const batch_size = 1;
const iter_count = 500_000; // Lowered for fast detection
const queue_size = 1024;

var g_start: atomic.Value(bool) = atomic.Value(bool).init(false);

// Test struct to ensure the queue works with non-primitive types
const TestStruct = struct {
    id: usize,
    value: u64,
};

// Generic MPMC Queue (reuse previous implementation)
fn MPMCQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        const Cell = struct {
            seq: atomic.Value(usize),
            data: T,
        };

        buf: []Cell,
        buf_mask: usize,
        enqueue_pos: atomic.Value(usize),
        dequeue_pos: atomic.Value(usize),

        pub fn init(allocator: Allocator, buf_size: usize) !Self {
            std.debug.assert((buf_size >= 2) and ((buf_size & (buf_size - 1)) == 0));

            var buf = try allocator.alloc(Cell, buf_size);
            for (0..buf_size) |i| {
                buf[i] = Cell{
                    .seq = atomic.Value(usize).init(i),
                    .data = undefined,
                };
            }

            return Self{
                .buf = buf,
                .buf_mask = buf_size - 1,
                .enqueue_pos = atomic.Value(usize).init(0),
                .dequeue_pos = atomic.Value(usize).init(0),
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.buf);
        }

        pub fn enqueue(self: *Self, data: T) !void {
            var pos = self.enqueue_pos.load(.monotonic);
            var cell: *Cell = undefined;

            while (true) {
                cell = &self.buf[pos & self.buf_mask];
                const seq = cell.seq.load(.acquire);

                if (seq == pos) {
                    if (self.enqueue_pos.cmpxchgStrong(pos, pos + 1, .monotonic, .monotonic)) |_| {
                        break;
                    }
                } else if (@as(isize, @bitCast(seq)) < @as(isize, @bitCast(pos))) {
                    return error.QueueFull;
                } else {
                    pos = self.enqueue_pos.load(.monotonic);
                }
            }

            cell.data = data;
            cell.seq.store(pos + 1, .release);
        }

        pub fn dequeue(self: *Self) ?T {
            var pos = self.dequeue_pos.load(.monotonic);
            var cell: *Cell = undefined;

            while (true) {
                cell = &self.buf[pos & self.buf_mask];
                const seq = cell.seq.load(.acquire);

                if (seq == pos + 1) {
                    if (self.dequeue_pos.cmpxchgStrong(pos, pos + 1, .monotonic, .monotonic)) |_| {
                        break;
                    }
                } else if (@as(isize, @bitCast(seq)) < @as(isize, @bitCast(pos + 1))) {
                    return null;
                } else {
                    pos = self.dequeue_pos.load(.monotonic);
                }
            }

            const data = cell.data;
            cell.seq.store(pos + self.buf_mask + 1, .release);
            return data;
        }
    };
}

// Atomic counter for correctness checks
var produced = atomic.Value(usize).init(0);
var consumed = atomic.Value(usize).init(0);

// Worker thread function
fn threadfunc(q: *MPMCQueue(usize)) !void {
    while (!g_start.load(.acquire)) {
        try Thread.yield();
    }

    const thread_id = Thread.getCurrentId();
    var randgen = std.Random.DefaultPrng.init(thread_id);
    const random = randgen.random();
    const pause = random.intRangeAtMost(usize, 0, 100);

    for (0..pause) |_| {
        std.atomic.spinLoopHint();
    }

    for (0..iter_count) |_| {
        const value = produced.fetchAdd(1, .monotonic);
        while (q.enqueue(value)) |_| {} else |_| {
            try Thread.yield();
        }

        var result: ?usize = null;
        while (result == null) {
            result = q.dequeue();
            if (result == null) {
                try Thread.yield();
            }
        }

        if (result.? != value) {
            std.log.err("Ordering Error: Expected {d}, got {d}", .{ value, result.? });
            return error.OrderingViolation;
        }
        _ = consumed.fetchAdd(1, .monotonic);
    }
}

// Main test function
fn mpmc_thread_test(allocator: Allocator) !void {
    var queue = try MPMCQueue(usize).init(allocator, queue_size);
    defer queue.deinit(allocator);

    var threads: [thread_count]Thread = undefined;
    for (&threads) |*t| {
        t.* = try Thread.spawn(.{}, threadfunc, .{&queue});
    }

    std.time.sleep(1_000_000_000); // Sleep for 1 second
    g_start.store(true, .release);

    for (&threads) |t| {
        t.join();
    }

    // Final correctness check
    if (produced.load(.monotonic) != consumed.load(.monotonic)) {
        std.log.err("Mismatch: Produced {d}, Consumed {d}", .{
            produced.load(.monotonic),
            consumed.load(.monotonic),
        });
        return error.DataLoss;
    }

    std.log.warn("Test passed! Produced = Consumed = {d}", .{produced.load(.monotonic)});
}

// Additional basic enqueue-dequeue test
fn mpmc_test(allocator: Allocator) !void {
    var queue = try MPMCQueue(TestStruct).init(allocator, queue_size);
    defer queue.deinit(allocator);

    const item = TestStruct{ .id = 42, .value = 1337 };
    try queue.enqueue(item);

    const dequeued = queue.dequeue() orelse {
        std.log.err("Test failed: queue returned null", .{});
        return error.TestFailed;
    };

    if (dequeued.id != 42 or dequeued.value != 1337) {
        std.log.err("Test failed: dequeued struct mismatch", .{});
        return error.TestFailed;
    }

    std.log.warn("Basic test passed: Struct enqueue/dequeue works.", .{});
}

// Run tests
test "generic MPMC queue" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    try mpmc_thread_test(allocator);
    try mpmc_test(allocator);
}
