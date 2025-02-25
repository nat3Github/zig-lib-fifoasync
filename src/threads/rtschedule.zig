const std = @import("std");
const root = @import("../lib.zig");
const wthread = root.threads.wthread;
const Allocator = std.mem.Allocator;

const ResetEvent = std.Thread.ResetEvent;
const Timer = std.time.Timer;

/// NOTE: need to use 64 because 32 is only equal to 5 seconds as NanoSeconds
/// so value is a u64 and protected through atomic access if methods are called on it
/// u64 value is refering to NanoSeconds
/// u64 maximum integer is the null value,
pub const SchedTime = struct {
    const NullValue: u64 = std.math.maxInt(u64);
    const This = @This();
    /// not threadsafe to use use get and set
    _value: *u64,
    /// init self with null value
    pub fn init(gpa: Allocator) !This {
        const v = try gpa.create(u64);
        v.* = NullValue;
        return This{ ._value = v };
    }
    // pub fn deinit(gpa: Allocator)
    pub fn deinit(self: *This, gpa: Allocator) void {
        gpa.destroy(self._value);
    }
    pub fn get(self: *const This) ?u64 {
        const val = @atomicLoad(u64, self._value, .acquire);
        if (val == NullValue) return null else return val;
    }
    pub fn set(self: *const This, val: ?u64) void {
        if (val) |v| {
            std.debug.assert(v != NullValue);
            @atomicStore(usize, self._value, v, .release);
        } else @atomicStore(usize, self._value, NullValue, .release);
    }
};

const SchedHandleLocal = struct {
    const This = @This();
    re: *ResetEvent,
    att: SchedTime,
    local_counter: u64 = 0,
    pub fn init(alloc: Allocator) !This {
        const vre = try alloc.create(ResetEvent);
        const vatt = try SchedTime.init(alloc);
        return This{
            .att = vatt,
            .re = vre,
        };
    }
    pub fn check(self: *This, time_progress_nano: u64, compensation: u64) void {
        const x = self.att.get() orelse return;
        self.local_counter += time_progress_nano;
        if (self.local_counter + compensation >= x) {
            self.att.set(null);
            self.re.set();
            self.local_counter = 0;
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
    pub fn schedule(self: *This, time_ns: u64) void {
        self.re.reset();
        self.att.set(time_ns);
    }
    pub fn wait(self: *This, time_out_ns: u64) !void {
        std.debug.assert(!self.re.isSet());
        try self.re.timedWait(time_out_ns);
    }
};

const ScheduleWakeConfig = struct {
    /// how many wake handles are processed
    slots: usize = 1024,
};
/// schedule waking a thread with sub ms accuracy:
pub fn ScheduleWake(cfg: ScheduleWakeConfig) type {
    return struct {
        const This = @This();
        const T_Lthread = wthread.WThread(wthread.WThreadConfig.init().withT([cfg.slots]SchedHandleLocal));
        thread: T_Lthread.InitReturnType,
        sched_handles: []SchedHandle,
        fn f(self: *[cfg.slots]SchedHandleLocal, thread: *T_Lthread.ArgumentType) !void {
            const handles = self[0..];
            var compensation: u64 = 0;
            const offset = 1000 * 300 * 0;
            var local_timer: Timer = try Timer.start();
            local_timer.reset();
            while (thread.is_running.load(.acquire)) {
                var time_to_turn = local_timer.read();
                for (handles) |*h| {
                    time_to_turn += local_timer.read();
                    h.check(time_to_turn, compensation);
                }
                time_to_turn += local_timer.read();
                local_timer.reset();
                compensation = (compensation + time_to_turn) / 2 + offset;
            }
        }
        pub fn init(alloc: Allocator) !This {
            var hndles: [cfg.slots]SchedHandleLocal = undefined;
            for (hndles[0..]) |*j| j.* = try SchedHandleLocal.init(alloc);
            const these_handles = try alloc.alloc(SchedHandle, cfg.slots);
            for (these_handles, hndles[0..]) |*j, h| {
                j.re = h.re;
                j.att = h.att;
            }
            const t = try T_Lthread.init(
                alloc,
                hndles,
                This.f,
                wthread.Void,
                wthread.Void,
                wthread.Void,
                wthread.Void,
            );
            return This{
                .thread = t,
                .sched_handles = these_handles,
            };
        }
        pub fn stop_thread(self: *This) void {
            self.thread.stop();
        }
        pub fn wait_till_stopped(self: *This, time_out_ns: u64) !void {
            try self.thread.wait_till_stopped(time_out_ns);
        }
        /// if deinit is called before the thread is stopped segfaults will likely crash the programm
        pub fn deinit(self: *This) void {
            const alloc = self.thread.alloc;
            for (self.sched_handles) |*h| h.deinit(alloc);
            alloc.free(self.sched_handles);
            self.thread.deinit();
        }
    };
}
test "test schedule wake" {
    //TODO
    var heapalloc = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = heapalloc.allocator();
    // const alloc = std.testing.allocator;
    const swcfg = ScheduleWakeConfig{
        .slots = 1,
    };
    var sw = try ScheduleWake(swcfg).init(alloc);
    while (!sw.thread.is_running.load(.acquire)) {}
    const ms = 1_000_000;

    const N_measurement = 256;
    var mes_arr: [N_measurement]u64 = undefined;

    var timer = try Timer.start();
    const time_period = 1 * ms;
    const time_out = 100 * time_period;

    for (0..N_measurement) |i| {
        timer.reset();
        sw.sched_handles[0].schedule(time_period);
        try sw.sched_handles[0].wait(time_out);
        const real_time = timer.read();
        mes_arr[i] = real_time;
        std.Thread.sleep(1 * ms);
    }
    std.Thread.sleep(1 * ms);
    try sw.thread.wait_till_stopped(std.math.maxInt(u64));
    statistics(mes_arr[0..]);
    sw.deinit();
}

test "test all refs" {
    std.testing.refAllDeclsRecursive(@This());
}

fn statistics(slc: []u64) void {
    const mean = calc_mean_ms(slc);
    const max = calc_max_ms(slc);
    const p90 = calc_mean_maxp(slc, 0.9);
    const fmt =
        \\ statistics ({} samples)
        \\ mean: {d:.3} ms
        \\ max: {d:.3} ms
        \\ p90: {d:.3} ms
        \\
    ;
    std.debug.print(fmt, .{ slc.len, mean, max, p90 });
}
fn calc_mean_maxp(slc: []u64, percentile: f32) f64 {
    std.debug.assert(percentile <= 1.0 and percentile >= 0);
    const z = @as(f64, @floatFromInt(slc.len)) * percentile;
    const ind: usize = @intFromFloat(@floor(z));
    const kk = struct {
        const This = @This();
        fn flessthan(v: This, a: u64, b: u64) bool {
            _ = v;
            return a < b;
        }
    };
    std.mem.sort(u64, slc, kk{}, kk.flessthan);
    return calc_mean_ms(slc[ind..]);
}

fn ns_to_ms_f64(k: u64) f64 {
    const ns_f: f64 = @floatFromInt(k);
    const ms: f64 = @floatFromInt(1_000_000);
    return ns_f / ms;
}
fn calc_mean_ms(slc: []u64) f64 {
    var x: f64 = 0;
    for (slc) |s| {
        x += ns_to_ms_f64(s) / @as(f64, @floatFromInt(slc.len));
    }
    return x;
}
fn calc_max_ms(slc: []u64) f64 {
    var x: u64 = 0;
    for (slc) |s| {
        if (s >= x) x = s;
    }
    return ns_to_ms_f64(x);
}
