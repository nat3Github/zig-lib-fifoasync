pub const prim = @import("primitives/primitives.zig");
pub const spsc = @import("primitives/weakrb-spsc.zig");
pub const mpmc = @import("mpmc");
// pub const mpmc = @import("primitives/cmpmc.zig");
pub const thread = @import("threads/thread.zig");

pub const sched = struct {
    pub const common = @import("wsqueue/common.zig");
    pub const realtime = @import("wsqueue/sched_rt.zig");
    pub const default = @import("wsqueue/sched_gp.zig");
    test "test sched submodules" {
        _ = .{
            common,
            realtime,
            default,
        };
    }
};

pub const stats = @import("util/statistics.zig");

test "test all refs" {
    _ = .{
        prim,
        spsc,
        stats,
        thread,
        sched,
    };
}
