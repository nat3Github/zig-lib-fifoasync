const std = @import("std");
const assert = std.debug.assert;
const root = @import("../lib.zig");
const rtsp = root.threads.rtschedule;
const Atomic = std.atomic.Value;
const Allocator = std.mem.Allocator;
const AtomicOrder = std.builtin.AtomicOrder;
const AtomicU8 = Atomic(u8);
const ResetEvent = std.Thread.ResetEvent;

pub const VoidType = struct {};
pub const Void = VoidType{};
pub const StopSignal = struct {
    const This = @This();
    inner: *AtomicU8,
    const THREAD_NOT_STARTED = 0;
    const THREAD_STARTED = 1;
    const THREAD_STOPP_SIGNAL = 2;
    const THREAD_STOPPED = 3;
    pub fn is_stop_signal(self: *const This) bool {
        return self.inner.load(.acquire) == THREAD_STOPP_SIGNAL;
    }
    pub fn has_started(self: *const This) bool {
        return self.inner.load(.acquire) >= THREAD_STARTED;
    }
    pub fn is_stopped(self: *const This) bool {
        return self.inner.load(.acquire) == THREAD_STOPPED;
    }
    fn set_stopp_signal(self: *const This) void {
        self.inner.store(THREAD_STOPP_SIGNAL, .release);
    }

    fn init(alloc: Allocator) !This {
        const running: *AtomicU8 = try alloc.create(AtomicU8);
        running.* = AtomicU8.init(THREAD_NOT_STARTED);
        return This{ .inner = running };
    }
    fn deinit(self: *const This, alloc: Allocator) void {
        alloc.destroy(self.inner);
    }
};

pub const WThreadConfig = struct {
    const This = @This();
    T_stack_type: type = VoidType,
    debug_name: [:0]const u8 = "",
};

pub const WThreadArg = struct {
    const This = @This();
    stop_signal: StopSignal,
    thread_sets_handle_waits: *ResetEvent,
    handle_sets_thread_waits: *ResetEvent,
    pub fn should_run(self: *const This) bool {
        return !self.stop_signal.is_stop_signal();
    }
    pub fn wakeup_waiting_thread(self: *This) void {
        self.thread_sets_handle_waits.set();
    }
    pub fn reset_event_reset(self: *This) void {
        self.handle_sets_thread_waits.reset();
    }
    pub fn reset_event_wait(self: *This, time_out_ns: u64) !void {
        try self.handle_sets_thread_waits.timedWait(time_out_ns);
    }
    fn init(wthread_handle: anytype) This {
        return This{
            .stop_signal = wthread_handle.stop_signal,
            .thread_sets_handle_waits = wthread_handle.thread_sets_handle_waits,
            .handle_sets_thread_waits = wthread_handle.handle_sets_thread_waits,
        };
    }
};

pub const WThreadHandleConfig = struct {
    owns_handle_sets_thread_waits: bool,
};
fn make_reset_event(alloc: Allocator) !*ResetEvent {
    const re = try alloc.create(ResetEvent);
    re.* = ResetEvent{};
    re.reset();
    return re;
}
const WthreadHandleOwned = WThreadHandle(.{ .owns_handle_sets_thread_waits = true });
const WthreadHandleForeignResetEvent = WThreadHandle(.{ .owns_handle_sets_thread_waits = false });

fn wthread_handle_sched_handle(alloc: Allocator, sh: rtsp.SchedHandle) !WthreadHandleForeignResetEvent {
    const stop_signal = try StopSignal.init(alloc);
    const stop_event = try make_reset_event(alloc);
    return WthreadHandleForeignResetEvent{
        .stop_signal = stop_signal,
        .stop_event = stop_event,
        .thread_sets_handle_waits = try make_reset_event(alloc),
        .handle_sets_thread_waits = sh.re,
    };
}
fn wthread_handle_owned(alloc: Allocator) !WthreadHandleOwned {
    const stop_signal = try StopSignal.init(alloc);
    const stop_event = try make_reset_event(alloc);
    return WthreadHandleOwned{
        .stop_signal = stop_signal,
        .stop_event = stop_event,
        .thread_sets_handle_waits = try make_reset_event(alloc),
        .handle_sets_thread_waits = try make_reset_event(alloc),
    };
}
pub fn WThreadHandle(cfg: WThreadHandleConfig) type {
    return struct {
        const This = @This();
        stop_event: *ResetEvent,
        thread_sets_handle_waits: *ResetEvent,
        handle_sets_thread_waits: *ResetEvent,
        stop_signal: StopSignal,
        pub fn spinwait_for_startup(self: *const This) void {
            assert(!self.stop_signal.is_stop_signal());
            assert(!self.stop_signal.is_stopped());
            while (!self.stop_signal.has_started()) {}
        }

        pub fn has_terminated(self: *const This) bool {
            return self.stop_signal.is_stopped();
        }
        pub fn set_stop_signal(self: *This) void {
            // note we only can stopp the thread if its started (thread function may run some cleanup logic thats get skipped otherwise)
            if (self.stop_signal.is_stopped()) return;
            if (self.stop_signal.is_stop_signal()) return;
            self.stop_signal.set_stopp_signal();
        }

        pub fn stop_or_timeout(self: *This, time_out_ns: u64) !void {
            // note we only can stopp the thread if its started (thread function may run some cleanup logic thats get skipped otherwise)
            if (self.stop_signal.is_stopped()) return;
            if (self.stop_signal.is_stop_signal()) {
                self.wakeup_waiting_thread();
                try self.stop_event.timedWait(time_out_ns);
            } else {
                var timer = std.time.Timer.start() catch unreachable;
                while (!self.stop_signal.has_started()) if (timer.read() + 1000 > time_out_ns) return error.TimeOutThreadNotStarted;
                self.stop_signal.set_stopp_signal();
                self.wakeup_waiting_thread();
                const remaining_ns = std.math.sub(u64, time_out_ns, timer.read()) catch 0;
                try self.stop_event.timedWait(remaining_ns);
            }
        }
        pub fn wakeup_waiting_thread(self: *This) void {
            self.handle_sets_thread_waits.set();
        }
        pub fn reset_event_reset(self: *This) void {
            self.thread_sets_handle_waits.reset();
        }
        pub fn reset_event_wait(self: *This, time_out_ns: u64) !void {
            try self.thread_sets_handle_waits.timedWait(time_out_ns);
        }
        /// if deinit is called before the thread is stopped segfaults will likely crash the programm
        pub fn deinit(self: *This, alloc: Allocator) void {
            // if this assertion is triggered call wait till stopped
            std.debug.assert(self.has_terminated());

            self.stop_signal.deinit(alloc);
            alloc.destroy(self.stop_event);
            if (cfg.owns_handle_sets_thread_waits) alloc.destroy(self.handle_sets_thread_waits);
            alloc.destroy(self.thread_sets_handle_waits);
        }
    };
}
/// Abstracts stopping threads, gives you waiting / waking with two reset events via the W_ThreadArg parameter
/// if you have a custom function which does not terminate check for the stop signal like:
/// while (W_ThreadArg.is_running()) {
///     // my periodic code
/// }
pub fn WThread(cfg: WThreadConfig) type {
    const T_Thread = WThreadArg;
    const T_stack = cfg.T_stack_type;
    return struct {
        const This = @This();
        pub const config = cfg;
        pub const ArgumentType = T_Thread;
        pub const InitReturnType = WThreadHandle(.{ .owns_handle_sets_thread_waits = true });
        pub const InitReturnTypeWithSchedHandle = WThreadHandle(.{ .owns_handle_sets_thread_waits = false });

        fn exe(inst: T_stack, thread: T_Thread, fx: fn (T_stack, T_Thread) anyerror!void, stop_event: *ResetEvent) void {
            var xthread = thread;
            xthread.stop_signal.inner.store(StopSignal.THREAD_STARTED, .release);
            fx(inst, xthread) catch |e| std.log.err("{s}: {}", .{ cfg.debug_name, e });
            xthread.stop_signal.inner.store(StopSignal.THREAD_STOPPED, .release);
            std.log.warn("{s} Thread is terminating...", .{cfg.debug_name});
            stop_event.set();
        }
        /// NOTE: sched_handle must be valid for the lifetime of WTthread!
        pub fn init_with_sched_handle(
            alloc: Allocator,
            instance: T_stack,
            f: fn (T_stack, T_Thread) anyerror!void,
            sched_handle: rtsp.SchedHandle,
        ) !WthreadHandleForeignResetEvent {
            const wthandle = try wthread_handle_sched_handle(alloc, sched_handle);
            const thread_arg = T_Thread.init(wthandle);
            const th = try std.Thread.spawn(
                .{ .allocator = alloc },
                This.exe,
                .{ instance, thread_arg, f, wthandle.stop_event },
            );
            th.detach();
            return wthandle;
        }
        pub fn init(
            alloc: Allocator,
            instance: T_stack,
            f: fn (T_stack, T_Thread) anyerror!void,
        ) !WthreadHandleOwned {
            const wthandle = try wthread_handle_owned(alloc);
            const thread_arg = T_Thread.init(wthandle);
            const th = try std.Thread.spawn(
                .{ .allocator = alloc },
                This.exe,
                .{ instance, thread_arg, f, wthandle.stop_event },
            );
            th.detach();
            return wthandle;
        }
    };
}
test "test wthread" {
    const alloc = std.testing.allocator;
    const cfg = WThreadConfig{};
    const T = WThread(cfg);
    const S = struct {
        fn f(s: VoidType, thread: T.ArgumentType) !void {
            std.log.warn("\n thread started (good)", .{});
            while (thread.should_run()) {}
            _ = s;
            std.log.warn("\n thread Exited (good)", .{});
        }
    };
    var sv = try T.init(
        alloc,
        Void,
        S.f,
    );
    std.Thread.sleep(1e6);
    try sv.stop_or_timeout(1 * 1e6);
    sv.deinit(alloc);
}
test "test all refs" {
    std.testing.refAllDecls(@This());
}
