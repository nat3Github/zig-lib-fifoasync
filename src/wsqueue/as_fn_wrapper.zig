const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("../root.zig");

const assert = std.debug.assert;
const expect = std.testing.expect;

const Atomic = std.atomic.Value;
const AtomicOrder = std.builtin.AtomicOrder;

const Type = std.builtin.Type;
const Task = root.sched.Task;

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
pub fn ASFuture(Fn: anytype) type {
    return struct {
        const FnT = @TypeOf(Fn);
        const FnArg = arg_tuple_from_fn(FnT); //arg_tuple_from_fn_typeinfo(@typeInfo(FnT).@"fn");
        const FnRet = @typeInfo(FnT).@"fn".return_type.?;
        const fnc: *const FnT = Fn;

        task: Task = Task{},
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
            self.task.set(@This(), self, anyopaque_run);
            if (@TypeOf(async_executor) == *std.Thread.Pool) {
                const pool: *std.Thread.Pool = async_executor;
                return try pool.spawn(Task.call, .{&self.task});
            }
            switch (@typeInfo(@typeInfo(@TypeOf(@TypeOf(async_executor).exe)).@"fn".return_type.?)) {
                .void => {
                    return async_executor.exe(&self.task);
                },
                else => {
                    return try async_executor.exe(&self.task);
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

test "test asnode" {
    const m = struct {
        pub fn hello_world(arg1: u32, arg2: u8) !void {
            std.log.debug("hello world with {} : {}, {} : {}", .{
                arg1,
                @TypeOf(arg1),
                arg2,
                @TypeOf(arg2),
            });
        }
    };

    const alloc = std.testing.allocator;
    const Sched = root.sched.DefaultSched;

    var ps = try Sched.init(alloc, 2, 1);

    const as1 = ps.get_async_executor(0, 0);
    const AShello_world = ASFuture(m.hello_world);
    const ashello = try AShello_world.init(alloc);
    defer ashello.deinit(alloc);
    try ashello.call(.{ 12, 255 }, as1);

    std.Thread.sleep(200e6);
    std.Thread.sleep(20e6);

    ps.shutdown() catch unreachable;
    ps.deinit();
}
