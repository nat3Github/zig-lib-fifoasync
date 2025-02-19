const std = @import("std");
const ziggen = @import("ziggen");
const zmeta = ziggen.Meta;
const zfmt = ziggen.SourcePub;
const Type = std.builtin.Type;
const zjoin = ziggen.join;
const zprint = ziggen.print;
const zconcat = ziggen.concat;
const stringu8 = []const u8;

pub const CodeGenConfig = struct {
    const This = @This();
    T: type,
};
// note: unlikely somemone would use these as keywords
pub const RESERVED_DECL = "B1EF4C_DECLS";
pub const RESERVED_ARGS = "B1EF4C_ARGS";
pub const RESERVED_RET = "B1EF4C_RET";
pub const RESERVED_NAME = "B1EF4C_AS";
/// generates boilerplate source code for turning a struct into a Delegator which forwards the struct fn calls as Union Enum Messages
/// will only generate functions which are pub
/// to work properly you must import the file that defines T
/// and other files which types are used in the methods of T
/// std is already imported
///
/// dont use reserved keywords (see above)
///
pub fn CodeGen(config: CodeGenConfig) type {
    if (!zmeta.isStruct(config.T)) {
        @compileError("expected T to be of type Struct");
    }
    const T = config.T;
    const decls = zmeta.struct_decl_names(T);
    return struct {
        const This = @This();
        t_name: stringu8,
        t_name_tag: stringu8,
        t_name_param_union: stringu8,
        t_name_return_union: stringu8,
        t_reference_path: stringu8,
        imports: []const stringu8,
        NameCompType: stringu8,
        /// struct import name = the module where T is located;
        pub fn init(struct_import_name: stringu8) This {
            const xNameCompType = "Channel";
            const struct_base_import = zmeta.type_name_base(config.T);
            const struct_name_without_base = zmeta.type_name_without_base(config.T);

            const ximports = &.{
                zfmt.Import(struct_base_import, struct_import_name),
            };
            // const _decl_check = zfmt.HasDeclCompileCheck(xNameCompType, "send", "the server type is missing the send method");
            const struct_name_as = RESERVED_NAME;
            return This{
                .t_name = struct_name_as,
                .t_name_tag = RESERVED_DECL,
                .t_name_param_union = RESERVED_ARGS,
                .t_name_return_union = RESERVED_RET,
                .NameCompType = xNameCompType,
                .t_reference_path = zconcat(&.{ struct_base_import, ".", struct_name_without_base }),
                .imports = ximports,
            };
        }
        fn delegator_fn_str(self: *const This) stringu8 {
            const slc = zfmt.make_string_slice(decls.len);
            inline for (decls, slc) |decl, *si| {
                const args_type = zmeta.decl_arglist_without_selfpointer(T, decl);
                const args_id = zfmt.generic_identifiers(args_type.len);
                // param-union, decl, args
                const bodyfmt =
                    \\const msg = {s}{{
                    \\.{s} = .{{{s}}} 
                    \\}};
                    \\try self.channel.send(msg);
                ;
                const msg_args = zjoin(", ", args_id);
                const body = zprint(bodyfmt, .{ self.t_name_param_union, decl, msg_args });
                var args = zprint("self: *Self, {s}", .{zfmt.combine_fn_arguments_comma_seperated(args_id, args_type)});
                if (args_id.len == 0) args = "self: *Self";
                si.* = zfmt.Fn(decl, args, "!void", body);
            }
            return zjoin("\n", slc);
        }
        //TODO: calling convention for selfref vs not selfref
        fn message_handler(self: *const This) stringu8 {
            const Nremote = "remote";
            const slc = zfmt.make_string_slice(decls.len);
            inline for (decls, slc) |decl, *scli_i| {
                const args_type = zmeta.decl_arglist_without_selfpointer(T, decl);
                const vargs = zfmt.make_string_slice(args_type.len);
                for (vargs, 0..) |*v, a| {
                    v.* = zprint("v[{d}]", .{a});
                }
                var xvargs = zjoin(", ", vargs);
                if (zmeta.decl_uses_selfpointer(T, decl)) xvargs = zjoin(", ", &.{ Nremote, xvargs });
                const xfmt =
                    \\{1s}.{0s} => {3s} {{
                    \\    return {2s}{{.{0s} = {5s}.{0s}({4s}) }};
                    \\}}
                ;
                var var_v: stringu8 = "";
                if (args_type.len > 0) var_v = zprint("|v|", .{});
                scli_i.* = zprint(xfmt, .{ decl, self.t_name_tag, self.t_name_return_union, var_v, xvargs, self.t_reference_path });
            }
            const msg_handler_body = zfmt.Switch("msg", slc);
            const comment = "/// calls the remote type with the right functions and arguments from the ArgUnions and returns a ReturnUnion. \n/// DelegatorServer uses this.\n";
            const zfn = zfmt.Fn("__message_handler", zconcat(&.{ Nremote, ": *", self.t_reference_path, ", msg: ", self.t_name_param_union }), self.t_name_return_union, msg_handler_body);
            return zconcat(&.{ comment, zfn });
        }
        fn msg_union_fnargs(self: *const This) stringu8 {
            var args_str: [decls.len]stringu8 = undefined;
            inline for (&args_str, decls) |*s, n| {
                const args = zmeta.decl_arglist_without_selfpointer(T, n);
                const fmt = zprint("std.meta.Tuple(&.{{{s}}})", .{zjoin(", ", args)});
                s.* = fmt;
            }
            return zfmt.TaggedUnion(self.t_name_param_union, self.t_name_tag, &decls, &args_str);
        }
        fn msg_union_fnreturn(self: *const This) stringu8 {
            var ret_str: [decls.len]stringu8 = undefined;
            inline for (&ret_str, decls) |*s, n| {
                const decl_return = zmeta.decl_return_type(T, n);
                s.* = decl_return;
            }
            return zfmt.TaggedUnion(self.t_name_return_union, self.t_name_tag, &decls, &ret_str);
        }
        pub fn generate(self: *const This) stringu8 {
            // msg tag union for fn return data
            // body of struct
            const sfn_body_fmt =
                \\{s}
                \\return struct {{
                \\    channel: {s},
                \\    wakeup_handle: ?T,
                \\    pub const Type = {s};
                \\    const Self = @This();
                \\{s}
                \\    pub fn wake(self: *Self) !void {{
                \\      const handle = self.wakeup_handle orelse return error.WakeHandleIsNull;
                \\      handle.wake();
                \\    }}
                \\// delegated functions:
                \\{s}
                \\}};
            ;
            const sfn_args = zconcat(&.{ " ", self.NameCompType, ": type", ", ", "T : type" });
            const sfn_return = "type";
            // note temporary removed _decl_check check for send function decl of channel
            const sfn_body = zprint(sfn_body_fmt, .{ "", self.NameCompType, self.t_reference_path, self.message_handler(), self.delegator_fn_str() });

            const concat_imports = zjoin("\n", self.imports);
            const generic_fn = zfmt.Fn(self.t_name, sfn_args, sfn_return, sfn_body);
            const msg_tag_enum = zfmt.Enum(self.t_name_tag, &decls);

            return zjoin("\n\n", &.{ "/// Autogenerated, will refresh if underlying struct changes and build.zig if setup in the build script\n/// changes to this file will likely be overwritten", zfmt.Import("std", "std"), concat_imports, generic_fn, msg_tag_enum, self.msg_union_fnargs(), self.msg_union_fnreturn() });
        }
    };
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
fn SoundEngineRemote(Server: type) type {
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
test "test all" {
    std.testing.refAllDeclsRecursive(@This());
}
