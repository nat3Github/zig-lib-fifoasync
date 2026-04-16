const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const root = @import("../root.zig");

const assert = std.debug.assert;
const expect = std.testing.expect;

const Atomic = std.atomic.Value;
const AtomicOrder = std.builtin.AtomicOrder;

const Type = std.builtin.Type;
const is_debug = builtin.mode == .Debug;

pub const Cancelled = error{Cancelled};
pub const Timeout = error{Timeout};
const common = @This();

/// Generic type erased Task
/// if arguments or return values are needed they must be somehow stored in the instance
///
/// its easier to use `ASFunction` which is a helpful wrapper for Task
pub const Task = struct {
    data: *anyopaque,
    task_fn: *const fn (*anyopaque, AsyncExecutor) void,
    /// the t_fn must re-cast the *anyopaque pointer to *T
    pub inline fn set(self: *Task, T: type, t_ptr: *T, t_fn: *const fn (*anyopaque, AsyncExecutor) void) void {
        const cast: *anyopaque = @ptrCast(t_ptr);
        self.data = cast;
        self.task_fn = t_fn;
    }
    /// calls the fn ptr of the Task, with its payload
    /// this fn is to be called by an AsyncExecutor
    ///
    /// pass AsyncExecutor as exec that the Task can decide to yield!
    pub fn call(self: Task, exec: AsyncExecutor) void {
        self.task_fn(self.data, exec);
    }
};

/// filters Task.Context from a Argument Tuple if its in first place
fn filtered_arg_tuple(comptime T: type) type {
    comptime {
        const t = @typeInfo(T).@"struct";
        const len = t.fields.len;
        if (len == 0) return T;
        var x: [len]type = undefined;
        for (t.fields, &x) |f, *y| y.* = f.type;
        if (x[0] == TaskContext) {
            return std.meta.Tuple(x[1..]);
        } else return std.meta.Tuple(x[0..]);
    }
}
/// can be used by Fn in ASFunction to yield cooperatively (enables efficient task cancelling!)
pub const TaskContext = struct {
    state: *Atomic(TaskState),
    exec: AsyncExecutor,
    pub fn yield(self: *const @This()) Cancelled!void {
        if (self.state.load(.acquire) == .busy_cancelling) return Cancelled.Cancelled;
        try self.exec.yield();
    }
    const LockError = Timeout || Cancelled;
    /// tries to aquire the mutex and returns
    pub fn try_lock(self: *const @This(), mtx: *std.Thread.Mutex, how_often: usize) LockError!void {
        _ = try_lock: {
            for (0..how_often) |_| if (!mtx.tryLock()) {
                try self.yield();
                break :try_lock;
            };
            return Timeout.Timeout;
        };
    }
};

const TaskState = enum(u8) {
    none = 0,
    has_result = 1,
    busy_submitted = 2,
    busy_cancelling = 3,

    /// the task is in it busy / locked state. result and fn args cant be touched
    pub fn is_busy(Self: TaskState) bool {
        return @intFromEnum(Self) >= @intFromEnum(TaskState.busy_submitted);
    }
};

/// stores fn args and return data and wires a Task
/// to the fn that can be executed by an async executor by calling Task.call()
/// make sure the memory is defined for the duration of the async call!
/// call join to wait for the end of the task!
///
/// you can use TaskContext.yield() for cooperative yielding and cancelation
/// if the first argument of Fn is of type TaskContext, Fn will be passed a TaskContext for cooperative yielding
pub fn ASFunction(
    Fn: anytype,
) type {
    const FnT = @TypeOf(Fn);
    const FnArgs = filtered_arg_tuple(std.meta.ArgsTuple(FnT));
    comptime if (@typeInfo(FnT).@"fn".calling_convention == .@"inline") @panic("inlined functions do not work with ASFunction, please use a normal fn!");
    const R = @typeInfo(FnT).@"fn".return_type.?;
    // NOTE: if compiliation failes here your Fn is not returning an error
    const E = @typeInfo(R).error_union.error_set;
    // NOTE: if compilation failes here your Fn is returning an error that does not include "Cancelled"
    comptime assert(blk: {
        const es = @typeInfo(E).error_set;
        if (es == null) break :blk true;
        for (es.?) |err| {
            if (std.mem.eql(u8, err.name, "Cancelled")) break :blk true;
        }
        break :blk false;
    });

    return struct {
        const fnc: *const FnT = Fn;
        pub const ReturnType = R;
        fnarg: FnArgs = undefined,
        fnret: ReturnType = undefined,
        state: Atomic(TaskState) = Atomic(TaskState).init(.none),
        re: std.Thread.ResetEvent = .{},
        pub fn join_timeout(self: *@This(), timeout_ns: u64) void {
            if (self.state.load(.acquire) == .none) return;
            self.re.timedWait(timeout_ns) catch @panic("join timeout");
            while (!self.has_result()) {}
        }

        pub fn join_block(self: *@This()) void {
            if (self.state.load(.acquire) == .none) return;
            var t: u32 = 1;
            while (!self.has_result()) {
                self.re.timedWait(2_000_000_000) catch {
                    std.debug.print("async fn {s}: waiting for join ..{} s elapsed\n", .{ @typeName(FnT), t * 2 });
                    t += 1;
                };
            }
            while (!self.has_result()) {}
        }

        pub fn join(self: *@This(), tc: ?TaskContext) void {
            if (self.state.load(.acquire) == .none) return;
            var xt = std.time.Timer.start() catch unreachable;
            while (!self.has_result()) {
                if (tc) |tc_| tc_.yield() catch {};
                if (is_debug) {
                    if (xt.read() % 2_000_000_000 == 0) {
                        std.log.err("async fn {s}: waiting for join ..{} s elapsed\n", .{ @typeName(FnT), xt.read() / 1_000_000_000 });
                    }
                }
            }
        }
        /// will call the function asynchronously, your fn will be called even if it was cancelled!
        /// this is important because you potentially are doing something that absolutely must be done
        /// i.e. deinitialize some state / handle an error etc.
        ///
        /// use cooperative yielding via the TaskContext
        ///
        /// threadsafe
        /// NOTE the Memory of *@This() must live till the task has finished!
        /// NOTE the fn must be able to fail if you use the TaskContext
        /// NOTE the fn MUST NOT be inline as of (zig 0.15.1)
        pub inline fn call(self: *@This(), async_executor: anytype, args: FnArgs) !void {
            if (self.is_running()) return error.TaskIsBusy;
            self.fnarg = args;
            self.state.store(.busy_submitted, .release);
            self.re.reset();
            var task: Task = undefined;
            task.set(@This(), self, anyopaque_run);
            if (@TypeOf(async_executor) == *std.Thread.Pool) {
                const pool: *std.Thread.Pool = async_executor;
                return try pool.spawn(Task.call, .{task});
            }
            if (@TypeOf(async_executor) == AsyncExecutor) {
                return try async_executor.execute(task);
            }
            switch (@typeInfo(@typeInfo(@TypeOf(@TypeOf(async_executor).exe)).@"fn".return_type.?)) {
                .void => {
                    return async_executor.exe(task);
                },
                else => {
                    return try async_executor.exe(task);
                },
            }
        }
        pub inline fn get_task_state(self: *@This()) TaskState {
            return self.state.load(.acquire);
        }
        /// threadsafe
        pub inline fn is_running(self: *@This()) bool {
            return self.get_task_state().is_busy();
        }
        /// threadsafe
        inline fn has_result(self: *@This()) bool {
            return self.state.load(.acquire) == .has_result;
        }
        /// threadsafe
        /// note: you can only handle a result once repeated calls will return null
        pub inline fn result(self: *@This()) ?ReturnType {
            if (!self.has_result()) return null;
            const res = self.fnret;
            self.state.store(.none, .release);
            return res;
        }
        /// cancel a running task
        /// works only with cooperative yielding (the Task must call TaskContext.yield() on its own)
        pub inline fn cancel(self: *@This()) void {
            _ = self.state.cmpxchgStrong(.busy_submitted, .busy_cancelling, .seq_cst, .seq_cst);
        }
        /// NOTE(nat3) you cannot just check if the task is cancelled and refrain to call it!
        /// this is unintuitive to the user
        /// the user might deinitialize some state / do some error handling or other important things
        /// the task_fn returns error.Cancelled so the user expects the natural error handling flow
        /// thats why yielding/and canceling must be deployed!
        fn anyopaque_run(p: *anyopaque, as_exe: AsyncExecutor) void {
            const self: *@This() = @ptrCast(@alignCast(p));
            if (comptime @typeInfo(FnArgs).@"struct".fields.len != @typeInfo(FnT).@"fn".params.len) {
                const ctx = self.task_context(as_exe);
                self.fnret = @call(.auto, @This().fnc, .{ctx} ++ self.fnarg);
            } else {
                self.fnret = @call(.auto, @This().fnc, self.fnarg);
            }
            self.re.set();
            self.state.store(.has_result, .release);
        }
        pub fn task_context(self: *@This(), exe: AsyncExecutor) TaskContext {
            return TaskContext{
                .exec = exe,
                .state = &self.state,
            };
        }
    };
}

pub const AsyncExecutor = struct {
    ptr: *anyopaque,
    vtable: *const AsyncExecutorVtable,
    pub fn execute(Self: AsyncExecutor, task: Task) !void {
        return Self.vtable.execute_task_fn(Self.ptr, task);
    }
    pub fn yield(Self: AsyncExecutor) error{Cancelled}!void {
        return Self.vtable.yield_fn(Self.ptr);
    }
    pub fn from_std_pool(pool: *std.Thread.Pool) AsyncExecutor {
        const m = struct {
            fn f(p: *anyopaque, t: Task) anyerror!void {
                const pp: *std.Thread.Pool = @ptrCast(@alignCast(p));
                try pp.spawn(Task.call, .{t});
            }
        };
        return AsyncExecutor{
            .ptr = pool,
            .f = &m.f,
        };
    }
};

pub const AsyncExecutorVtable = struct {
    execute_task_fn: *const fn (*anyopaque, Task) anyerror!void,
    yield_fn: *const fn (*anyopaque) error{Cancelled}!void = __no_yield,
};

fn __no_yield(_: *anyopaque) error{Cancelled}!void {}
