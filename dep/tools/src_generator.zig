const std = @import("std");
const gen = @import("fifoasync").codegen;
const struct_module = @import("examplestruct");
// this generates source code for an delegator of the struct MyStruct from some_struct.zig:
// note: look at the build.zig for help with setting this up.
pub fn main() !void {
    const config = comptime gen.CodeGenConfig{
        .T = struct_module.MyStruct,
    };
    // examplestruct in this case is the import name for the module where the struct is
    // in build.zig also add the module under the name "examplestruct" the auto generated module (because it references it)
    const TCodeGen = gen.CodeGen(config).init("examplestruct");
    try TCodeGen.generate_and_write();
}
