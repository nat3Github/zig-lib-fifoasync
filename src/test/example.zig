const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const heap = std.heap;
const server = @import("fifoasync");
const auto_generated_module = @import("delegator");
const MyStruct = @import("examplestruct").MyStruct;

const MILLISECOND: u64 = 1_000_000;
pub fn main() !void {
    var heapalloc = heap.GeneralPurposeAllocator(.{}){};
    const gpa = heapalloc.allocator();

    // will use the default config you can also use init_ex to set internal queue CAP and delegat num CAP
    const server_config = server.RtsDelegatorServerConfig.init(auto_generated_module);
    const T_Server = server.RtsDelegatorServer(server_config);

    var sv = try T_Server.init(gpa, 1 * MILLISECOND);

    const instance = MyStruct{};

    var my_struct_as = try sv.register_delegator(instance);

    std.time.sleep(2000 * 1_000_000);
    // after that the server goes to sleep
    try my_struct_as.void_fn(0, 0.0);
    try my_struct_as.self_u32_fn();
    my_struct_as.wake() catch unreachable;
    std.debug.print("now wait 3 seconds for timeout\n", .{});
    std.time.sleep(3000 * 1_000_000);

    // handle return
    while (my_struct_as.channel.receive()) |ret| {
        switch (ret) {
            .void_fn => |r| {
                std.debug.print("{any} was returned\n", .{r});
            },
            .self_u32_fn => |r| {
                std.debug.print("{any} was returned\n", .{r});
            },
            else => unreachable,
        }
    }

    // wakeup_sv.deinit();
    // server_as.deinit();
}
