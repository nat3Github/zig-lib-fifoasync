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
    const MyStructASThread = server.DelegatorThread(MyStructAS, AutoGen.NewStructArgs, AutoGen.NewStructRet, capacity);

    // Setup
    const instance = MyStruct{};
    // instantiate Delegator backround Thread
    var server_as = try MyStructASThread.init(gpa, instance);
    const channel = server_as.get_channel();

    // to safe cpu cycles DelegatorThreads sleeps after work and has to be woken up with the get_wake_handle().set()

    // make polling thread to use wait free wake up of the Backround Thread
    const PollingThread = server.WakeUpThread(1);

    var wakeup_sv = try PollingThread.init(gpa, 1 * 1_000_000);
    const wakeup_atomic = try wakeup_sv.add(gpa, server_as.get_wake_handle());

    // MyStructAS is the Delegator struct generated from MyStruct
    var my_struct_as = MyStructAS{
        // give the channel of the Delegator Thread to MyStructAs
        .channel = channel,
        // give the wake handle from the Delegator Thread to MyStructAs that we can wake up the Delegator Thread by calling MyStructAS.wake_up_blocking()
        .wake_up_event = server_as.get_wake_handle(),
        // give the atomic we got from WakeUpThread to MyStructAS for waitfree wakeup
        .wake_up_atomic = wakeup_atomic,
    };
    // const handle = server_as.get_wake_handle();
    // handle.set();

    std.time.sleep(2000 * 1_000_000);
    // after that the server goes to sleep
    try my_struct_as.void_fn(0, 0.0);
    try my_struct_as.self_u32_fn();
    // wake up blocking
    my_struct_as.wake_up_blocking();
    // wake up wait free
    my_struct_as.wake_up_waitfree();
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
