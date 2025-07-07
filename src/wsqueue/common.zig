const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("../root.zig");

const assert = std.debug.assert;
const expect = std.testing.expect;

const Atomic = std.atomic.Value;
const AtomicOrder = std.builtin.AtomicOrder;

const Type = std.builtin.Type;

/// Generic type erased Task
/// if arguments or return values are needed they must be somehow stored in the instance
pub const Task = struct {
    const This = @This();
    instance: ?*anyopaque = null,
    task: ?*const fn (*anyopaque) void = null,
    /// the t_fn must re-cast the *anyopaque pointer to *T
    pub fn set(self: *This, T: type, t_ptr: *T, t_fn: *const fn (*anyopaque) void) void {
        const cast: *anyopaque = @ptrCast(t_ptr);
        self.instance = cast;
        self.task = t_fn;
    }
    pub fn call(self: This) void {
        if (self.instance) |inst| {
            @call(.auto, self.task.?, .{inst});
        }
    }
};

fn arg_tuple_from_fn(comptime f: type) type {
    assert(comptime @typeInfo(f).@"fn".calling_convention != .@"inline");
    return std.meta.ArgsTuple(f);
}

const TaskState = enum(u8) {
    const default: TaskState = .unitialized;
    unitialized,
    running,
    finished,
};

/// stores fn args and return data and wires a Task
/// to the fn that can be executed by an async executor by calling Task.call()
/// make sure the memory is defined for the duration of the async call!
/// call join to wait for the end of the task!
pub fn ASFunction(Fn: anytype) type {
    return struct {
        const FnT = @TypeOf(Fn);
        const FnArg = arg_tuple_from_fn(FnT); //arg_tuple_from_fn_typeinfo(@typeInfo(FnT).@"fn");
        const FnRet = @typeInfo(FnT).@"fn".return_type.?;
        const fnc: *const FnT = Fn;

        fnarg: FnArg = undefined,
        fnret: FnRet = undefined,
        state: Atomic(TaskState) = Atomic(TaskState).init(.default),
        re: std.Thread.ResetEvent = .{},

        pub fn join(self: *@This()) void {
            if (self.state.load(.acquire) != .unitialized) {
                if (!self.result_ready()) {
                    self.re.wait();
                }
                while (!self.result_ready()) {}
            }
        }
        /// NOTE the Memory of *@This() must remain well defined till the task has finished !!!
        pub inline fn call(self: *@This(), args: FnArg, async_executor: anytype) !void {
            if (self.is_running()) return error.TaskIsBusy;
            self.fnarg = args;
            self.state.store(.running, .release);
            self.re.reset();
            var task = Task{};
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
        pub inline fn is_running(self: *@This()) bool {
            return self.state.load(.acquire) == .running;
        }
        inline fn result_ready(self: *@This()) bool {
            return self.state.load(.acquire) == .finished;
        }
        pub inline fn result(self: *@This()) ?FnRet {
            if (self.result_ready()) return self.fnret else return null;
        }
        fn anyopaque_run(p: *anyopaque) void {
            const self: *@This() = @alignCast(@ptrCast(p));
            self.fnret = @call(.auto, @This().fnc, self.fnarg);
            self.re.set();
            self.state.store(.finished, .release);
        }
    };
}

pub const AsyncExecutor = struct {
    ptr: *anyopaque,
    f: *const fn (*anyopaque, Task) anyerror!void,
    pub fn execute(Self: AsyncExecutor, task: Task) !void {
        return Self.f(Self.ptr, task);
    }
};

pub fn GenericAsyncExecutor(T: type, f_exe: *const fn (*T, Task) anyerror!void) type {
    return struct {
        inner: T,
        const This = @This();
        pub fn async_executor(self: *@This()) AsyncExecutor {
            const m = struct {
                fn any_exe(ptr: *anyopaque, task: Task) anyerror!void {
                    const this: *This = @alignCast(@ptrCast(ptr));
                    return f_exe(&this.inner, task);
                }
            };
            return root.sched.AsyncExecutor{ .ptr = self, .f = m.any_exe };
        }
    };
}
