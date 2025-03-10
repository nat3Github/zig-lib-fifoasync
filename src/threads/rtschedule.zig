const std = @import("std");
const assert = std.debug.assert;
const root = @import("../lib.zig");
const wthread = root.threads.wthread;
const Allocator = std.mem.Allocator;

const ResetEvent = std.Thread.ResetEvent;
const Timer = std.time.Timer;

fn make_reset_event(alloc: Allocator) !*ResetEvent {
    const re = try alloc.create(ResetEvent);
    re.* = ResetEvent{};
    re.reset();
    return re;
}
/// NOTE: need to use 64 because 32 is only equal to 5 seconds as NanoSeconds
/// so value is a u64 and protected through atomic access if methods are called on it
/// u64 value is refering to NanoSeconds
/// u64 maximum integer is the null value,
const Atomic = std.atomic.Value;
const AtomicU64 = Atomic(u64);
pub const SchedTime = struct {
    const NullValue: u64 = std.math.maxInt(u64);
    const This = @This();
    /// not threadsafe to use use get and set
    _value: *AtomicU64,
    /// init self with null value
    pub fn init(alloc: Allocator) !This {
        const v = try alloc.create(AtomicU64);
        v.* = AtomicU64.init(NullValue);
        return This{ ._value = v };
    }
    // pub fn deinit(gpa: Allocator)
    pub fn deinit(self: *This, alloc: Allocator) void {
        alloc.destroy(self._value);
    }
    pub fn get(self: *const This) ?u64 {
        const val = self._value.load(.acquire);
        if (val == NullValue) return null else return val;
    }
    pub fn set(self: *const This, val: ?u64) void {
        if (val) |v| {
            const xval = if (val == NullValue) v - 1 else v;
            self._value.store(xval, .release);
        } else self._value.store(NullValue, .release);
    }
};

const SchedHandleLocal = struct {
    const This = @This();
    re: *ResetEvent,
    att: SchedTime,
    local_counter: u64 = 0,
    pub fn init(alloc: Allocator) !This {
        const vre = try make_reset_event(alloc);
        const vatt = try SchedTime.init(alloc);
        return This{
            .att = vatt,
            .re = vre,
        };
    }
    pub fn progress_clock(self: *This, time_progress_nano: u64, compensation: u64) void {
        if (self.att.get()) |event| {
            self.local_counter += time_progress_nano;
            if (self.local_counter + compensation >= event) {
                self.local_counter = 0;
                self.att.set(null);
                self.re.set();
            }
        }
    }
};
pub const SchedHandle = struct {
    const This = @This();
    re: *ResetEvent,
    att: SchedTime,
    pub fn deinit(self: *This, alloc: Allocator) void {
        alloc.destroy(self.re);
        self.att.deinit(alloc);
    }
    pub fn schedule(self: *This, time_ns: u64) !void {
        if (self.att.get() != null) return error.SchedHandleNotNull;
        self.att.set(time_ns);
    }
    pub fn wait(self: *This, time_out_ns: u64) !void {
        assert(!self.re.isSet());
        try self.re.timedWait(time_out_ns);
    }
};

const ScheduleWakeConfig = struct {
    /// how many wake handles are processed
    slots: usize = 1024,
    compensation_ns: u64 = 0,
};
/// schedule waking a thread with sub ms accuracy:
pub fn ScheduleWake(cfg: ScheduleWakeConfig) type {
    return struct {
        const This = @This();
        const T_Lthread = wthread.WThread(.{ .T_stack_type = [cfg.slots]SchedHandleLocal, .debug_name = "Schedule Wake" });
        thread: T_Lthread.InitReturnType,
        sched_handles: []SchedHandle,
        fn f(self: [cfg.slots]SchedHandleLocal, thread: T_Lthread.ArgumentType) !void {
            var handles = self;
            var local_timer: Timer = Timer.start() catch unreachable;
            local_timer.reset();
            while (true) {
                local_timer.reset();
                for (handles[0..]) |*h| {
                    h.progress_clock(local_timer.read(), cfg.compensation_ns);
                }
                if (local_timer.read() > 600e3) unreachable;
                if (!thread.should_run()) break;
            }
        }
        pub fn init(alloc: Allocator) !This {
            var hndles: [cfg.slots]SchedHandleLocal = undefined;
            for (&hndles) |*j| j.* = try SchedHandleLocal.init(alloc);
            const these_handles = try alloc.alloc(SchedHandle, cfg.slots);
            for (these_handles, hndles[0..]) |*j, h| {
                j.re = h.re;
                j.att = h.att;
            }
            const t = try T_Lthread.init(alloc, hndles, This.f);
            return This{ .thread = t, .sched_handles = these_handles };
        }
        pub fn stop_or_timeout(self: *This, time_out_ns: u64) !void {
            try self.thread.stop_or_timeout(time_out_ns);
        }
        /// if deinit is called before the thread is stopped segfaults will likely crash the programm
        pub fn deinit(self: *This, alloc: Allocator) void {
            // NOTE: call stop_or_timeout before calling deinit
            assert(self.thread.has_terminated());
            for (self.sched_handles) |*h| h.deinit(alloc);
            alloc.free(self.sched_handles);
            self.thread.deinit(alloc);
        }
    };
}
test "test schedule wake" {
    var heapalloc = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = heapalloc.allocator();
    // const alloc = std.testing.allocator;
    const swcfg = ScheduleWakeConfig{
        .slots = 128,
    };
    var sw = try ScheduleWake(swcfg).init(alloc);

    const N_measurement = 256;
    var mes_arr: [N_measurement]u64 = undefined;

    var timer = try Timer.start();
    sw.thread.spinwait_for_startup();
    var i: usize = 0;
    const sh = &sw.sched_handles[0];
    assert(sh.att.get() == null);
    sh.re.reset();
    while (i < mes_arr.len) {
        timer.reset();
        const sched: u64 = 10e6;
        try sh.schedule(sched);
        try sh.wait(10 * sched);
        sh.re.reset();
        const real_time = timer.read() - sched;
        mes_arr[i] = real_time;
        i += 1;
    }
    try sw.stop_or_timeout(std.math.maxInt(u64));
    stats.basic_stats(mes_arr[0..]);
    sw.deinit(alloc);
}
const stats = root.stats;

test "how fast is Timer.read()?" {
    const N_measurement = 1024;
    var mes_arr: [N_measurement]u64 = undefined;

    var timer = try Timer.start();
    var timer2 = try Timer.start();
    for (0..N_measurement) |i| {
        timer.reset();
        const real_time = timer.read();
        mes_arr[i] = real_time;
    }
    const time = timer2.read();
    const timef = stats.ns_to_ms_f64(time);
    const fmt =
        \\ how fast is timer.read()?
        \\ in time {d:.3} ms
        \\ that means avg = {d:.3} micro s
        \\
    ;
    std.debug.print(fmt, .{ timef, 1000 * (timef / mes_arr.len) });
}

fn benchmark_time_read(alloc: Allocator) void {
    _ = alloc;
    var timer = Timer.start() catch unreachable;
    _ = timer.read();
}

const zbench = @import("zbench");

test "how fast is Timer.read()? 2" {
    // var bench = zbench.Benchmark.init(std.testing.allocator, .{});
    // defer bench.deinit();
    // try bench.add("how fast is timer.read()", benchmark_time_read, .{});
    // try bench.run(std.io.getStdOut().writer());
}

test "test all refs" {
    std.testing.refAllDeclsRecursive(@This());
}
