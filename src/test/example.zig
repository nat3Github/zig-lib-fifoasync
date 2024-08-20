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
    const handle = server_as.get_wake_handle();

    try my_struct_as.selfFunction2(23.0);
    handle.set();
    std.time.sleep(100 * 1_000_000);
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
