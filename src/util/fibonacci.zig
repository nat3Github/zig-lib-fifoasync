const std = @import("std");
const root = @import("../root.zig");

pub const Fibonacci = @This();
const List = std.ArrayList(root.thread.ThreadControl);
const Au64 = std.atomic.Value(u64);
threads: List = .{},
counter: Au64 = .init(0),
alloc: std.mem.Allocator = undefined,
fn init(self: *Fibonacci, alloc: std.mem.Allocator) !void {
    self.* = .{};
    self.alloc = alloc;
}

fn deinit(self: *Fibonacci, alloc: std.mem.Allocator) void {
    self.threads.deinit(alloc);
}

pub fn start(self: *Fibonacci, alloc: std.mem.Allocator) !void {
    try self.startEx(alloc, 2 * (std.Thread.getCpuCount() catch 16));
}
pub fn startEx(self: *Fibonacci, alloc: std.mem.Allocator, threads: usize) !void {
    try self.init(alloc);
    try self.threads.ensureTotalCapacity(self.alloc, threads);
    for (0..threads) |_| {
        const tc = root.thread.ThreadControl{};
        self.threads.appendAssumeCapacity(tc);
    }
    for (self.threads.items, 0..) |*tk, i| {
        try tk.spawn(alloc, "fibonacci thread {}", .{i}, fib_load, .{&self.counter});
        tk.spinwait_for_startup();
    }
}
pub fn stop(self: *Fibonacci) void {
    std.debug.print("calculated {} fibonaccis\n", .{self.counter.load(.seq_cst)});
    const alloc = self.alloc;
    for (self.threads.items) |*tk| {
        tk.join(alloc);
    }
    self.deinit(alloc);
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
