const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("../root.zig");

const assert = std.debug.assert;
const expect = std.testing.expect;

const Atomic = std.atomic.Value;
const AtomicOrder = std.builtin.AtomicOrder;
const AtomicBool = Atomic(bool);

const Type = std.builtin.Type;
const Task = root.sched.Task;

fn arg_tuple_from_fn_typeinfo(comptime Fn: Type.Fn) type {
    var fields: [Fn.params.len]Type.StructField = undefined;
    const params = Fn.params;
    inline for (&fields, params, 0..) |*field, param, i| {
        field.* = Type.StructField{
            .name = std.fmt.comptimePrint("{}", .{i}),
            .type = param.type.?,
            .alignment = 0,
            .default_value_ptr = null,
            .is_comptime = false,
        };
    }
    return @Type(Type{ .@"struct" = Type.Struct{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = true,
    } });
}

/// stores fn args and return data on the heap and wires a Task
/// to the fn that can be executed by an async executor by calling Task.call()
pub fn ASFuture(Fn: anytype) type {
    return struct {
        const FnT = @TypeOf(Fn);
        const FnArg = arg_tuple_from_fn_typeinfo(@typeInfo(FnT).@"fn");
        const FnRet = @typeInfo(FnT).@"fn".return_type.?;
        const fnc: *const FnT = Fn;
        // mutex: std.Thread.Mutex = std.Thread.Mutex{},
        task: Task = Task{},
        fnarg: FnArg = undefined,
        fnret: FnRet = undefined,
        blocked: AtomicBool = AtomicBool.init(false),

        pub fn init(alloc: Allocator) !*@This() {
            const this = try alloc.create(@This());
            this.* = @This(){};
            this.task.set(@This(), this, anyopaque_process);
            return this;
        }
        pub fn call(self: *@This(), args: FnArg, async_executor: anytype) !void {
            if (self.blocked.load(.acquire)) @panic("result is still pending");
            self.fnarg = args;
            self.blocked.store(true, .release);
            switch (@typeInfo(@typeInfo(@TypeOf(@TypeOf(async_executor).exe)).@"fn".return_type.?)) {
                .void => {
                    return async_executor.exe(&self.task);
                },
                else => {
                    return try async_executor.exe(&self.task);
                },
            }
        }
        pub fn result_ready(self: *@This()) bool {
            return !self.blocked.load(.acquire);
        }
        pub fn result(self: *@This()) FnRet {
            if (self.blocked.load(.acquire)) @panic("result still pending");
            return self.fnret;
        }

        pub fn deinit(self: *@This(), alloc: Allocator) void {
            alloc.destroy(self);
        }
        fn process_fn(self: *@This()) void {
            self.fnret = @call(.auto, @This().fnc, self.fnarg);
            self.blocked.store(false, .release);
        }
        fn anyopaque_process(p: *anyopaque) void {
            const self: *@This() = @alignCast(@ptrCast(p));
            self.process_fn();
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
