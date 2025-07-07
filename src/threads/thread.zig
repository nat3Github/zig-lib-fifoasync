const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const root = @import("../root.zig");
const atomic = root.util.atomic;
const Atomic = atomic.AcqRelAtomic;

const ResetEvent = std.Thread.ResetEvent;
pub const prio = @import("thread_prio.zig");
test "prio" {
    _ = prio;
}

pub const Signal = enum(u8) {
    const default: Signal = .unitialized;
    unitialized = 0,
    running = 1,
    stop_signal = 2,
    stopped = 3,

    pub fn has_started(self: Signal) bool {
        return @intFromEnum(self) >= @intFromEnum(Signal.running);
    }
};

pub const ThreadStatus = struct {
    thread_sets_handle_waits: *ResetEvent,
    handle_sets_thread_waits: *ResetEvent,
    signal: *Atomic(Signal),
    pub fn wakeup(self: *const ThreadStatus) void {
        self.thread_sets_handle_waits.set();
    }
    pub fn reset(self: *const ThreadStatus) void {
        self.handle_sets_thread_waits.reset();
    }
    pub fn wait(self: *const ThreadStatus, time_out_ns: u64) !void {
        const signal = self.signal.load();
        if (signal == .stop_signal) return;
        try self.handle_sets_thread_waits.timedWait(time_out_ns);
    }
};
pub const ThreadControl = struct {
    thread_sets_handle_waits: ResetEvent = .{},
    handle_sets_thread_waits: ResetEvent = .{},
    signal: Atomic(Signal) = .init(.default),
    handle: ?std.Thread = null,
    debug_name: []const u8 = &.{},
    pub fn spinwait_for_startup(self: *const ThreadControl) void {
        while (!self.signal.load().has_started()) {}
    }
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
        if (self.handle == null) return;
        self.spinwait_for_startup();
        self.set_stop_signal();
        self.wakeup();
        self.handle.?.join();
        alloc.free(self.debug_name);
        self.debug_name = &.{};
        self.handle = null;
    }
    /// NOTE: only stopp the thread if its started (thread function may run some cleanup logic thats get skipped otherwise)
    inline fn set_stop_signal(self: *ThreadControl) void {
        if (self.signal.load() == .stopped) return;
        self.signal.store(.stop_signal);
    }
    /// Abstracts stopping threads, gives you waiting / waking with two reset events via the Control parameter (first parameter in function must be type ThreadStatus)
    /// use the ThreadStaus in the your function to check if stop was signaled!
    /// NOTE: all resources used by the thread must be valid for the lifetime of the thread!
    pub fn spawn(self: *ThreadControl, alloc: Allocator, comptime debug_name_fmt: []const u8, debug_name_args: anytype, function: anytype, args: anytype) !void {
        assert(self.handle == null);
        const name = try std.fmt.allocPrint(alloc, debug_name_fmt, debug_name_args);
        errdefer alloc.free(name);
        const m = struct {
            fn startup(th_status: ThreadStatus, dbg_name: []const u8, fnc: anytype, xargs: anytype) void {
                th_status.signal.store(.running);
                _ = @call(.auto, fnc, .{th_status} ++ xargs) catch |e| {
                    std.log.err("{s}: {}", .{ dbg_name, e });
                };
                std.log.info("{s} Thread is terminating...", .{dbg_name});
                th_status.signal.store(.stopped);
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
            .{ status, name, function, args },
        );
        self.debug_name = name;
        self.handle = th;
    }
};
