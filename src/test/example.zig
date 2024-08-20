const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const heap = std.heap;
const server = @import("fifoasync");
const AutoGen = @import("xx");

pub fn main() !void {
    var heapalloc = heap.GeneralPurposeAllocator(.{}){};
    const gpa = heapalloc.allocator();
    const capacity = 16;
    const Channel = server.DelegatorChannel(AutoGen.NewStructArgs, AutoGen.NewStructRet, capacity);
    const MyStructAS = AutoGen.NewStruct(*Channel);
    const MyStruct = MyStructAS.Type;
    const MyStructServerAS = server.DelegatorThread(MyStructAS, AutoGen.NewStructArgs, AutoGen.NewStructRet, capacity);
    const instance = MyStruct{};
    var server_as = try MyStructServerAS.init(gpa, instance);
    defer server_as.deinit();
    const channel = server_as.get_channel();

    var my_struct_as = MyStructAS{ .channel = channel };
    // const handle = server_as.get_wake_handle();
    // handle.set();

    std.time.sleep(1000 * 1_000_000);
    // after that the server goes to sleep
    try my_struct_as.void_fn(0, 0.0);
    try my_struct_as.self_u32_fn();
    server_as.wake_up_blocking();
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

    // try my_struct_as.something(&MyStruct{});
    // handle.set();
    // std.time.sleep(100 * 1_000_000);
    // try my_struct_as.kkkk(&MyStruct{});
    // handle.set();
    // std.time.sleep(100 * 1_000_000);
    // try my_struct_as.nothing(&MyStruct{});
    // handle.set();
    // std.time.sleep(100 * 1_000_000);
    // try my_struct_as.selfFunction(&MyStruct{});
    // handle.set();
    // std.time.sleep(100 * 1_000_000);
}
