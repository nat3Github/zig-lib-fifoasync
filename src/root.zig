const builtin = @import("builtin");
const std = @import("std");

pub const prim = @import("primitives/primitives.zig");
pub const spsc = @import("primitives/weakrb-spsc.zig");
pub const thread = @import("threads/thread.zig");

pub const sched = struct {
    const common = @import("wsqueue/common.zig");
    pub const Task = common.Task;
    pub const TaskContext = common.TaskContext;
    pub const Cancelled = common.Cancelled;
    pub const AsyncExecutor = common.AsyncExecutor;
    pub const ASFunction = common.ASFunction;
    pub const RealtimeSched = @import("wsqueue/sched_rt.zig");
    pub const DefaultSched = @import("wsqueue/sched_gp.zig");
    pub const HybridSched = @import("wsqueue/sched_hybrid.zig");
};
pub const util = struct {
    pub const atomic = @import("util/atomic.zig");
    pub const fibonacci = @import("util/fibonacci.zig");
};

pub const stats = @import("util/statistics.zig");

pub const cpu_cache_line = std.atomic.cacheLineForCpu(builtin.target.cpu);
