const root = @import("fifoasync");
const std = @import("std");
const spsc = root.spsc;

test "spsc basic test" {
    var fifo = spsc.Fifo(u32, 4){};
    for (0..10) |i| {
        const casted: u32 = @intCast(i);
        fifo.push(casted) catch unreachable;
        const ret = fifo.pop().?;
        try std.testing.expect((ret == casted));
    }
}
