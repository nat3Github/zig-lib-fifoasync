const std = @import("std");
const root = @import("../lib.zig");
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
    pub fn thread_is_running(self: *const This) bool {
        return self.inner.load(.acquire) != THREAD_STOPP_SIGNAL;
    }
    pub fn thread_has_terminated(self: *const This) bool {
        return self.inner.load(.acquire) == THREAD_STOPPED;
    }
    pub fn set_stopp_signal(self: *const This) void {
        self.inner.store(THREAD_STOPP_SIGNAL, .release);
    }
    pub fn init(alloc: Allocator) !This {
        const running: *AtomicU8 = try alloc.create(AtomicU8);
        running.* = AtomicU8.init(THREAD_NOT_STARTED);
        return This{ .inner = running };
    }
    pub fn deinit(self: *const This, alloc: Allocator) void {
        alloc.destroy(self.inner);
    }
};

pub const WThreadConfig = struct {
    const This = @This();
    T_stack_type: type = VoidType,
    pub fn init(T: type) This {
        return This{ .T_stack_type = T };
    }
};

pub const WThreadArg = struct {
    const This = @This();
    stop_signal: StopSignal,
    thread_sets_handle_waits: *ResetEvent,
    handle_sets_thread_waits: *ResetEvent,
    pub fn is_running(self: *const This) bool {
        return self.stop_signal.thread_is_running();
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
};

pub const WThreadHandle = struct {
    const This = @This();
    stop_signal: StopSignal,
    stop_event: *ResetEvent,
    thread_sets_handle_waits: *ResetEvent,
    handle_sets_thread_waits: *ResetEvent,
    // this allocator is exposed to the thread make sure it is threadsafe if you use it
    pub fn isRunning(self: *const This) bool {
        return self.stop_signal.thread_is_running();
    }
    /// dont call if stopped will dead block
    pub fn spinwait_for_startup(self: *const This) void {
        if (self.stop_signal.thread_has_terminated()) return;
        while (!self.isRunning()) {}
    }
    pub fn stop(self: *This) void {
        self.stop_signal.set_stopp_signal();
        self.handle_sets_thread_waits.set();
    }
    pub fn wait_till_stopped(self: *This, time_out_ns: u64) !void {
        self.stop();
        try self.stop_event.timedWait(time_out_ns);
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
    pub fn setup_rts_waking(self: *This, sh: root.threads.rtschedule.SchedHandle) root.threads.rtschedule.SchedHandle {
        const shx = sh;
        shx.re.* = self.handle_sets_thread_waits.*;
        return shx;
    }
    /// if deinit is called before the thread is stopped segfaults will likely crash the programm
    pub fn deinit(self: *This, alloc: Allocator) void {
        std.debug.assert(self.stop_signal.thread_has_terminated());
        self.stop_signal.deinit(alloc);
        alloc.destroy(self.stop_event);
        alloc.destroy(self.thread_sets_handle_waits);
        alloc.destroy(self.handle_sets_thread_waits);
    }
};

pub fn WThread(cfg: WThreadConfig) type {
    const T_This = WThreadHandle;
    const T_Thread = WThreadArg;
    const T_stack = cfg.T_stack_type;
    return struct {
        const This = @This();
        pub const config = cfg;
        pub const InitReturnType = T_This;
        pub const ArgumentType = T_Thread;

        fn exe(inst: T_stack, thread: T_Thread, fx: fn (T_stack, T_Thread) anyerror!void, stop_event: *ResetEvent) void {
            var xthread = thread;
            const stopped = xthread.stop_signal.inner.swap(StopSignal.THREAD_STARTED, .seq_cst);
            if (stopped != StopSignal.THREAD_STOPP_SIGNAL) {
                fx(inst, xthread) catch |e| std.log.err("\nerror in thread accured: {}", .{e});
                std.log.warn("\nl thread has terminated\n", .{});
            }
            xthread.stop_signal.inner.store(StopSignal.THREAD_STOPPED, .release);
            stop_event.set();
        }
        pub fn init(
            alloc: Allocator,
            instance: T_stack,
            f: fn (T_stack, T_Thread) anyerror!void,
        ) !T_This {
            const stop_signal = try StopSignal.init(alloc);
            const stop_event = try alloc.create(ResetEvent);
            stop_event.* = ResetEvent{};
            stop_event.reset();
            const re1 = try alloc.create(ResetEvent);
            re1.* = ResetEvent{};
            re1.reset();
            const re2 = try alloc.create(ResetEvent);
            re2.* = ResetEvent{};
            re2.reset();
            const thread = T_Thread{
                .stop_signal = stop_signal,
                .thread_sets_handle_waits = re1,
                .handle_sets_thread_waits = re2,
            };
            const th = try std.Thread.spawn(.{ .allocator = alloc }, This.exe, .{
                instance,
                thread,
                f,
                stop_event,
            });
            th.detach();
            return T_This{
                .stop_signal = stop_signal,
                .stop_event = stop_event,
                .thread_sets_handle_waits = re1,
                .handle_sets_thread_waits = re2,
            };
        }
    };
}
test "test wthread" {
    const alloc = std.testing.allocator;
    const cfg = WThreadConfig{};
    const T = WThread(cfg);
    const S = struct {
        fn f(s: VoidType, thread: T.ArgumentType) !void {
            while (thread.is_running()) {}
            _ = s;
            std.debug.print("\n thread Exited (good)", .{});
        }
    };
    var sv = try T.init(
        alloc,
        Void,
        S.f,
    );
    try sv.wait_till_stopped(1000 * 1000 * 1000);
    sv.deinit(alloc);
}
test "test all refs" {
    std.testing.refAllDecls(@This());
}
