const std = @import("std");
const Atomic = std.atomic.Value;
const Allocator = std.mem.Allocator;
const AtomicOrder = std.builtin.AtomicOrder;
const AtomicBool = Atomic(bool);
const ResetEvent = std.Thread.ResetEvent;

pub const VoidType = struct {};
pub const Void = VoidType{};

pub const WThreadConfig = struct {
    const This = @This();
    T_stack_type: type = VoidType,
    pub fn init(T: type) This {
        return This{ .T_stack_type = T };
    }
};

pub const WThreadArg = struct {
    const This = @This();
    is_running: *AtomicBool,
    thread_sets_handle_waits: *ResetEvent,
    handle_sets_thread_waits: *ResetEvent,
};

pub const WThreadHandle = struct {
    const This = @This();
    is_running: *AtomicBool,
    stop_event: *ResetEvent,
    thread_sets_handle_waits: *ResetEvent,
    handle_sets_thread_waits: *ResetEvent,
    // this allocator is exposed to the thread make sure it is threadsafe if you use it
    pub fn stop(self: *This) void {
        self.is_running.store(false, .release);
    }
    pub fn wait_till_stopped(self: *This, time_out_ns: u64) !void {
        self.stop();
        try self.stop_event.timedWait(time_out_ns);
    }
    /// if deinit is called before the thread is stopped segfaults will likely crash the programm
    pub fn deinit(self: *This, alloc: Allocator) void {
        alloc.destroy(self.is_running);
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
            xthread.is_running.store(true, AtomicOrder.release);
            fx(inst, xthread) catch |e| std.log.err("error in thread accured: {}", .{e});
            std.log.warn("l thread has terminated\n", .{});
            stop_event.set();
        }
        pub fn init(
            alloc: Allocator,
            instance: T_stack,
            f: fn (T_stack, T_Thread) anyerror!void,
        ) !T_This {
            const running: *AtomicBool = try alloc.create(AtomicBool);
            running.* = AtomicBool.init(false);
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
                .is_running = running,
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
                .is_running = running,
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
            while (thread.is_running.load(.acquire)) {}
            _ = s;
        }
    };
    var sv = try T.init(
        alloc,
        Void,
        S.f,
    );
    while (!sv.is_running.load(.acquire)) {}
    try sv.wait_till_stopped(1000 * 1000 * 1000);
    sv.deinit(alloc);
}
test "test all refs" {
    std.testing.refAllDecls(@This());
}
