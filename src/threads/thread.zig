const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const root = @import("../root.zig");
const atomic = root.util.atomic;
const Atomic = atomic.AcqRelAtomic;

const ResetEvent = std.Thread.ResetEvent;
pub const prio = @import("thread_prio.zig");
const sleep = @import("timer.zig");
pub const Timer = sleep.Timer;
pub const context = @import("context.zig");

test "prio" {
    _ = prio;
    _ = context;
    _ = sleep;
}

pub const Signal = struct {
    pub const Signal_ = enum(u8) {
        const default: Signal_ = .unitialized;
        unitialized = 0,
        running = 1,
        stop_sig = 2,
        stop_ack = 3,
        stopped = 4,
        pub fn has_started(self: Signal_) bool {
            return @intFromEnum(self) >= @intFromEnum(Signal_.running);
        }
    };
    raw: Atomic(Signal_) = .init(.unitialized),
    pub fn has_started(self: *const Signal) bool {
        return self.raw.load().has_started();
    }
    pub fn is_stop_signal(self: *Signal) bool {
        const res = self.raw.load();
        if (res == .stop_sig) self.raw.store(Signal_.stop_ack);
        return @intFromEnum(res) >= @intFromEnum(Signal_.stop_sig);
    }
    pub fn is_running(self: *Signal) bool {
        return !self.is_stop_signal();
    }
    fn set_stop_signal(self: *Signal) void {
        if (self.raw.load() == .stopped) return;
        self.raw.store(.stop_sig);
    }
    fn is_ack_or_stopped(self: *Signal) bool {
        return @intFromEnum(self.raw.load()) >= @intFromEnum(Signal_.stop_ack);
    }
    fn set_started(self: *Signal) void {
        self.raw.store(.running);
    }
};
pub const StopError = error{
    ThreadTerminated,
};

/// - gets passed to function spawned with ThreadControl
/// - fn should check signal for the stop signal and terminate accordingly
/// - fn can wait for wakeup
/// - fn can wakeup a waiting thread
pub const ThreadStatus = struct {
    thread_sets_handle_waits: *ResetEvent,
    handle_sets_thread_waits: *ResetEvent,
    signal: *Signal,
    pub fn wakeup(self: *const ThreadStatus) void {
        self.thread_sets_handle_waits.set();
    }
    pub fn reset(self: *const ThreadStatus) void {
        self.handle_sets_thread_waits.reset();
    }
    const WaitError = error{Timeout} || StopError;
    pub fn wait(self: *const ThreadStatus, time_out_ns: u64) WaitError!void {
        try self.check_stop_signal();
        try self.handle_sets_thread_waits.timedWait(time_out_ns);
    }
    pub fn check_stop_signal(self: *const ThreadStatus) StopError!void {
        if (self.signal.is_stop_signal()) return StopError.ThreadTerminated;
    }
};
/// - spawn a thread
/// - join a thread
/// - running fn can decide to wait for wakeup call from ThreadControl
/// - you can wait till the running fn wakes you up
pub const ThreadControl = struct {
    pub const Status = ThreadStatus;
    thread_sets_handle_waits: ResetEvent = .{},
    handle_sets_thread_waits: ResetEvent = .{},
    start_stop_event: ResetEvent = .{},
    signal: Signal = .{},
    handle: ?std.Thread = null,
    debug_name: []const u8 = &.{},

    pub fn wakeup(self: *ThreadControl) void {
        self.handle_sets_thread_waits.set();
    }
    pub fn reset(self: *ThreadControl) void {
        self.thread_sets_handle_waits.reset();
    }
    pub fn wait(self: *ThreadControl, time_out_ns: u64) !void {
        try self.thread_sets_handle_waits.timedWait(time_out_ns);
    }

    pub fn join(self: *ThreadControl, alloc: Allocator) void {
        if (self.handle == null) @panic("");
        self.signal.set_stop_signal();
        self.wakeup();
        // routine that makes sure the thread is not stalling and properly exiting
        // stage one waiting for ACK
        // const max_usize = std.math.maxInt(usize);
        // const start_ns = 50_000;
        // for (0..max_usize) |i| {
        //     if (self.signal.is_ack_or_stopped()) break;
        //     const exp_limit = 300_000_000;
        //     const t_sleep_ns = std.math.powi(usize, start_ns, i + 1) catch unreachable;
        //     self.start_stop_event.timedWait(t_sleep_ns) catch {};
        //     self.wakeup();
        //     if (t_sleep_ns >= exp_limit) break;
        // }
        // std.log.err("{s}: After Wakeup did not Acknowledge Stop signal", .{self.debug_name});
        // for (0..max_usize) |i| {
        //     if (self.signal.raw.load() == .stopped) break;
        //     const exp_limit = 5_000_000_000;
        //     const t_sleep_ns = std.math.powi(usize, start_ns, i + 1) catch unreachable;
        //     std.Thread.sleep(t_sleep_ns);
        //     if (t_sleep_ns >= exp_limit) {
        //         std.log.err("Thread {s} failed to finish after receiving a stop signal", .{self.debug_name});
        //         break;
        //     }
        // }
        std.log.info("joining \"{s}\"", .{self.debug_name});
        self.handle.?.join();
        std.log.info("sucessfully joined \"{s}\"", .{self.debug_name});
        alloc.free(self.debug_name);
        self.debug_name = &.{};
        self.handle = null;
    }
    /// Abstracts stopping threads, gives you waiting / waking with two reset events via the Control parameter (first parameter in function must be type ThreadStatus)
    /// use the ThreadStatus in the your function to check if stop was signaled!
    /// NOTE: all resources used by the thread must be valid for the lifetime of the thread!
    /// example for the function signature: pub fn thread(status: TC.Status, self: *@This()) anyerror!void {}
    pub fn spawn(self: *ThreadControl, alloc: Allocator, comptime debug_name_fmt: []const u8, debug_name_args: anytype, function: anytype, args: anytype) !void {
        self.* = .{};
        self.start_stop_event.reset();
        const name = try std.fmt.allocPrint(alloc, debug_name_fmt, debug_name_args);
        errdefer alloc.free(name);
        const m = struct {
            fn startup(th_status: ThreadStatus, start_stop: *ResetEvent, dbg_name: []const u8, fnc: anytype, xargs: anytype) void {
                th_status.signal.set_started();
                start_stop.set();
                _ = @call(.auto, fnc, .{th_status} ++ xargs) catch |e| {
                    switch (e) {
                        StopError.ThreadTerminated => {},
                        else => {
                            std.log.err("{s}: {}", .{ dbg_name, e });
                        },
                    }
                };
                std.log.info("{s} is terminating...", .{dbg_name});
                th_status.signal.raw.store(.stopped);
            }
        };
        const status = ThreadStatus{
            .handle_sets_thread_waits = &self.handle_sets_thread_waits,
            .thread_sets_handle_waits = &self.thread_sets_handle_waits,
            .signal = &self.signal,
        };
        const th = try std.Thread.spawn(
            .{ .allocator = alloc },
            m.startup,
            .{ status, &self.start_stop_event, name, function, args },
        );
        self.debug_name = name;
        self.handle = th;
    }
};
