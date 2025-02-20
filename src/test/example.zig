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
    const server_config = server.DelegatorServerConfig.init(auto_generated_module);
    // set server type (RtsDelegatorServer or BlockingDelegatorServer);
    // for real time safe use use Rts otherwise use Blocking
    const T_Server = server.RtsDelegatorServer(server_config);

    var sv = try T_Server.init(gpa);
    const instance = MyStruct{};
    var my_struct_as = try sv.register_delegator(instance);

    const MEASUREMENT_NUM = 100;
    var mesarr: [MEASUREMENT_NUM]u64 = std.mem.zeroes([MEASUREMENT_NUM]u64);
    var num: usize = 0;

    for (0..MEASUREMENT_NUM) |_| {
        var timer = std.time.Timer.start() catch unreachable;
        timer.reset();
        my_struct_as.make_measurement(timer) catch unreachable;
        my_struct_as.wake() catch unreachable;

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
                .make_measurement => |time_ns| {
                    mesarr[num] = time_ns;
                    num += 1;
                },
                else => unreachable,
            }
        }
    }
    for (mesarr) |k| {
        std.debug.print("\n{} ms", .{ns_to_ms_f64(k)});
    }

    std.debug.print("\nmean: {}", .{calc_mean_ms(mesarr[0..])});
    std.debug.print("\nmax: {}", .{calc_max_ms(mesarr[0..])});
    // wakeup_sv.deinit();
    // server_as.deinit();
}
fn ns_to_ms_f64(k: u64) f64 {
    const ns_f: f64 = @floatFromInt(k);
    const ms: f64 = @floatFromInt(MILLISECOND);
    return ns_f / ms;
}
fn calc_mean_ms(slc: []u64) f64 {
    var x: f64 = 0;
    for (slc) |s| {
        x += ns_to_ms_f64(s) / @as(f64, @floatFromInt(slc.len));
    }
    return x;
}
fn calc_max_ms(slc: []u64) f64 {
    var x: u64 = 0;
    for (slc) |s| {
        if (s >= x) x = s;
    }
    return ns_to_ms_f64(x);
}
