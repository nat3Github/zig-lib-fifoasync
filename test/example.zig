const std = @import("std");
const fifoasync = @import("fifoasync");
const stats = fifoasync.stats;
const fs = std.fs;
const mem = std.mem;
const heap = std.heap;
const server = @import("fifoasync").threads.delegator;
const auto_generated_module = @import("delegator");
const MyStruct = @import("examplestruct").MyStruct;

const MILLISECOND: u64 = 1_000_000;
pub fn main() !void {
    var heapalloc = heap.GeneralPurposeAllocator(.{}){};
    const gpa = heapalloc.allocator();

    // will use the default config you can also use init_ex to set internal queue CAP and delegat num CAP
    const server_config = server.DelegatorServerConfig.init(auto_generated_module);
    // set server type (RtsDelegatorServer or BlockingDelegatorServer);
    // for real time safe use use Rts otherwise use Blocking
    const T_Server = server.DelegatorServer(server_config);

    var sv = try T_Server.init(gpa);
    const instance = MyStruct{};
    var my_struct_as = try sv.register_delegator(instance);

    const MEASUREMENT_NUM = 256;
    var mesarr: [MEASUREMENT_NUM]u64 = std.mem.zeroes([MEASUREMENT_NUM]u64);
    var num: usize = 0;

    for (0..MEASUREMENT_NUM) |_| {
        var timer = std.time.Timer.start() catch unreachable;
        timer.reset();
        my_struct_as.make_measurement(timer) catch unreachable;
        my_struct_as.wake() catch unreachable;

        const wait = my_struct_as.wait_handle.?;
        wait.timedWait(100 * MILLISECOND) catch {};

        // handle return
        while (my_struct_as.channel.receive()) |ret| {
            switch (ret) {
                .void_fn => |r| {
                    std.debug.print("{any} was returned\n", .{r});
                },
                .self_u32_fn => |r| {
                    std.debug.print("{any} was returned\n", .{r});
                },
                .make_measurement => |time_ns| {
                    mesarr[num] = time_ns;
                    num += 1;
                },
                else => unreachable,
            }
        }
        std.Thread.sleep(1 * 1000 * 1000);
    }
    switch (server_config.realtime_safe) {
        true => {
            std.debug.print("\nLatency Waking through Polling Background Thread", .{});
        },
        false => {
            std.debug.print("\nLatency Waking directly ", .{});
        },
    }
    stats.basic_stats(mesarr[0..]);
    try test_polling_server(gpa);
}

const Fifo = fifoasync.spsc.Fifo;
const Timer = std.time.Timer;
fn test_polling_server(aalc: std.mem.Allocator) !void {
    const FifoT = Fifo(Timer, 32);
    const N = 256;
    const S = struct {
        fifo: FifoT,
        pub fn f(fifo: *FifoT) void {
            var arr = std.mem.zeroes([N]u64);
            var c: usize = 0;
            while (true) {
                if (c == arr.len) break;
                if (fifo.pop()) |p| {
                    var t = p;
                    arr[c] = t.read();
                    c += 1;
                }
            }
            std.debug.print("\nLatency of Busy Polling ", .{});
            stats.basic_stats(arr[0..]);
        }
    };
    const fifo = try FifoT.init(aalc);
    const h = try std.Thread.spawn(.{ .allocator = aalc }, S.f, .{
        fifo,
    });

    h.detach();

    for (0..N) |_| {
        const t = Timer.start() catch unreachable;
        try fifo.push(t);
        std.Thread.sleep(1 * 1000 * 1000);
    }
    std.Thread.sleep(20 * 1000 * 1000);
}
