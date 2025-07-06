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
    stop_event: *ResetEvent,
    pub fn wakeup(self: *const ThreadStatus) void {
        self.thread_sets_handle_waits.set();
    }
    pub fn reset(self: *const ThreadStatus) void {
        self.handle_sets_thread_waits.reset();
    }
    pub fn wait(self: *const ThreadStatus, time_out_ns: u64) !void {
        try self.handle_sets_thread_waits.timedWait(time_out_ns);
    }
};
pub const ThreadControl = struct {
    stop_event: ResetEvent = .{},
    thread_sets_handle_waits: ResetEvent = .{},
    handle_sets_thread_waits: ResetEvent = .{},
    signal: Atomic(Signal) = .init(.default),
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
    pub fn shutdown(self: *ThreadControl, alloc: Allocator) void {
        self.spinwait_for_startup();
        self.set_stop_signal();
        self.stop_or_timeout(1 * 1_000_000_000) catch {
            std.log.err("shutdown failed thread function did not return", .{});
            @panic("shutdown failed thread function did not return");
        };
        self.deinit(alloc);
    }
    /// NOTE: only stopp the thread if its started (thread function may run some cleanup logic thats get skipped otherwise)
    pub fn set_stop_signal(self: *ThreadControl) void {
        if (self.signal.load() == .stopped) return;
        self.signal.store(.stop_signal);
    }
    /// NOTE: only stopp the thread if its started (thread function may run some cleanup logic thats get skipped otherwise)
    pub fn stop_or_timeout(self: *ThreadControl, time_out_ns: u64) !void {
        if (self.signal.load() == .stopped) return;
        if (self.signal.load() == .stop_signal) {
            self.wakeup();
            try self.stop_event.timedWait(time_out_ns);
        } else {
            var timer = std.time.Timer.start() catch unreachable;
            while (!self.signal.load().has_started()) if (timer.read() + 1000 > time_out_ns) {
                std.log.err("thread has not started", .{});
                @panic("thread has not started");
            };
            self.set_stop_signal();
            self.wakeup();
            const remaining_ns = std.math.sub(u64, time_out_ns, timer.read()) catch 0;
            try self.stop_event.timedWait(remaining_ns);
            assert(self.stop_event.isSet());
        }
    }
    /// Abstracts stopping threads, gives you waiting / waking with two reset events via the Control parameter (first parameter in function must be type ThreadStatus)
    /// use the ThreadStaus in the your function to check if stop was signaled!
    /// NOTE: all resources used by the thread must be valid for the lifetime of the thread!
    pub fn spawn(tc: *ThreadControl, alloc: Allocator, debug_name: []const u8, function: anytype, args: anytype) !std.Thread {
        const m = struct {
            fn startup(th_status: ThreadStatus, dbg_name: []const u8, fnc: anytype, xargs: anytype) void {
                th_status.signal.store(.running);
                _ = @call(.auto, fnc, .{th_status} ++ xargs) catch |e| {
                    std.log.err("{s}: {}", .{ dbg_name, e });
                };
                std.log.info("{s} Thread is terminating...", .{dbg_name});
                th_status.stop_event.set();
                th_status.signal.store(.stopped);
            }
        };
        const status = ThreadStatus{
            .handle_sets_thread_waits = &tc.handle_sets_thread_waits,
            .thread_sets_handle_waits = &tc.thread_sets_handle_waits,
            .signal = &tc.signal,
            .stop_event = &tc.stop_event,
        };
        const th = try std.Thread.spawn(
            .{ .allocator = alloc },
            m.startup,
            .{ status, debug_name, function, args },
        );
        return th;
    }
};

/// this lock is safe to use in a audio realtime scenario
/// use this when you want to mutate variables of something accesed by the realtime thread
/// mutex = synchronized exclusiv access = only one can have it at a time
/// use try_lock on the audio realtime thread which is wait free and lock on the thread which is blocking
/// aka if (mtx.try_lock) { // proceed to use the variables on the realtime thread }
/// NOTE: a lock is for synchronization and often compromises composability of functions, synchronization is best left to the end user because as he views the circumstances!
pub const Spinlock = struct {
    mtx: std.Thread.Mutex = .{},
    pub fn lock(self: *Spinlock) void {
        while (!self.mtx.tryLock()) {
            std.Thread.yield() catch {};
        }
    }
    pub fn unlock(self: *Spinlock) void {
        self.mtx.unlock();
    }
    pub fn try_lock(self: *Spinlock) bool {
        return self.mtx.tryLock();
    }
};
