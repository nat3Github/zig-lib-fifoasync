const std = @import("std");
const builtin = @import("builtin");
const root = @import("../lib.zig");
const os_tag = builtin.target.os.tag;
const Atomic = std.atomic.Value;
const wthread = root.threads.wthread;
const Allocator = std.mem.Allocator;
const Timer = std.time.Timer;
fn sub_or_zero(a: u64, b: u64) u64 {
    return a - @min(a, b);
}
pub const SEC = 1000 * MILLI;
pub const MILLI = 1000 * MICRO;
pub const MICRO = 1_000;
/// use this with buffer sizes that have more leeway (big buffers) -> less spinning, more efficient!
/// use this with tight buffer sizes and rather poll on next event
const RtSleep = struct {
    const This = @This();
    /// i.e. windows sleep cant sleep shorter than 1 ms
    lower_bound: u64,
    /// assumed that
    pos_max_derivation: u64,
    neg_max_derivation: u64,

    fn sleep(nano_seconds: u64) void {
        if (nano_seconds > MILLI) {
            switch (os_tag) {
                .linux, .macos => {
                    // linux sleep is to be assumed correct for sub milliseconds;
                    // i have read that sometime it sleeps longer that that, must test that!
                    std.Thread.sleep(nano_seconds);
                },
                .windows => {
                    // windows clock cant sleep shorter than 1 ms spin-wait
                    const ms = nano_seconds / MILLI;
                    std.Thread(ms);
                },
                else => @compileError("OS is not Supported"),
            }
        } else {
            switch (os_tag) {
                .linux => {
                    // linux sleep is to be assumed correct for sub milliseconds;
                    // i have read that sometime it sleeps longer that that, must test that!
                    const sleep_alt = sub_or_zero(nano_seconds, 500 * MICRO);
                    if (sleep_alt > 0) {
                        std.Thread.sleep(nano_seconds);
                    }
                },
                .windows => {
                    // windows clock cant sleep shorter than 1 ms spin-wait
                    const ms = nano_seconds / MILLI;
                    // const rem = nano_seconds - ms * MILLI;
                    if (ms > 0) {
                        std.Thread(ms);
                    }
                },
                .macos => {
                    // no idea have to test is assumed to be like linux
                    std.Thread.sleep(nano_seconds);
                },
                else => @compileError("OS is not Supported"),
            }
        }
    }
};

// times the sleep function at runtime
const RtsSleepOptimizer = struct {
    const This = @This();
    result: RtSleep,
    /// uses the default timings for the os
    pub fn init_os_default_timings() This {
        const rts = switch (os_tag) {
            .linux => RtSleep{
                .lower_bound = 0,
                .pos_max_derivation = 0,
                .neg_max_derivation = 0,
            },
            .windows => RtSleep{
                .lower_bound = 0,
                .pos_max_derivation = 0,
                .neg_max_derivation = 0,
            },
            else => @compileError("unsupported OS"),
        };
        return This{
            .result = rts,
        };
    }
    /// performs timing measurements of the system
    const PASSES = 128;
    pub fn init_measure_timings_on_local_thread() !This {
        var t = try Timer.start();
        var timings = std.mem.zeroes([PASSES]u64);
        const interval = 1 * MILLI;
        for (0..PASSES) |i| {
            t.reset();
            std.Thread.sleep(interval);
            timings[i] = t.read();
        }
        const test_lower_bound: []const u64 = &.{ 2000, 1000, 500, 250, 100, 50, 5 };
        var lb = test_lower_bound[0] * MILLI;
        for (test_lower_bound) |tlb| {
            const tt = tlb * MICRO;
            lb = tt;
            t.reset();
            std.Thread.sleep(tt);
            const tx = t.read();
            if (tx < (tt * 3) / 4) {
                break;
            }
        }
        const stat = get_pos_max(timings[0..], interval);
        return This{
            .result = RtSleep{
                .lower_bound = lb,
                .pos_max_derivation = stat[0],
                .neg_max_derivation = stat[1],
            },
        };
    }
    fn get_pos_max(dat: []u64, cmp: u64) [2]u64 {
        var pos: u64 = 0;
        var neg: u64 = 0;
        var avg: f64 = 0;
        for (dat) |x| {
            const sp = sub_or_zero(x, cmp);
            const sn = sub_or_zero(cmp, x);
            pos = @max(sp, pos);
            neg = @max(sn, pos);
            const abs = @max(sp, sn);
            avg += @as(f64, @floatFromInt(abs)) / @as(f64, @floatFromInt(dat.len));
        }

        const fmt =
            \\
            \\ stats:
            \\ avg derivation = {d:.3}
            \\
        ;

        std.debug.print(fmt, .{avg / MILLI});
        return .{ pos, neg };
    }
    pub fn create_rt_sleep(self: *const This) RtSleep {
        return self.result;
    }
};

test "test sleeping" {
    std.testing.refAllDecls(@This());
    const rtso = RtsSleepOptimizer.init_measure_timings_on_local_thread() catch unreachable;
    const rst = rtso.create_rt_sleep();
    const fmt =
        \\
        \\RtSleep measurements:
        \\ lower bound : {}
        \\ max derivation negative: {}
        \\ max derivation positive: {}
        \\
    ;
    std.debug.print(fmt, .{
        rst.lower_bound,
        rst.neg_max_derivation,
        rst.pos_max_derivation,
    });
}

// NOTE:
// sleeping on windows is absolutlely no serious thing to consider
// as ist is for now it is in fact not usable at all for timed thread synchronization
// did not test on linux but with this mess in windows we have to find a better way than just infinetly polling on all threads:
