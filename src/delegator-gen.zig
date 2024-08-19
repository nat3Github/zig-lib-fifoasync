const std = @import("std");
pub const ziggen = @import("ziggen");
// pub const check_ast_write_src_code = @import("ziggen.zig").check_ast_write_src_code;
const zmeta = ziggen.meta;
const zfmt = ziggen.fmt(true);
const Type = std.builtin.Type;
const join = zfmt.join;
const comptimePrint = std.fmt.comptimePrint;
pub fn code_gen2() []const u8 {
    return comptime ziggen.fmt(true).fStruct("mystruct", "const x = hello world;\n_ = x;");
}
pub fn code_gen3() []const u8 {
    return "hello world";
}
pub fn write_src_file(b: *std.Build, path: std.Build.LazyPath) !void {
    try ziggen.write_src_code(b, path, code_gen2());
}
/// generates boilerplate source code for turning a struct into a Delegator which forwards the struct fn calls as Union Enum Messages
/// will only generate functions which are pub
/// to work properly you must import the file that defines T
/// and other files which types are used in the methods of T
/// std is already imported
pub fn code_gen(
    comptime T: type,
    comptime nameof_T: []const u8,
    comptime name: []const u8,
    /// imports are naively inserted at the top of the generated file
    comptime imports: []const u8,
) [:0]const u8 {
    if (!comptime zmeta.isStruct(T)) {
        @compileError("expected T to be of type Struct");
    }

    const parts = struct {
        const TName = nameof_T;
        const TNameTag = name ++ "Decls";
        const TNameParamUnion = name ++ "Args";
        const TNameReturnUnion = name ++ "Ret";
        const decls = zmeta.struct_decl_names(T);
        const comptime_decl_check = zfmt.fHasDeclCompileCheck("Server", "send", "the server type is missing the send method");
        const Ttypename = @typeName(T);

        fn delegator_fn_str() []const u8 {
            comptime var slc: [decls.len][]const u8 = undefined;
            inline for (decls, &slc) |decl, *si| {
                const args_type = comptime zmeta.decl_arglist_without_selfpointer(T, decl);
                const args_id = comptime zfmt.default_arg_id_list(args_type.len);
                // param-union, decl, args
                const bodyfmt =
                    \\const msg = {s}{{
                    \\.{s} = .{{{s}}} 
                    \\}};
                    \\try self.channel.send(msg);
                ;
                const msg_args = comptime join(", ", args_id);
                const body = comptime std.fmt.comptimePrint(bodyfmt, .{ TNameParamUnion, decl, msg_args });
                comptime var args: []const u8 = std.fmt.comptimePrint("self: *@This(), {s}", .{zfmt.combine_arg_lists_comma_seperated(args_id, args_type)});
                if (comptime args_id.len == 0) {
                    args = "self: *@This()";
                }
                si.* = comptime zfmt.fFn(decl, args, "!void", body);
            }
            return comptime join("\n", &slc);
        }
        //todo: calling convention for selfref vs not selfref
        fn message_handler() []const u8 {
            comptime var slc: [decls.len][]const u8 = undefined;
            inline for (decls, &slc) |decl, *scli_i| {
                const args = comptime zmeta.field(T, decl).Fn.params;
                comptime var vargs: [args.len][]const u8 = undefined;
                inline for (&vargs, 0..) |*v, a| {
                    v.* = comptime comptimePrint("v[{d}]", .{a});
                }
                comptime var xvargs: []const u8 = join(", ", &vargs);
                if (comptime zmeta.decl_args_has_selfpointer(T, decl)) {
                    const xremote = "remote";
                    if (comptime args.len == 1) {
                        xvargs = xremote;
                    } else {
                        xvargs = xremote ++ ", " ++ xvargs;
                    }
                }
                const xfmt =
                    \\{1s}.{0s} => {3s} {{
                    \\    return {2s}{{.{0s} = {5s}.{0s}({4s}) }};
                    \\}}
                ;
                comptime var var_v: []const u8 = "";
                if (comptime args.len > 0) {
                    var_v = comptimePrint("|v|", .{});
                }
                scli_i.* = comptime comptimePrint(xfmt, .{ decl, TNameTag, TNameReturnUnion, var_v, xvargs, Ttypename });
            }
            const msg_handler_body = comptime zfmt.fSwitch("msg", &slc);

            return comptime zfmt.fFn("message_handler", "remote: *" ++ Ttypename ++ ", msg: " ++ TNameParamUnion, TNameReturnUnion, msg_handler_body);
        }
        const msg_tag_enum = zfmt.fEnum(TNameTag, &decls);
        fn msg_union_fnargs() []const u8 {
            comptime var args_str: [decls.len][]const u8 = undefined;
            inline for (&args_str, decls) |*s, n| {
                const args = comptime zmeta.decl_arglist_without_selfpointer(T, n);
                const fmt = comptime comptimePrint("std.meta.tuple(&.{{{s}}})", .{join(", ", args)});
                s.* = fmt;
            }
            return comptime zfmt.fTaggedUnion(TNameParamUnion, TNameTag, &decls, &args_str);
        }
        fn msg_union_fnreturn() []const u8 {
            comptime var ret_str: [decls.len][]const u8 = undefined;
            inline for (&ret_str, decls) |*s, n| {
                const decl_return = comptime zmeta.decl_return_type(T, n);
                s.* = decl_return;
            }
            return comptime zfmt.fTaggedUnion(TNameReturnUnion, TNameTag, &decls, &ret_str);
        }
        fn generate() [:0]const u8 {
            // msg tag union for fn return data
            // body of struct
            const sfn_body_fmt =
                \\{s}
                \\return struct {{
                \\    channel: Server,
                \\    const Type = {s};
                \\{s}
                \\// delegated functions:
                \\{s}
                \\}};
            ;
            const sfn_args = "comptime Server: type";
            const sfn_return = "type";
            const sfn_body = comptime comptimePrint(sfn_body_fmt, .{ comptime_decl_check, Ttypename, message_handler(), delegator_fn_str() });
            const generic_fn = comptime zfmt.fFn(name, sfn_args, sfn_return, sfn_body);
            return comptime join("\n\n", &.{ "/// Autogenerated, will refresh if underlying struct changes and build.zig if setup in the build script\n/// changes to this file will likely be overwritten", zfmt.fImport("std", "std"), imports, generic_fn, msg_tag_enum, msg_union_fnargs(), msg_union_fnreturn() });
        }
    };
    return parts.generate();
}

// Example:
pub const SoundEngine = struct {
    const Self = @This();
    fn make_brum_brum(noise: u32) void {
        _ = noise;
    }
    fn releaseGas() f32 {
        return 0.2;
    }
    fn something(self: *Self) f32 {
        _ = self;
        return 0.2;
    }
};
// transform into
const SoundEngineTag = enum {
    make_brum_brum,
    releaseGas,
};
const SoundEngineParamUnion = union(SoundEngineTag) {
    make_brum_brum: std.meta.Tuple(&.{u32}),
    releaseGas: std.meta.Tuple(&.{}),
};
const SoundEngineReturnUnion = union(SoundEngineTag) {
    make_brum_brum: void,
    releaseGas: f32,
};
fn SoundEngineRemote(comptime Server: type) type {
    if (!@hasDecl(Server, "send")) {
        @compileError("the server type is missing the send method");
    }
    return struct {
        channel: Server,
        const Self = @This();
        fn message_handler(remote_device: *SoundEngine, msg: SoundEngineParamUnion) SoundEngineReturnUnion {
            switch (msg) {
                // code gen
                SoundEngineTag.make_brum_brum => |v| {
                    return SoundEngineReturnUnion{ .make_brum_brum = remote_device.make_brum_brum(v[0]) };
                },
                SoundEngineTag.releaseGas => {
                    return SoundEngineReturnUnion{ .releaseGas = remote_device.releaseGas() };
                },
            }
        }
        // note to myself:
        // if the first arg is self referential we must remove it

        // in auto functions generation we must add self: *Self to the args
        // to all decls even to those who normally dont take self
        // otherwise we cant call self.channel.send()

        // in messagehanlder if decl is self referential call it with the pointer
        // otherwise take the type and call decl on that

        fn make_brum_brum(self: *Self, noise: u32) void {
            const msg = SoundEngineParamUnion{ .make_brum_brum = .{noise} };
            self.channel.send(msg);
        }
        fn releaseGase(self: *Self) void {
            const msg = SoundEngineParamUnion{ .releaseGas = .{} };
            self.channel.send(msg);
        }
        // code gen
    };
}
const DummyServer = struct {
    const Self = @This();
    pub fn send(self: *Self, x: SoundEngineParamUnion) void {
        std.debug.print("{any}\n", .{x});
        _ = self;
    }
    pub fn xtest(x: f32, self1: *Self, self2: *Self) void {
        _ = self1;
        _ = self2;
        _ = x;
    }
};

test "test remote" {
    const Remote = SoundEngineRemote(DummyServer);
    const sv = DummyServer{};
    var remote = Remote{ .channel = sv };
    remote.releaseGase();
    remote.make_brum_brum(666);
    const srt = SoundEngineReturnUnion{ .releaseGas = SoundEngine.releaseGas() };
    std.debug.print("{any}\n", .{srt});
}
