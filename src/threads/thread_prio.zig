const std = @import("std");
const assert = std.debug.assert;
const c = @cImport(@cInclude("macOS/pthread/pthread.h"));
const win32 = @import("win32");
const builtin = @import("builtin");
const Pool = @import("pool.zig");

test "set thread prio" {
    try set_realtime_critical_highest();
    // try pthread.set_prio(.Fifo, 0.5);
    // const current_info = try pthread.get_thread_scheduling(try pthread.get_current_thread());
    // std.log.warn("policy is now: {s} prio is now: {}", .{ current_info.policy.get_str(), current_info.priority });
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const pool = try alloc.create(Pool);
    try Pool.init(pool, .{ .allocator = gpa, .n_jobs = 2, .spawn_fn = .time_critical });
    defer pool.deinit();

    for (0..10) |_| {
        var xt = std.time.Timer.start() catch unreachable;
        try pool.spawn(my_thread, .{
            std.time.Timer.start() catch unreachable,
        });
        const t = xt.read();
        const f: f64 = @floatFromInt(t);
        std.debug.print("time elapsed: *{d:.3} ms\n", .{f / 1_000_000.0});
        std.Thread.sleep(100 * 1_000_000);
    }
}

fn my_thread(time: std.time.Timer) void {
    var xt = time;
    const t = xt.read();
    const f: f64 = @floatFromInt(t);
    // _ = f;
    std.debug.print("time elapsed: {d:.3} ms\n", .{f / 1_000_000.0});
}
fn supports_pthread() bool {
    const linux = builtin.target.os.tag == .linux;
    const macos = builtin.target.os.tag == .macos;
    const freebsd = builtin.target.os.tag == .freebsd;
    return linux or macos or freebsd;
}

pub fn set_realtime_critical_highest() !void {
    if (supports_pthread()) {
        try pthread.set_prio(.Fifo, 0.9);
    } else if (builtin.target.os.tag == .windows) {
        try win32thread.set_thread_prio(.PRIORITY_TIME_CRITICAL);
    }
}
pub fn set_realtime_critical_high() !void {
    if (supports_pthread()) {
        try pthread.set_prio(.RR, 0.7);
    } else if (builtin.target.os.tag == .windows) {
        try win32thread.set_thread_prio(.PRIORITY_HIGHEST);
    }
}

const win32thread = struct {
    const threading = win32.system.threading;
    pub const ThreadPrio = struct {};
    pub fn get_current_thread() !*anyopaque {
        const h = threading.GetCurrentThread() orelse return error.ThreadHandleIsNull;
        return h;
    }
    pub fn get_thread_prio() !threading.THREAD_PRIORITY {
        const prio = threading.GetThreadPriority(try get_current_thread());
        return try std.meta.intToEnum(threading.THREAD_PRIORITY, prio);
    }
    pub fn set_thread_prio(prio: threading.THREAD_PRIORITY) !void {
        const success = threading.SetThreadPriority(try get_current_thread(), prio);
        if (success == 0) return error.FailedToSethThreadPriority;
    }
};

/// NOTE: SCHED_FIFO is better suited for a RT-schedular than SCHED_RR because it has no time quantum after it gets preempted. preemption is bad because a task could be left unfinished when preempted
/// SCHED_DEADLINE maybe useable but only on linux ...
pub const pthread = struct {
    /// prio 1.0 highest 0.0 lowest
    pub fn set_prio(policy: SchedPolicy, prio: f32) !void {
        assert(prio >= 0.0 and prio <= 1.0);
        const max: c_int = get_priority_max(policy);
        const min: c_int = get_priority_min(policy);
        const maxf: f32 = @floatFromInt(max);
        const minf: f32 = @floatFromInt(min);
        const delta = maxf - minf;
        const val = std.math.clamp(minf + delta * prio, @min(maxf, minf), @max(maxf, minf));
        const cprio: c_int = @intFromFloat(val);
        const self_thread = try get_current_thread();
        try set_thread_scheduling(self_thread, policy, cprio);
    }

    pub const SchedPolicy = struct {
        pub const Other = SchedPolicy{ .policy = c.SCHED_OTHER };
        pub const Fifo = SchedPolicy{ .policy = c.SCHED_FIFO };
        pub const RR = SchedPolicy{ .policy = c.SCHED_RR };
        policy: c_int,
        pub fn get_str(Self: SchedPolicy) []const u8 {
            if (Self.policy == c.SCHED_FIFO) return "FIFO";
            if (Self.policy == c.SCHED_RR) return "RR";
            if (Self.policy == c.SCHED_OTHER) return "OTHER";
            return "ERROR";
        }
    };

    pub fn get_priority_min(Self: SchedPolicy) c_int {
        return c.sched_get_priority_min(Self.policy);
    }
    pub fn get_priority_max(Self: SchedPolicy) c_int {
        return c.sched_get_priority_max(Self.policy);
    }

    pub fn get_current_thread() !c.pthread_t {
        var self_thread: c.pthread_t = undefined;
        self_thread = c.pthread_self();
        return self_thread;
    }

    pub fn get_thread_scheduling(self_thread: c.pthread_t) !struct {
        policy: SchedPolicy,
        priority: c_int,
    } {
        var current_policy: c_int = undefined;
        var current_param: c.sched_param = undefined; // To store the priority after setting
        const get_result = c.pthread_getschedparam(self_thread, &current_policy, &current_param);
        if (get_result != 0) return error.FailedFetchingThreadPolicy;
        return .{
            .policy = SchedPolicy{ .policy = current_policy },
            .priority = current_param.sched_priority,
        };
    }

    pub fn set_thread_scheduling(self_thread: c.pthread_t, policy: SchedPolicy, prio: c_int) !void {
        var new_param: c.sched_param = .{ .sched_priority = prio };
        const set_result = c.pthread_setschedparam(self_thread, policy.policy, &new_param);
        if (set_result != 0) return error.FailedSettingThreadPolicy;
    }
};
