const std = @import("std");
const root = @import("../lib.zig");
const wthread = root.threads.wthread;
const Atomic = std.atomic.Value;
const Allocator = std.mem.Allocator;

const ResetEvent = std.Thread.ResetEvent;
const Timer = std.time.Timer;

pub const AtomicU32 = Atomic(u32);
pub const SchedTime = struct {
    const NullValue: u32 = std.math.maxInt(u32);
    const This = @This();
    __value: *AtomicU32,
    /// init self with null value
    pub fn init(gpa: Allocator) !This {
        const v = try gpa.create(AtomicU32);
        v.* = AtomicU32.init(NullValue);
        return This{ .__value = v };
    }
    pub fn get_val(self: *const This) ?u32 {
        const val = self.__value.load(.acquire);
        if (val == NullValue) return null else return val;
    }
    pub fn set_val(self: *const This, val: ?u32) void {
        if (val) |v| {
            std.debug.assert(v != NullValue);
            self.__value.store(v, .release);
        } else self.__value.store(NullValue, .release);
    }
};

pub const SchedHandle = struct {
    const This = @This();
    re: *ResetEvent,
    att: SchedTime,
    local_counter: u32 = 0,
    pub fn init(alloc: Allocator) !This {
        const vre = try alloc.create(ResetEvent);
        const vatt = try SchedTime.init(alloc);
        return This{
            .att = vatt,
            .re = vre,
        };
    }
    pub fn check(self: *This, time_progress_nano: u32, compensation: u64) void {
        const x = self.att.get_val() orelse return;
        self.local_counter += time_progress_nano;
        if (self.local_counter + compensation >= x) {
            self.re.set();
            self.local_counter = 0;
            self.att.set_val(null);
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
        const T_Lthread = wthread.WThread(wthread.WThreadConfig.init().withT([cfg.slots]SchedHandle).withResetEventLinked(*[2]ResetEvent));
        fn f(self: *[cfg.slots]SchedHandle) !void {
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
        pub fn init(alloc: Allocator, hndles: [cfg.slots]SchedHandle) !T_Lthread.InitReturnType {
            const re = try alloc.create([2]ResetEvent);
            for (re) |*r| r.* = ResetEvent{};
            const t = try T_Lthread.init(alloc, hndles, This.f, wthread.VoidType{}, wthread.VoidType{}, re, re);
            return This{ .thread = t };
        }
    };
}

test "test all refs" {
    std.testing.refAllDeclsRecursive(@This());
}
