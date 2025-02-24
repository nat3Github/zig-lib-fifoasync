const std = @import("std");
const root = @import("../lib.zig");
const wthread = root.threads.wthread;
const Atomic = std.atomic.Value;
const Allocator = std.mem.Allocator;

const ResetEvent = std.Thread.ResetEvent;
const Timer = std.time.Timer;

pub const AtomicNanoSeconds = Atomic(u32);
pub const AtomicNanoSecondsNullValue = std.math.maxInt(u32);

pub const ScheduleWakeHandle = struct {
    const This = @This();
    re: *ResetEvent,
    att: *AtomicNanoSeconds,
    local_counter: u32 = 0,
    pub fn init(alloc: Allocator) !This {
        const vre = try alloc.create(ResetEvent);
        const vatt = try alloc.create(AtomicNanoSeconds.init(null));
        return This{
            .att = vatt,
            .re = vre,
        };
    }
    pub fn check(self: *This, time_progress_nano: u64, compensation: u64) void {
        const x = self.att.load(.acq_rel) orelse return;
        self.local_counter += time_progress_nano;
        if (self.local_counter + compensation >= x) {
            self.re.set();
            self.local_counter = 0;
            self.att.store(null, .acq_rel);
        }
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
        const T_Lthread = wthread.WThread(wthread.WThreadConfig.init().withT([cfg.slots]ScheduleWakeHandle).withResetEventLinked(*[2]ResetEvent));
        fn f(self: *[cfg.slots]ScheduleWakeHandle) !void {
            const handles = self[0..];
            const compensation: u64 = 0;
            var local_timer: Timer = Timer.start() catch unreachable;
            while (true) {
                local_timer.reset();
                var time_to_turn = local_timer.read();
                for (handles) |h| {
                    const time_diff = local_timer.read();
                    time_to_turn += time_diff;
                    h.check(time_to_turn, compensation);
                }
                compensation = (compensation + local_timer.read()) / 2;
            }
        }
        pub fn init(alloc: Allocator, hndles: [cfg.slots]ScheduleWakeHandle) !T_Lthread.InitReturnType {
            const re = try alloc.create([2]ResetEvent);
            for (re) |*r| r.* = ResetEvent{};
            const t = try T_Lthread.init(alloc, hndles, This.f, wthread.VoidType{}, wthread.VoidType{}, re, re);
            return This{ .thread = t };
        }
    };
}

test "test all refs" {
    std.testing.refAllDecls(@This());
}
