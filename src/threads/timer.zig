const std = @import("std");
const builtin = @import("builtin");
const print = std.debug.print;
const time = std.time;
const os = std.os;
const root = @import("../root.zig");

const win = struct {
    pub extern "kernel32" fn CreateWaitableTimerExW(
        lpTimerAttributes: ?*anyopaque,
        lpTimerName: ?[*:0]const u16,
        dwFlags: u32,
        dwDesiredAccess: u32,
    ) callconv(.WinAPI) os.windows.HANDLE;

    pub extern "kernel32" fn SetWaitableTimer(
        hTimer: os.windows.HANDLE,
        lpDueTime: *const i64,
        lPeriod: i32,
        pfnCompletionRoutine: ?*const anyopaque,
        lpArgToCompletionRoutine: ?*anyopaque,
        fResume: bool,
    ) callconv(.WinAPI) os.windows.BOOL;

    pub extern "kernel32" fn CancelWaitableTimer(
        hTimer: os.windows.HANDLE,
    ) callconv(.WinAPI) os.windows.BOOL;

    pub extern "kernel32" fn WaitForSingleObject(
        hHandle: os.windows.HANDLE,
        dwMilliseconds: u32,
    ) callconv(.WinAPI) u32;

    pub extern "kernel32" fn CloseHandle(
        hObject: os.windows.HANDLE,
    ) callconv(.WinAPI) os.windows.BOOL;

    const CREATE_WAITABLE_TIMER_HIGH_RESOLUTION = 0x00000002;
    const TIMER_ALL_ACCESS = 0x1F0003;
    const INFINITE = 0xFFFFFFFF;
};

const macos = struct {
    pub extern "c" fn mach_absolute_time() u64;
    pub extern "c" fn mach_wait_until(deadline: u64) void;
    pub const mach_timebase_info_data_t = struct {
        numer: u32,
        denom: u32,
    };
    pub extern "c" fn mach_timebase_info(info: *mach_timebase_info_data_t) void;
};

pub const Timer = if (builtin.os.tag == .linux)
    LinuxTimer
else if (builtin.os.tag == .macos)
    MacosTimer
else if (builtin.os.tag == .windows)
    WinTimer
else
    @compileError("not implemnted");

pub const Error = error{
    CreateTimerError,
    WindowsTimerCreationFailed,
    LinuxTimerCreationFailed,
};

const linux = struct {
    pub const CLOCK_MONOTONIC = os.linux.CLOCK_MONOTONIC;
    pub const sigevent = extern struct {
        sigev_value: os.linux.sigval_t,
        sigev_signo: i32,
        sigev_notify: i32,
        _sigev_un: os.linux.sigeventUnion,
    };
    pub const itimerspec = extern struct {
        it_interval: os.linux.timespec,
        it_value: os.linux.timespec,
    };
    pub extern "c" fn timer_create(
        clockid: os.linux.clockid_t,
        sevp: *const sigevent,
        timerid: *os.linux.timer_t,
    ) i32;
    pub extern "c" fn timer_settime(
        timerid: os.linux.timer_t,
        flags: i32,
        new_value: *const itimerspec,
        old_value: ?*itimerspec,
    ) i32;
    pub extern "c" fn timer_delete(timerid: os.linux.timer_t) i32;
};

pub const LinuxTimer = struct {
    timer_id: os.linux.timer_t,

    pub fn init() Error!@This() {
        var sev: linux.sigevent = undefined;
        sev.sigev_notify = os.linux.SIGEV_THREAD_ID;
        sev.sigev_signo = os.linux.SIGRTMIN;
        sev.sigev_value.sival_ptr = @ptrFromInt(0);
        sev._sigev_un._tid = os.linux.gettid();

        var timer_id: os.linux.timer_t = undefined;
        if (linux.timer_create(linux.CLOCK_MONOTONIC, &sev, &timer_id) == -1) {
            return error.LinuxTimerCreationFailed;
        }
        return .{ .timer_id = timer_id };
    }

    pub fn deinit(self: *@This()) void {
        _ = linux.timer_delete(self.timer_id);
    }

    pub fn rt_sleep(self: *@This(), duration_ns: u64) void {
        if (duration_ns == 0) {
            return;
        }

        var its = linux.itimerspec{
            .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
            .it_value = .{ .tv_sec = @intCast(duration_ns / 1_000_000_000), .tv_nsec = @intCast(duration_ns % 1_000_000_000) },
        };

        if (linux.timer_settime(self.timer_id, 0, &its, null) == -1) {
            print("Warning: Failed to set POSIX timer on Linux\n", .{});
            time.sleep(duration_ns);
            return;
        }
    }
};

pub const MacosTimer = struct {
    timebase_info: macos.mach_timebase_info_data_t,

    pub fn init() Error!@This() {
        var info: macos.mach_timebase_info_data_t = undefined;
        macos.mach_timebase_info(&info);
        return .{ .timebase_info = info };
    }

    pub fn deinit(_: *@This()) void {}

    pub fn rt_sleep(self: *@This(), duration_ns: u64) void {
        if (duration_ns == 0) {
            return;
        }
        const current_mach_time = macos.mach_absolute_time();
        const target_mach_time = current_mach_time + (duration_ns * self.timebase_info.denom) / self.timebase_info.numer;
        macos.mach_wait_until(target_mach_time);
    }
};

pub const WinTimer = struct {
    h_timer: os.windows.HANDLE,

    pub fn init() Error!@This() {
        const h_timer = win.CreateWaitableTimerExW(
            null,
            null,
            win.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
            win.TIMER_ALL_ACCESS,
        );
        if (h_timer == null) {
            return error.WindowsTimerCreationFailed;
        }
        return .{ .h_timer = h_timer };
    }

    pub fn deinit(self: *@This()) void {
        if (self.h_timer != null) {
            _ = win.CloseHandle(self.h_timer);
        }
    }

    pub fn rt_sleep(self: *@This(), duration_ns: u64) void {
        if (duration_ns == 0) {
            return;
        }

        var due_time_quad_part: i64 = -@as(i64, duration_ns / 100);
        const set_result = win.SetWaitableTimer(
            self.h_timer,
            &due_time_quad_part,
            0,
            null,
            null,
            false,
        );
        if (set_result == 0) {
            print("Warning: Failed to set waitable timer on Windows. Error: {d}\n", .{os.windows.kernel32.GetLastError()});
            time.sleep(duration_ns);
            return;
        }

        const wait_result = win.WaitForSingleObject(self.h_timer, win.INFINITE);
        if (wait_result != os.windows.WAIT_OBJECT_0) {
            print("Warning: WaitForSingleObject failed or timed out. Result: {d}\n", .{wait_result});
        }
        _ = win.CancelWaitableTimer(self.h_timer);
    }
};
