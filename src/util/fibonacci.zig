const std = @import("std");
const root = @import("../root.zig");

pub const Fibonacci = @This();
const List = std.ArrayList(root.thread.ThreadControl);
const Au64 = std.atomic.Value(u64);
threads: List,
counter: *Au64,
pub fn start(alloc: std.mem.Allocator) !Fibonacci {
    return startEx(alloc, 2 * (std.Thread.getCpuCount() catch 16));
}
pub fn startEx(alloc: std.mem.Allocator, threads: usize) !Fibonacci {
    const at = try alloc.create(Au64);
    errdefer alloc.destroy(at);
    at.* = .init(0);
    var self = Fibonacci{
        .threads = .init(alloc),
        .counter = at,
    };
    try self.threads.ensureTotalCapacity(threads);
    for (0..threads) |_| {
        const tc = root.thread.ThreadControl{};
        self.threads.append(tc) catch unreachable;
    }
    for (self.threads.items, 0..) |*tk, i| {
        try tk.spawn(alloc, "fibonacci thread {}", .{i}, fib_load, .{self.counter});
        tk.spinwait_for_startup();
    }
    return self;
}
pub fn stop(self: *Fibonacci) void {
    std.debug.print("calculated {} fibonaccis\n", .{self.counter.load(.seq_cst)});
    const alloc = self.threads.allocator;
    for (self.threads.items) |*tk| {
        tk.join(alloc);
    }
    self.threads.deinit();
    alloc.destroy(self.counter);
}
fn fib_load(th_status: root.thread.ThreadStatus, c: *std.atomic.Value(u64)) !void {
    const fibs = struct {
        pub fn fibonacci(comptime T: type) fn (T) T {
            return struct {
                pub fn fib(n: T) T {
                    return switch (n) {
                        0...1 => n,
                        else => fib(n - 1) + fib(n - 2),
                    };
                }
            }.fib;
        }
    };
    while (th_status.signal.load() == .running) {
        _ = fibs.fibonacci(u64)(20);
        _ = c.fetchAdd(1, .seq_cst);
    }
}
