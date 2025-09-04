const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("../root.zig");

const assert = std.debug.assert;
const expect = std.testing.expect;

const Atomic = std.atomic.Value;
const AtomicOrder = std.builtin.AtomicOrder;

const Type = std.builtin.Type;

const Cancelled = error{Cancelled};
const common = @This();

pub const TaskContext = struct {
    pub const Cancelled = common.Cancelled;
    ptr: *anyopaque = undefined,
    yield_fn: ?*const fn (*anyopaque) TaskContext.Cancelled!void = null,
    pub fn yield(self: *const @This()) TaskContext.Cancelled!void {
        try self.yield_fn(self.ptr);
    }
};

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
        if (x[0] == AsyncExecutor) {
            return std.meta.Tuple(x[1..]);
        } else return std.meta.Tuple(x[0..]);
    }
}

const TaskState = enum(u8) {
    none,
    busy,
    has_result,
};

/// stores fn args and return data and wires a Task
/// to the fn that can be executed by an async executor by calling Task.call()
/// make sure the memory is defined for the duration of the async call!
/// call join to wait for the end of the task!
///
/// you can use AsyncExecutor.yield() for cooperative yielding and cancelation
/// (will only have an effect if its supported by the AsyncExecutor)
/// if the first argument of Fn is of type AsyncExecutor Fn, will be passed the AsyncExecutor it was called with
pub fn ASFunction(Fn: anytype) type {
    const FnT = @TypeOf(Fn);
    const FnArgs = filtered_arg_tuple(std.meta.ArgsTuple(FnT));
    comptime if (@typeInfo(FnT).@"fn".calling_convention == .@"inline") @panic("inlined functions do not work with ASFunction, please use a normal fn!");
    return struct {
        pub const ReturnType = @typeInfo(FnT).@"fn".return_type.?;
        const fnc: *const FnT = Fn;

        fnarg: FnArgs = undefined,
        fnret: ReturnType = undefined,
        state: Atomic(TaskState) = Atomic(TaskState).init(.none),
        re: std.Thread.ResetEvent = .{},

        pub fn join(self: *@This()) void {
            if (self.state.load(.acquire) == .none) return;
            var t: u32 = 1;
            while (!self.has_result()) {
                self.re.timedWait(1_000_000_000) catch {
                    std.debug.print("ASFunction: waiting for join ..{} s elapsed\n", .{t});
                    t += 1;
                };
            }
            while (!self.has_result()) {}
        }
        /// NOTE the Memory of *@This() must remain well defined till the task has finished !!!
        /// threadsafe
        pub inline fn call(
            self: *@This(),
            async_executor: anytype,
            args: FnArgs,
        ) !void {
            if (self.is_running()) return error.TaskIsBusy;
            self.fnarg = args;
            self.state.store(.busy, .release);
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
        inline fn task_state(self: *@This()) TaskState {
            return self.state.load(.acquire);
        }
        /// threadsafe
        pub inline fn is_running(self: *@This()) bool {
            return self.state.load(.acquire) == .busy;
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
        fn anyopaque_run(p: *anyopaque, as_exe: AsyncExecutor) void {
            const self: *@This() = @alignCast(@ptrCast(p));
            if (comptime @typeInfo(FnArgs).@"struct".fields.len != @typeInfo(FnT).@"fn".params.len) {
                self.fnret = @call(.auto, @This().fnc, .{as_exe} ++ self.fnarg);
            } else {
                self.fnret = @call(.auto, @This().fnc, self.fnarg);
            }
            self.re.set();
            self.state.store(.has_result, .release);
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
                const pp: *std.Thread.Pool = @alignCast(@ptrCast(p));
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
