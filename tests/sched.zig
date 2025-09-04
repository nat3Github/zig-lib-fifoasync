const std = @import("std");
const fifoasync = @import("fifoasync");

const DefaultSched = fifoasync.sched.DefaultSched;
const HybridSched = fifoasync.sched.HybridSched;
const RealtimeSched = fifoasync.sched.RealtimeSched;
const Task = fifoasync.sched.Task;
const AsyncExecutor = fifoasync.sched.AsyncExecutor;
const AsFn = fifoasync.sched.ASFunction;

pub fn negate(b: *anyopaque, _: AsyncExecutor) void {
    const bp: *bool = @alignCast(@ptrCast(b));
    bp.* = !bp.*;
}

pub fn negate2(as: AsyncExecutor, bp: *bool) !void {
    try as.yield();
    bp.* = !bp.*;
}

pub fn negate3(bp: *bool) void {
    bp.* = !bp.*;
}

fn test_as_exe(as_exe: AsyncExecutor) !void {
    var b = false;
    const task = Task{
        .data = @ptrCast(&b),
        .task_fn = negate,
    };
    try as_exe.execute(task);
    std.Thread.sleep(1_000_000);
    try std.testing.expect(b);
}

fn test_as_exe2(as_exe: AsyncExecutor) !void {
    var b = false;
    var task: AsFn(negate2) = .{};
    try task.call(as_exe, .{&b});
    task.join();
    try std.testing.expect(b);
}

fn test_as_exe3(as_exe: AsyncExecutor) !void {
    var b = false;
    var task: AsFn(negate3) = .{};
    try task.call(as_exe, .{&b});
    task.join();
    try std.testing.expect(b);
}
fn test_all(as_exe: AsyncExecutor) !void {
    try test_as_exe(as_exe);
    try test_as_exe2(as_exe);
    try test_as_exe3(as_exe);
}

test "sched gp" {
    const alloc = std.testing.allocator;
    var sched = DefaultSched{};
    try sched.init(alloc, .{
        .N_queue_capacity = 1024,
        .N_threads = 4,
    });
    defer sched.deinit(alloc);
    try test_all(sched.async_executor());
}

test "sched rt" {
    const alloc = std.testing.allocator;
    var sched = RealtimeSched{};
    try sched.init(alloc, .{
        .N_queue_capacity = 1024,
        .N_threads = 4,
    });
    defer sched.deinit(alloc);
    try test_all(sched.async_executor());
}

test "sched hybrid" {
    const alloc = std.testing.allocator;
    var sched = HybridSched{};
    try sched.init(alloc, .{
        .N_queue_capacity = 1024,
        .N_threads = 4,
        .sleep_ns = 250_000,
    });
    defer sched.deinit(alloc);
    try test_all(sched.async_executor());
}
