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
    // want to use a type on the stack?
    T_stack_type: type = VoidType,
    // want to use a channel type?
    T_channel_type_thread: type = VoidType,
    T_channel_type_local: type = VoidType,
    // want to have a reset event for waking the thread?
    reset_event_local: type = VoidType,
    // want to use a reset event inside the the thread function?
    reset_event_thread: type = VoidType,
    pub fn init() This {
        return This{};
    }
    pub fn withT(self: This, T: type) This {
        var this = self;
        this.T_stack_type = T;
        return this;
    }
    pub fn withChannelLinked(self: This, T: type) This {
        var this = self;
        this.T_channel_type_local = T;
        this.T_channel_type_thread = T;
        return this;
    }
    pub fn withResetEventLinked(self: This, T: type) This {
        var this = self;
        this.reset_event_local = T;
        this.reset_event_thread = T;
        return this;
    }
};
pub const WThreadHandleConfig = struct {
    channel: type,
    reset_event: type,
};
pub fn WThreadArg(cfg: WThreadHandleConfig) type {
    return struct {
        const This = @This();
        pub const config = cfg;
        is_running: *AtomicBool,
        reset_event: cfg.reset_event,
        channel: cfg.channel,
    };
}

pub fn WThreadHandle(cfg: WThreadHandleConfig) type {
    return struct {
        const This = @This();
        pub const config = cfg;
        is_running: *AtomicBool,
        stop_event: *ResetEvent,
        reset_event: cfg.reset_event,
        // channel for communication
        channel: cfg.channel,
        // this allocator is exposed to the thread make sure it is threadsafe if you use it
        alloc: Allocator,
        pub fn stop(self: *This) void {
            self.is_running.store(false, .release);
        }
        pub fn wait_till_stopped(self: *This, time_out_ns: u64) !void {
            self.stop();
            try self.stop_event.timedWait(time_out_ns);
        }
        /// if deinit is called before the thread is stopped segfaults will likely crash the programm
        pub fn deinit(self: *This) void {
            self.alloc.destroy(self.is_running);
            self.alloc.destroy(self.stop_event);
        }
    };
}
pub fn WThread(cfg: WThreadConfig) type {
    const config_this = WThreadHandleConfig{
        .channel = cfg.T_channel_type_local,
        .reset_event = cfg.reset_event_local,
    };
    const T_This = WThreadHandle(config_this);
    const config_thread = WThreadHandleConfig{
        .channel = cfg.T_channel_type_thread,
        .reset_event = cfg.reset_event_thread,
    };
    const T_Thread = WThreadArg(config_thread);
    const T_reset_event_thread = cfg.reset_event_thread;
    const T_reset_event_local = cfg.reset_event_local;
    const T_channel_local = cfg.T_channel_type_local;
    const T_channel_thread = cfg.T_channel_type_thread;
    const T_stack = cfg.T_stack_type;

    return struct {
        const This = @This();
        pub const config = cfg;
        pub const InitReturnType = T_This;
        pub const ArgumentType = T_Thread;

        fn exe(inst: T_stack, thread: T_Thread, fx: fn (*T_stack, *T_Thread) anyerror!void, stop_event: *ResetEvent) void {
            var xthread = thread;
            xthread.is_running.store(true, AtomicOrder.release);
            var t: T_stack = inst;
            std.log.debug("w thread started", .{});
            fx(&t, &xthread) catch |e| std.log.err("error in thread accured: {}", .{e});
            std.log.warn("l thread has terminated\n", .{});
            stop_event.set();
        }
        pub fn init(
            alloc: Allocator,
            instance: T_stack,
            f: fn (*T_stack, *T_Thread) anyerror!void,
            channel_local: T_channel_local,
            channel_thread: T_channel_thread,
            reset_event_local: T_reset_event_local,
            reset_event_thread: T_reset_event_thread,
        ) !T_This {
            const running: *AtomicBool = try alloc.create(AtomicBool);
            running.* = AtomicBool.init(false);
            const stop_event = try alloc.create(ResetEvent);
            stop_event.* = ResetEvent{};
            stop_event.reset();
            const thread = T_Thread{
                .is_running = running,
                .channel = channel_thread,
                .reset_event = reset_event_thread,
            };
            const th = try std.Thread.spawn(.{ .allocator = alloc }, This.exe, .{
                instance,
                thread,
                f,
                stop_event,
            });
            th.detach();
            const local = T_This{
                .alloc = alloc,
                .is_running = running,
                .channel = channel_local,
                .reset_event = reset_event_local,
                .stop_event = stop_event,
            };
            return local;
        }
    };
}
test "test wthread" {
    const alloc = std.testing.allocator;
    const cfg = WThreadConfig{};
    const T = WThread(cfg);
    const S = struct {
        fn f(s: *VoidType, thread: *T.ArgumentType) !void {
            while (thread.is_running.load(.acquire)) {}
            _ = s;
        }
    };
    var sv = try T.init(
        alloc,
        Void,
        S.f,
        Void,
        Void,
        Void,
        Void,
    );
    while (!sv.is_running.load(.acquire)) {}
    try sv.wait_till_stopped(1000 * 1000 * 1000);
    sv.deinit();
}
test "test all refs" {
    std.testing.refAllDecls(@This());
}
