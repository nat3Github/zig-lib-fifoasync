pub const prim = @import("primitives/primitives.zig");
pub const spsc = @import("primitives/weakrb-spsc.zig");
pub const thread = @import("threads/thread.zig");

pub const sched = struct {
    const common = @import("wsqueue/common.zig");
    pub const Task = common.Task;
    pub const AsyncExecutor = common.AsyncExecutor;
    pub const GenericAsyncExecutor = common.GenericAsyncExecutor;
    pub const ASFunction = common.ASFunction;
    pub const RealtimeSched = @import("wsqueue/sched_rt.zig");
    pub const DefaultSched = @import("wsqueue/sched_gp.zig");
    test "test sched submodules" {
        _ = .{
            common,
            RealtimeSched,
            DefaultSched,
        };
    }
};
pub const util = struct {
    pub const atomic = @import("util/atomic.zig");
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
