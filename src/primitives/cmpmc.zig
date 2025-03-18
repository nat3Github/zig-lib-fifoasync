const std = @import("std");
const Allocator = std.mem.Allocator;
const atomic = std.atomic;
const Ordering = std.builtin.AtomicOrder;

const CACHELINE_SIZE = 64;
const CacheLinePadT = [CACHELINE_SIZE]u8;

pub const Cell = struct {
    seq: atomic.Value(usize),
    data: ?*anyopaque = undefined,
};

pub const MPMCQueue = struct {
    pad0: CacheLinePadT = undefined,
    buf: []Cell,
    buf_mask: usize,
    pad1: CacheLinePadT = undefined,
    enqueue_pos: atomic.Value(usize),
    pad2: CacheLinePadT = undefined,
    dequeue_pos: atomic.Value(usize),
    pad3: CacheLinePadT = undefined,

    pub fn init(allocator: Allocator, buf_size: usize) !MPMCQueue {
        std.debug.assert((buf_size >= 2) and ((buf_size & (buf_size - 1)) == 0));

        var buf = try allocator.alloc(Cell, buf_size);
        for (0..buf_size) |i| {
            buf[i] = Cell{ .seq = atomic.Value(usize).init(i) };
        }

        return MPMCQueue{
            .buf = buf,
            .buf_mask = buf_size - 1,
            .enqueue_pos = atomic.Value(usize).init(0),
            .dequeue_pos = atomic.Value(usize).init(0),
        };
    }

    pub fn deinit(self: *MPMCQueue, allocator: Allocator) void {
        allocator.free(self.buf);
    }

    pub fn enqueue(self: *MPMCQueue, data: *anyopaque) !void {
        // var pos = self.enqueue_pos.load(Ordering.Relaxed);
        var enq_pos = self.enqueue_pos.load(.monotonic);
        var cell: *Cell = undefined;

        while (true) {
            cell = &self.buf[enq_pos & self.buf_mask];
            const seq = cell.seq.load(Ordering.acquire);
            if (enq_pos == seq) {
                // if (self.enqueue_pos.compareAndSwap(pos, pos + 1, Ordering.Relaxed, Ordering.Relaxed)) |_| {
                if (self.enqueue_pos.cmpxchgWeak(enq_pos, enq_pos + 1, .monotonic, .monotonic)) |_| {
                    break;
                }
            } else if (seq < enq_pos) {
                return error.QueueFull;
            } else {
                // pos = self.enqueue_pos.load(Ordering.Relaxed);
                enq_pos = self.enqueue_pos.load(.monotonic);
            }
        }
        // std.debug.print("Enqueue: pos={}, seq={}\n", .{ enq_pos, cell.seq.load(Ordering.acquire) });
        cell.data = data;
        cell.seq.store(enq_pos + 1, Ordering.release);
    }

    pub fn dequeue(self: *MPMCQueue) ?*anyopaque {
        // var pos = self.dequeue_pos.load(Ordering.Relaxed);
        var deq_pos = self.dequeue_pos.load(.seq_cst);
        var cell: *Cell = undefined;

        while (true) {
            cell = &self.buf[deq_pos & self.buf_mask];
            const seq = cell.seq.load(Ordering.acquire);

            if (seq == deq_pos + 1) {
                // if (self.dequeue_pos.compareAndSwap(pos, pos + 1, Ordering.Relaxed, Ordering.Relaxed)) |_| {
                if (self.dequeue_pos.cmpxchgWeak(deq_pos, deq_pos + 1, .monotonic, .monotonic)) |_| {
                    break;
                }
            } else if (seq < deq_pos + 1) {
                return null; // Queue is empty
            } else {
                // pos = self.dequeue_pos.load(Ordering.Relaxed);
                deq_pos = self.dequeue_pos.load(.monotonic);
            }
        }

        const data = cell.data;
        cell.data = null;
        // std.debug.print("Dequeue: pos={}, seq={}\n", .{ deq_pos, cell.seq.load(Ordering.acquire) });
        cell.seq.store(deq_pos + self.buf_mask + 1, .seq_cst);
        // cell.seq.store(deq_pos + self.buf.len, .seq_cst);
        return data;
    }
};

const Thread = std.Thread;

const thread_count = 4;
const batch_size = 2;
const iter_count = 2_000_000;

var g_start: atomic.Value(bool) = atomic.Value(bool).init(false);

fn threadfunc(q: *MPMCQueue) !void {
    var seed: u64 = undefined;
    try std.posix.getrandom(std.mem.asBytes(&seed));
    var randgen = std.Random.DefaultPrng.init(seed);
    const random = randgen.random();
    const pause = random.intRangeAtMost(usize, 0, 1000);

    while (!g_start.load(.acquire)) {
        try Thread.yield();
    }

    for (0..pause) |_| {
        std.atomic.spinLoopHint();
    }

    var item: usize = 0;
    for (0..iter_count) |_| {
        for (0..batch_size) |_| {
            while (q.enqueue(&item)) |_| {} else |_| {
                try Thread.yield();
            }
        }

        for (0..batch_size) |_| {
            while (q.dequeue()) |deq_item| {
                _ = deq_item;
            } else {
                try Thread.yield();
            }
        }
    }
}

fn mpmc_thread_test(allocator: Allocator) !void {
    var queue = try MPMCQueue.init(allocator, 1024);
    defer queue.deinit(allocator);

    var threads: [thread_count]Thread = undefined;
    for (&threads) |*t| {
        t.* = try Thread.spawn(.{}, threadfunc, .{&queue});
    }

    std.time.sleep(1_000_000_000); // Sleep for 1 second

    const start = std.time.microTimestamp();
    g_start.store(true, .release);

    for (&threads) |t| {
        t.join();
    }

    const end = std.time.microTimestamp();
    const delta = end - start;

    std.log.warn("Time taken: {d} micro secs", .{delta});
    std.log.warn("Cycles per operation: {d}", .{@divTrunc(delta, (batch_size * iter_count * 2 * thread_count))});
}

fn mpmc_test(allocator: Allocator) !void {
    var queue = try MPMCQueue.init(allocator, 1024);
    defer queue.deinit(allocator);

    var data: usize = 1337;
    try queue.enqueue(&data);

    const dequeued = queue.dequeue() orelse {
        std.log.warn("Test failed: queue returned null", .{});
        return error.TestFailed;
    };

    if (@as(*usize, @alignCast(@ptrCast(dequeued))).* == data) {
        std.log.warn("Test passed: enqueue and dequeue work correctly.", .{});
    } else {
        std.log.warn("Test failed: dequeued value mismatch", .{});
        return error.TestFailed;
    }
}

test "test cmpmc" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    const alloc = gpa.allocator();
    // const alloc = std.testing.allocator;
    try mpmc_thread_test(alloc);
    try mpmc_test(alloc);
}

pub fn TypedSharedMPSC(T: type) type {
    return struct {
        const This = @This();
        inner: *MPMCQueue,
        pub fn init(alloc: Allocator, capacity: usize) !This {
            const mpmc = try alloc.create(MPMCQueue);
            mpmc.* = try MPMCQueue.init(alloc, capacity);
            return This{
                .inner = mpmc,
            };
        }
        pub fn deinit(self: *This, alloc: Allocator) void {
            self.deinit(alloc);
            alloc.destroy(self.inner);
        }
        pub fn push(self: *This, data: *T) !void {
            try self.inner.enqueue(data);
        }
        pub fn pop(self: *This) ?*T {
            const res = self.inner.dequeue() orelse return null;
            const cast_ptr: *T = @alignCast(@ptrCast(res));
            return cast_ptr;
        }
    };
}

// // TODO: test is wrong overwrites heap while pushing so pop could read new value
test "test typed shared mpsc" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    const alloc = gpa.allocator();
    const AtomicU64 = atomic.Value(u64);
    // const alloc = std.testing.allocator;
    const T = u64;
    const MPSC = TypedSharedMPSC(T);
    var xthread_counter = AtomicU64.init(0);
    const ResetEvent = std.Thread.ResetEvent;
    var reset_start: ResetEvent = undefined;
    reset_start.reset();
    var xmpsc = try MPSC.init(alloc, 1024);
    var xheap_storage = try alloc.alloc(T, thread_count * batch_size);
    defer alloc.free(xheap_storage);
    const thread_count_u64 = @as(u64, @intCast(thread_count));
    const TStack = struct {
        pub fn f_enque(
            th_counter: *AtomicU64,
            thread_idx: usize,
            res_start: *ResetEvent,
            mpsc: *MPSC,
            heap_storage: []T,
            // xalloc: Allocator,
        ) !void {
            // const heap_storage = try xalloc.create(T);
            _ = th_counter.fetchAdd(1, .seq_cst);
            res_start.wait();
            for (0..batch_size) |i| {
                const data = std.math.pow(usize, 10, thread_idx) + i;
                @atomicStore(usize, &heap_storage[i], data, .seq_cst);
                // heap_storage.* = data;
                try mpsc.push(&heap_storage[i]);
                // std.log.warn("enqued {}", .{data});
                std.log.warn("enq/{}", .{&heap_storage[i]});
            }
            _ = th_counter.fetchSub(1, .seq_cst);
        }
        pub fn f_deque(
            th_counter: *AtomicU64,
            res_start: *ResetEvent,
            mpsc: *MPSC,
        ) !void {
            _ = th_counter.fetchAdd(1, .seq_cst);
            res_start.wait();
            var t = std.time.Timer.start() catch unreachable;
            var finish = false;
            var finish_ns: u64 = 1e6;
            while (true) {
                const data = mpsc.pop();
                if (data) |d| {
                    const ld = @atomicLoad(usize, d, .seq_cst);
                    // std.log.warn("pop: {}", .{ld});
                    std.log.warn("pop ptr: {}", .{d});
                    _ = ld;
                }
                if (th_counter.load(.monotonic) <= thread_count_u64) {
                    finish = true;
                    t.reset();
                }
                if (finish) finish_ns = std.math.sub(u64, finish_ns, t.lap()) catch 0;
                if (finish_ns == 0) break;
            }
            _ = th_counter.fetchSub(1, .seq_cst);
        }
    };
    for (0..thread_count) |i| {
        var h = try std.Thread.spawn(
            .{ .allocator = alloc },
            TStack.f_enque,
            .{
                &xthread_counter,
                i,
                &reset_start,
                &xmpsc,
                xheap_storage[i * batch_size .. (i + 1) * batch_size],
                // alloc,
            },
        );
        h.detach();
        var h2 = try std.Thread.spawn(
            .{ .allocator = alloc },
            TStack.f_deque,
            .{
                &xthread_counter,
                &reset_start,
                &xmpsc,
            },
        );
        h2.detach();
    }
    while (xthread_counter.load(.monotonic) != 2 * thread_count_u64) {}
    reset_start.set();
    while (xthread_counter.load(.monotonic) != 0) {}
    std.log.warn("heap data {any}", .{xheap_storage});
}

test "sanity test" {
    var gpa = std.heap.DebugAllocator(.{}).init;
    const alloc = gpa.allocator();
    const AtomicU64 = atomic.Value(u64);
    // const alloc = std.testing.allocator;
    const T = u64;
    var xthread_counter = AtomicU64.init(0);
    const ResetEvent = std.Thread.ResetEvent;
    var reset_start: ResetEvent = undefined;
    reset_start.reset();
    var xheap_storage = try alloc.alloc(T, thread_count * batch_size);
    for (xheap_storage) |*x| x.* = 7;
    // std.debug.print("xheapstorage : {any}", .{xheap_storage});
    defer alloc.free(xheap_storage);
    const thread_count_u64 = @as(u64, @intCast(thread_count));
    const TStack = struct {
        pub fn f_enque(
            th_counter: *AtomicU64,
            thread_idx: usize,
            res_start: *ResetEvent,
            heap_storage: []T,
            // xalloc: Allocator,
        ) !void {
            // const heap_storage = try xalloc.create(T);
            _ = th_counter.fetchAdd(1, .seq_cst);
            res_start.wait();
            for (0..batch_size) |i| {
                const data = thread_idx * batch_size + i;
                // @atomicStore(usize, &heap_storage[i], data, .unordered);
                heap_storage[i] = data;
            }
            _ = th_counter.fetchSub(1, .seq_cst);
        }
        pub fn f_deque(
            th_counter: *AtomicU64,
            res_start: *ResetEvent,
            mpsc: []T,
        ) !void {
            var seed: u64 = undefined;
            try std.posix.getrandom(std.mem.asBytes(&seed));
            var randgen = std.Random.DefaultPrng.init(seed);
            const random = randgen.random();
            _ = th_counter.fetchAdd(1, .seq_cst);

            res_start.wait();
            while (true) {
                std.debug.assert(thread_count >= 1 and batch_size >= 1);
                const idx = random.intRangeAtMost(usize, 0, batch_size * thread_count - 1);
                const d = &mpsc[idx];
                const ldo = @atomicLoad(usize, d, .unordered);
                _ = ldo;
                if (th_counter.load(.monotonic) <= thread_count_u64) break;
            }
            _ = th_counter.fetchSub(1, .seq_cst);
        }
    };
    for (0..thread_count) |i| {
        var h = try std.Thread.spawn(
            .{ .allocator = alloc },
            TStack.f_enque,
            .{
                &xthread_counter,
                i,
                &reset_start,
                xheap_storage[i * batch_size .. (i + 1) * batch_size],
            },
        );
        h.detach();
        var h2 = try std.Thread.spawn(
            .{ .allocator = alloc },
            TStack.f_deque,
            .{
                &xthread_counter,
                &reset_start,
                xheap_storage,
            },
        );
        h2.detach();
    }
    while (xthread_counter.load(.monotonic) != 2 * thread_count_u64) {}
    reset_start.set();
    while (xthread_counter.load(.monotonic) != 0) {}
    for (xheap_storage, 0..) |x, i| try std.testing.expect(x == i);
    // std.debug.print("xheapstorage : {any}", .{xheap_storage});
}
