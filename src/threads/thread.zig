const std = @import("std");
const assert = std.debug.assert;
const Atomic = std.atomic.Value;
const Allocator = std.mem.Allocator;
const AtomicOrder = std.builtin.AtomicOrder;
const AtomicU8 = Atomic(u8);
const ResetEvent = std.Thread.ResetEvent;
pub const prio = @import("thread_prio.zig");
test "prio" {
    _ = prio;
}

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

pub const WThreadArg = struct {};

fn make_reset_event(alloc: Allocator) !*ResetEvent {
    const re = try alloc.create(ResetEvent);
    re.* = ResetEvent{};
    re.reset();
    return re;
}

pub const Thread = struct {
    std_thread: std.Thread,
    stop_event: *ResetEvent,
    thread_sets_handle_waits: *ResetEvent,
    handle_sets_thread_waits: *ResetEvent,
    stop_signal: StopSignal,
    pub fn detach(self: *const Thread) void {
        self.std_thread.detach();
    }
    pub fn spinwait_for_startup(self: *const Thread) void {
        assert(!self.stop_signal.is_stop_signal());
        assert(!self.stop_signal.is_stopped());
        while (!self.stop_signal.has_started()) {}
    }
    pub fn wakeup(self: *Thread) void {
        self.handle_sets_thread_waits.set();
    }
    pub fn reset(self: *Thread) void {
        self.thread_sets_handle_waits.reset();
    }
    pub fn wait(self: *Thread, time_out_ns: u64) !void {
        try self.thread_sets_handle_waits.timedWait(time_out_ns);
    }
    pub fn shutdown(self: *Thread, alloc: Allocator) void {
        self.spinwait_for_startup();
        self.set_stop_signal();
        self.stop_or_timeout(1 * 1_000_000_000) catch {
            std.log.err("shutdown failed thread function did not return", .{});
            @panic("shutdown failed thread function did not return");
        };
        self.deinit(alloc);
    }
    /// NOTE: only stopp the thread if its started (thread function may run some cleanup logic thats get skipped otherwise)
    pub fn set_stop_signal(self: *Thread) void {
        if (self.stop_signal.is_stopped()) return;
        if (self.stop_signal.is_stop_signal()) return;
        self.stop_signal.set_stopp_signal();
    }
    /// NOTE: only stopp the thread if its started (thread function may run some cleanup logic thats get skipped otherwise)
    pub fn stop_or_timeout(self: *Thread, time_out_ns: u64) !void {
        if (self.stop_signal.is_stopped()) return;
        if (self.stop_signal.is_stop_signal()) {
            self.wakeup();
            try self.stop_event.timedWait(time_out_ns);
        } else {
            var timer = std.time.Timer.start() catch unreachable;
            while (!self.stop_signal.has_started()) if (timer.read() + 1000 > time_out_ns) {
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
    pub fn has_terminated(self: *const Thread) bool {
        return self.stop_signal.is_stopped();
    }
    /// if deinit is called before the thread is stopped segfaults will likely crash the programm
    pub fn deinit(self: *Thread, alloc: Allocator) void {
        // if this assertion is triggered call wait till stopped
        // std.debug.assert(self.stop_event.isSet());
        self.stop_signal.deinit(alloc);
        alloc.destroy(self.stop_event);
        alloc.destroy(self.handle_sets_thread_waits);
        alloc.destroy(self.thread_sets_handle_waits);
    }
};
pub const Control = struct {
    thread_sets_handle_waits: *ResetEvent,
    handle_sets_thread_waits: *ResetEvent,
    stop_signal: StopSignal,
    pub fn is_running(self: *const Control) bool {
        return !self.stop_signal.is_stop_signal();
    }
    pub fn wakeup(self: *const Control) void {
        self.thread_sets_handle_waits.set();
    }
    pub fn reset(self: *const Control) void {
        self.handle_sets_thread_waits.reset();
    }
    pub fn wait(self: *const Control, time_out_ns: u64) !void {
        try self.handle_sets_thread_waits.timedWait(time_out_ns);
    }
};
/// Abstracts stopping threads, gives you waiting / waking with two reset events via the Control parameter (first parameter in function)
/// if you have a custom function which does not terminate check for the stop signal like:
/// while (W_ThreadArg.is_running()) {
///     // my periodic code
/// }
/// NOTE: sched_handle must be valid for the lifetime of WTthread!
pub fn thread(alloc: Allocator, debug_name: []const u8, function: anytype, args: anytype) !Thread {
    const m = struct {
        const Thread = struct {
            stop_event: *ResetEvent,
            thread_sets_handle_waits: *ResetEvent,
            handle_sets_thread_waits: *ResetEvent,
            stop_signal: StopSignal,
        };
        fn startup(th: @This().Thread, dbg_name: []const u8, fnc: anytype, xargs: anytype) void {
            th.stop_signal.inner.store(StopSignal.THREAD_STARTED, .release);
            const ctrl = Control{
                .handle_sets_thread_waits = th.handle_sets_thread_waits,
                .thread_sets_handle_waits = th.thread_sets_handle_waits,
                .stop_signal = th.stop_signal,
            };
            _ = @call(.auto, fnc, .{ctrl} ++ xargs) catch |e| {
                std.log.err("{s}: {}", .{ dbg_name, e });
            };
            th.stop_signal.inner.store(StopSignal.THREAD_STOPPED, .release);
            std.log.info("{s} Thread is terminating...", .{dbg_name});
            th.stop_event.set();
        }
    };
    const mth = m.Thread{
        .handle_sets_thread_waits = try make_reset_event(alloc),
        .thread_sets_handle_waits = try make_reset_event(alloc),
        .stop_event = try make_reset_event(alloc),
        .stop_signal = try StopSignal.init(alloc),
    };
    const th = try std.Thread.spawn(
        .{ .allocator = alloc },
        m.startup,
        .{ mth, debug_name, function, args },
    );
    return Thread{
        .std_thread = th,
        .handle_sets_thread_waits = mth.handle_sets_thread_waits,
        .thread_sets_handle_waits = mth.thread_sets_handle_waits,
        .stop_event = mth.stop_event,
        .stop_signal = mth.stop_signal,
    };
}
fn concat_tuple(a: anytype, b: anytype) concat_tuple_type(a, b) {
    const init_val = a;
    var cur_ptr: *const anyopaque = &init_val;
    comptime var CurTy = @TypeOf(init_val);
    inline for (b) |item| {
        const cur_val = @as(*const CurTy, @alignCast(@ptrCast(cur_ptr))).*;
        const new_val = cur_val ++ .{item};
        cur_ptr = &new_val;
        CurTy = @TypeOf(new_val);
    }
    const final = @as(*const CurTy, @alignCast(@ptrCast(cur_ptr))).*;
    // @compileLog(final);
    return final;
}
fn concat_tuple_type(a: anytype, b: anytype) type {
    const init_val = a;
    var cur_ptr: *const anyopaque = &init_val;
    comptime var CurTy = @TypeOf(init_val);
    inline for (b) |item| {
        const cur_val = @as(*const CurTy, @alignCast(@ptrCast(cur_ptr))).*;
        const new_val = cur_val ++ .{item};
        cur_ptr = &new_val;
        CurTy = @TypeOf(new_val);
    }
    const final = @as(*const CurTy, @alignCast(@ptrCast(cur_ptr))).*;
    return @TypeOf(final);
}

test "test wthread" {
    if (true) return;
    const alloc = std.testing.allocator;
    const m = struct {
        fn func(th: Control) !void {
            std.log.warn("\n thread started (good)", .{});
            while (th.is_running()) {}
            std.log.warn("\n thread Exited (good)", .{});
        }
    };
    var thx = try thread(alloc, "my cool thread", m.func, .{});
    std.Thread.sleep(800e6);
    thx.shutdown(alloc);
}
test "test all refs" {
    std.testing.refAllDecls(@This());
}
