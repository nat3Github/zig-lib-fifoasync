const std = @import("std");
const builtin = @import("builtin");
const print = std.debug.print;
const time = std.time;
const os = std.os;
const root = @import("fifoasync");

const Timer = root.thread.Timer;

fn benchmark_rt_timer() !void {
    var rt_timer = try Timer.init();
    defer rt_timer.deinit();

    print("Running RtTimer sleep precision benchmark...\n", .{});
    print("Target interval: {d} us\n", .{@as(f64, target_interval_ns) / 1_000.0});
    print("Number of measurements: {d}\n\n", .{sleep_num_measurements});

    var max_deviation_ns: i128 = 0;
    var total_elapsed_ns: i128 = 0;

    var previous_timestamp = time.nanoTimestamp();

    for (0..sleep_num_measurements) |_| {
        // Sleep for the target interval
        rt_timer.rt_sleep(target_interval_ns);

        // Measure actual elapsed time since the previous iteration
        const current_timestamp = time.nanoTimestamp();
        const actual_elapsed_ns = current_timestamp - previous_timestamp;
        previous_timestamp = current_timestamp; // Update for the next iteration

        total_elapsed_ns += actual_elapsed_ns;

        // Calculate deviation
        const deviation_ns = actual_elapsed_ns - target_interval_ns;
        if (@abs(deviation_ns) > @abs(max_deviation_ns)) {
            max_deviation_ns = deviation_ns;
        }
    }

    const average_elapsed_ns = @divTrunc(total_elapsed_ns, sleep_num_measurements);
    const average_deviation_ns = average_elapsed_ns - target_interval_ns;

    print("Benchmark Results:\n", .{});
    print("  Average elapsed time per sleep: {d:.3} us\n", .{@as(f64, @floatFromInt(average_elapsed_ns)) / 1_000.0});
    print("  Average deviation: {d:.3} us\n", .{@as(f64, @floatFromInt(average_deviation_ns)) / 1_000.0});
    print("  Maximum deviation from target: {d:.3} us\n", .{@as(f64, @floatFromInt(max_deviation_ns)) / 1_000.0});
}
fn benchmark_timer() !void {
    var rt_timer: std.Thread.ResetEvent = .{};
    rt_timer.reset();
    print("Running std.Timer sleep precision benchmark...\n", .{});
    print("Target interval: {d} us\n", .{@as(f64, target_interval_ns) / 1_000.0});
    print("Number of measurements: {d}\n\n", .{sleep_num_measurements});

    var max_deviation_ns: i128 = 0;
    var total_elapsed_ns: i128 = 0;

    var previous_timestamp = time.nanoTimestamp();

    for (0..sleep_num_measurements) |_| {
        // Sleep for the target interval
        // rt_timer.timedWait(target_interval_ns) catch {};
        // rt_timer.reset();
        std.Thread.sleep(target_interval_ns);

        // Measure actual elapsed time since the previous iteration
        const current_timestamp = time.nanoTimestamp();
        const actual_elapsed_ns = current_timestamp - previous_timestamp;
        previous_timestamp = current_timestamp; // Update for the next iteration

        total_elapsed_ns += actual_elapsed_ns;

        // Calculate deviation
        const deviation_ns = actual_elapsed_ns - target_interval_ns;
        if (@abs(deviation_ns) > @abs(max_deviation_ns)) {
            max_deviation_ns = deviation_ns;
        }
    }

    const average_elapsed_ns = @divTrunc(total_elapsed_ns, sleep_num_measurements);
    const average_deviation_ns = average_elapsed_ns - target_interval_ns;

    print("Benchmark Results:\n", .{});
    print("  Average elapsed time per sleep: {d:.3} us\n", .{@as(f64, @floatFromInt(average_elapsed_ns)) / 1_000.0});
    print("  Average deviation: {d:.3} us\n", .{@as(f64, @floatFromInt(average_deviation_ns)) / 1_000.0});
    print("  Maximum deviation from target: {d:.3} us\n", .{@as(f64, @floatFromInt(max_deviation_ns)) / 1_000.0});
}
const sleep_num_measurements = 20_000;
const target_interval_ns: u64 = 5 * 100_000; // 100 microseconds
test "sleep" {
    if (true) return;
    // try root.thread.prio.set_realtime_critical_highest();
    const alloc = std.testing.allocator;
    var fib = try root.util.fibonacci.start(alloc);
    defer fib.stop();
    try benchmark_rt_timer();
    try benchmark_timer();
}

const reset_num_measurements = 1_000;
test "reset event" {
    const alloc = std.testing.allocator;
    // var fib = try root.util.fibonacci.start(alloc);
    // defer fib.stop();
    try benchmark_reset_event(alloc);
}
const Abool = root.util.atomic.AcqRelAtomic(bool);

fn benchmark_reset_event_bgthread(running: *Abool, b: *Abool, re: *std.Thread.ResetEvent) void {
    while (running.load()) {
        re.reset();
        b.store(true);
        re.wait();
    }
}

fn benchmark_reset_event(alloc: std.mem.Allocator) !void {
    var rt_timer = try Timer.init();
    defer rt_timer.deinit();

    print("Running ResetEvent benchmark...\n", .{});
    print("Number of measurements: {d}\n\n", .{reset_num_measurements});

    var max_deviation_ns: i128 = 0;
    var total_elapsed_ns: i128 = 0;

    var re = std.Thread.ResetEvent{};
    re.reset();

    var ready = Abool.init(false);

    var previous_timestamp = time.nanoTimestamp();
    var running: Abool = .init(true);
    const handle = try std.Thread.spawn(.{ .allocator = alloc }, benchmark_reset_event_bgthread, .{ &running, &ready, &re });

    var timer = std.time.Timer.start() catch unreachable;

    for (0..reset_num_measurements) |_| {
        // Sleep for the target interval
        while (!ready.load()) {}
        ready.store(false);
        rt_timer.rt_sleep(8 * 1000 * 1000);
        // previous_timestamp = time.nanoTimestamp();
        timer.reset();
        re.set();
        const current_timestamp = time.nanoTimestamp();
        const actual_elapsed_ns: i128 = @intCast(timer.read());
        previous_timestamp = current_timestamp; // Update for the next iteration

        total_elapsed_ns += actual_elapsed_ns;
        if (@abs(actual_elapsed_ns) > @abs(max_deviation_ns)) {
            max_deviation_ns = actual_elapsed_ns;
        }
    }
    running.store(false);
    re.set();
    handle.join();

    const average_elapsed_ns = @divTrunc(total_elapsed_ns, reset_num_measurements);

    print("Benchmark Results:\n", .{});
    print("  Average elapsed time per sleep: {d:.3} us\n", .{@as(f64, @floatFromInt(average_elapsed_ns)) / 1_000.0});
    print("  Maximum deviation from target: {d:.3} us\n", .{@as(f64, @floatFromInt(max_deviation_ns)) / 1_000.0});
}
