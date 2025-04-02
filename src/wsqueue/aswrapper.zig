const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("../lib.zig");
const Timer = std.time.Timer;

const assert = std.debug.assert;
const expect = std.testing.expect;

const Atomic = std.atomic.Value;
const AtomicOrder = std.builtin.AtomicOrder;
const AtomicU8 = Atomic(u8);
const AtomicU32 = Atomic(u32);
const AtomicBool = Atomic(bool);
const ResetEvent = std.Thread.ResetEvent;

const ExStruct = struct {
    const This = @This();
    pub fn doosomething(self: *This) u32 {
        _ = .{self};
        return 0;
    }
    pub fn doosomething2(self: *This, arg1: u32, arg2: u8) !void {
        _ = .{ self, arg1, arg2 };
    }
    pub fn extra(arg1: u32, arg2: u8) !void {
        std.log.warn("fn extra called with {}:{}, {}:{}", .{
            arg1,
            @TypeOf(arg1),
            arg2,
            @TypeOf(arg2),
        });
    }
};

fn decl_is_fn(T: type, decl: Type.Declaration) bool {
    const F = @field(T, decl.name);
    return switch (@typeInfo(@TypeOf(F))) {
        .@"fn" => true,
        else => false,
    };
}
const Type = std.builtin.Type;
fn pub_fn_num(T: type) usize {
    comptime var fn_num: usize = 0;
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            inline for (s.decls) |decl| {
                if (decl_is_fn(T, decl)) fn_num += 1;
            }
        },
        .@"enum" => |s| {
            inline for (s.decls) |decl| {
                if (decl_is_fn(T, decl)) fn_num += 1;
            }
        },
        .@"union" => |s| {
            inline for (s.decls) |decl| {
                if (decl_is_fn(T, decl)) fn_num += 1;
            }
        },
        else => @compileError("wrong type"),
    }
    return fn_num;
}
const FnTypeInfo = struct {
    decl: Type.Declaration,
    fn_type_info: Type.Fn,
};

fn pub_fn_type_info(T: type) [pub_fn_num(T)]FnTypeInfo {
    comptime var i: usize = 0;
    var fn_types: [pub_fn_num(T)]FnTypeInfo = undefined;
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            inline for (s.decls) |decl| {
                const F = @field(T, decl.name);
                switch (@typeInfo(@TypeOf(F))) {
                    .@"fn" => |f| {
                        fn_types[i] = .{
                            .decl = decl,
                            .fn_type_info = f,
                        };
                        i += 1;
                    },
                    else => {},
                }
            }
        },
        .@"enum" => |s| {
            inline for (s.decls) |decl| {
                const F = @field(T, decl.name);
                return switch (@typeInfo(@TypeOf(F))) {
                    .@"fn" => {
                        fn_types[i] = .{
                            .decl = decl,
                            .fn_type_info = @typeInfo(@TypeOf(F)).@"fn",
                        };
                        i += 1;
                    },
                    else => {},
                };
            }
        },
        .@"union" => |s| {
            inline for (s.decls) |decl| {
                const F = @field(T, decl.name);
                return switch (@typeInfo(@TypeOf(F))) {
                    .@"fn" => {
                        fn_types[i] = .{
                            .decl = decl,
                            .fn_type_info = @typeInfo(@TypeOf(F)).@"fn",
                        };
                        i += 1;
                    },
                    else => {},
                };
            }
        },
        else => @compileError("wrong type"),
    }
    return fn_types;
}

fn enum_from_pub_fn_decl(comptime T: type) type {
    const fns = pub_fn_type_info(T);
    var fields: [fns.len]Type.EnumField = undefined;
    inline for (&fields, &fns, 0..) |*field, x, i| {
        field.* = Type.EnumField{
            .name = x.decl.name,
            .value = i,
        };
    }
    const decls: []const Type.Declaration = &.{};
    return @Type(.{
        .@"enum" = .{
            .tag_type = u32,
            .fields = &fields,
            .decls = decls,
            .is_exhaustive = true,
        },
    });
}
fn arg_tuple_from_fn_typeinfo_without_first_param(comptime Fn: Type.Fn) type {
    if (Fn.params.len == 0) return arg_tuple_from_fn_typeinfo(Fn);
    var fields: [Fn.params.len - 1]Type.StructField = undefined;
    const params = Fn.params[1..];
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

fn tagged_arg_union_from_pub_fn(comptime T: type) type {
    const fns = pub_fn_type_info(T);
    var fields: [fns.len]Type.UnionField = undefined;
    inline for (&fields, &fns) |*field, x| {
        field.* = Type.UnionField{
            .alignment = 0,
            .name = x.decl.name,
            .type = arg_tuple_from_fn_typeinfo(x.fn_type_info),
        };
    }
    const decls: []const Type.Declaration = &.{};
    return @Type(Type{
        .@"union" = Type.Union{
            .tag_type = enum_from_pub_fn_decl(T),
            .layout = .auto,
            .fields = &fields,
            .decls = decls,
        },
    });
}

fn tagged_return_union_from_pub_fn(comptime T: type) type {
    const fns = pub_fn_type_info(T);
    var fields: [fns.len]Type.UnionField = undefined;
    inline for (&fields, &fns) |*field, x| {
        field.* = Type.UnionField{
            .alignment = 0,
            .name = x.decl.name,
            .type = x.fn_type_info.return_type.?,
        };
    }
    const decls: []const Type.Declaration = &.{};
    return @Type(Type{
        .@"union" = Type.Union{
            .tag_type = enum_from_pub_fn_decl(T),
            .layout = .auto,
            .fields = &fields,
            .decls = decls,
        },
    });
}

fn tagged_enum_from_struct_pub_fn(comptime T: type) type {
    const type_info = @typeInfo(T);
    std.debug.assert(type_info == .@"struct");
    const struct_decls = type_info.@"struct".decls;
    comptime var fn_num: usize = 0;
    inline for (struct_decls) |decl| {
        if (decl_is_fn(T, decl)) fn_num += 1;
    }
    var fields: [fn_num]Type.EnumField = undefined;
    fn_num = 0;
    inline for (struct_decls) |decl| {
        if (decl_is_fn(T, decl)) {
            fields[fn_num] = Type.EnumField{
                .name = decl.name,
                .value = fn_num,
            };
            fn_num += 1;
        }
    }
    const decls: []const Type.Declaration = &.{};
    return @Type(.{
        .@"enum" = .{
            .tag_type = u32,
            .fields = &fields,
            .decls = decls,
            .is_exhaustive = true,
        },
    });
}

const ASWrapperConfig = struct {
    wrapped_t: type,
};

/// wraps T for async calling via comptime generated tagged unions from pub fn of T
/// fn set_fn sets the fn with given arguments
/// some backend can use the *Task or process_fn() to execute
/// result can be checked by is_result_ready()
/// result can be gathered by result()
const Task = root.prioque.Task;
pub fn ASNode(wrapped_t: type) type {
    return struct {
        const This = @This();
        // const wrapped_t = cfg.wrapped_t;
        // const FnTable = fn_table_from_pub_fn(wrapped_t);
        const FnInfoOfT = pub_fn_type_info(wrapped_t);
        const FnEnum = enum_from_pub_fn_decl(wrapped_t);
        const FnArg = tagged_arg_union_from_pub_fn(wrapped_t);
        const FnRet = tagged_return_union_from_pub_fn(wrapped_t);

        t: wrapped_t,
        mutex: std.Thread.Mutex = std.Thread.Mutex{},
        task: *Task,
        fnarg: FnArg = undefined,
        fnret: FnRet = undefined,
        blocked: AtomicBool = AtomicBool.init(false),

        pub fn init(alloc: Allocator, t: wrapped_t) !*This {
            const this = try alloc.create(This);
            // p .task = try Task.init(alloc),rocess_task.set(This, t, anyopaque_process);
            const task = try Task.init(alloc);
            this.* = This{
                .t = t,
                .task = task,
            };
            task.set(This, this, anyopaque_process);
            return this;
        }

        pub fn set_fn(self: *This, function: FnArg) !void {
            if (self.mutex.tryLock()) {
                self.fnarg = function;
                self.blocked.store(true, .release);
                self.mutex.unlock();
            } else return error.NodeWasLocked;
        }

        pub fn is_result_ready(self: *This) bool {
            if (self.blocked.load(.acquire)) return false;
            if (self.mutex.tryLock()) {
                self.mutex.unlock();
                return true;
            } else return false;
        }
        /// panics if function tag is different from set_fn
        /// panics if not ready
        /// the result can be gathered till the set_fn call
        pub fn result(self: *This, comptime function: FnEnum) FnInfoOfT[@intFromEnum(function)].fn_type_info.return_type.? {
            if (self.blocked.load(.acquire)) unreachable;
            if (self.mutex.tryLock()) {
                const tag_idx = @intFromEnum(function);
                switch (tag_idx) {
                    inline 0...FnInfoOfT.len - 1 => |idx| {
                        const en: FnEnum = @enumFromInt(idx);
                        const ret = @field(self.fnret, @tagName(en));
                        self.mutex.unlock();
                        return ret;
                    },
                    else => unreachable,
                }
            } else unreachable;
        }

        pub fn deinit(self: *This, alloc: Allocator) void {
            self.task.deinit(alloc);
            alloc.destroy(self);
        }
        pub fn process_fn(self: *This) void {
            if (self.mutex.tryLock()) {
                const args: FnArg = self.fnarg;
                const tag_idx = @intFromEnum(args);
                switch (tag_idx) {
                    inline 0...FnInfoOfT.len - 1 => |idx| {
                        const en: FnEnum = @enumFromInt(idx);
                        const arg = @field(args, @tagName(en));
                        const decl = FnInfoOfT[idx].decl.name;
                        const f = @field(wrapped_t, decl);
                        const ret = @call(.auto, f, arg);
                        const ret_union = @unionInit(FnRet, @tagName(en), ret);
                        self.fnret = ret_union;
                        self.blocked.store(false, .release);
                    },
                    else => unreachable,
                }
                self.mutex.unlock();
            } else @panic("mutex of asnode was locked");
        }
        pub fn anyopaque_process(p: *anyopaque) void {
            const self: *This = @alignCast(@ptrCast(p));
            self.process_fn();
        }
    };
}

test "test asnode" {
    const alloc = std.testing.allocator;
    const ExAsNode = ASNode(ExStruct);
    const wrapped = ExStruct{};
    var asn = try ExAsNode.init(alloc, wrapped);
    defer asn.deinit(alloc);
    asn.set_fn(.{ .extra = .{ 0, 1 } }) catch unreachable;
    try expect(asn.is_result_ready() == false);
    ExAsNode.anyopaque_process(@ptrCast(asn));
    try expect(asn.is_result_ready() == true);
    const res = asn.result(.extra);
    if (res) |r| {
        std.log.warn("{}", .{r});
    } else |e| return e;
}
