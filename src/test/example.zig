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

    // after that the server goes to sleep
    // try my_struct_as.void_fn(0, 0.0);
    // try my_struct_as.self_u32_fn();
    std.debug.print("now wait 3 seconds for timeout\n", .{});
    std.time.sleep(3000 * 1_000_000);
    const MEASUREMENT_NUM = 100;
    var mesarr: [MEASUREMENT_NUM]u64 = std.mem.zeroes([MEASUREMENT_NUM]u64);
    var num: usize = 0;
    var inst: std.time.Instant = undefined;

    for (0..MEASUREMENT_NUM) |_| {
        my_struct_as.make_measurement() catch unreachable;
        my_struct_as.wake() catch unreachable;
        inst = std.time.Instant.now() catch unreachable;

        std.Thread.sleep(10 * MILLISECOND);

        // handle return
        while (my_struct_as.channel.receive()) |ret| {
            switch (ret) {
                .void_fn => |r| {
                    std.debug.print("{any} was returned\n", .{r});
                },
                .self_u32_fn => |r| {
                    std.debug.print("{any} was returned\n", .{r});
                },
                .make_measurement => |k| {
                    const time_ns = std.time.Instant.since(k, inst);
                    mesarr[num] = time_ns;
                    num += 1;
                },
                else => unreachable,
            }
        }
    }
    for (mesarr) |k| {
        const ns_f: f64 = @floatFromInt(k);
        const ms: f64 = @floatFromInt(MILLISECOND);
        const kms = ns_f / ms;
        std.debug.print("\n{} ms", .{kms});
    }

    // wakeup_sv.deinit();
    // server_as.deinit();
}
