const std = @import("std");

const root = @import("../root.zig");
const Task = root.sched.Task;
const thread = root.thread;
const sched_gp = @import("sched_gp.zig");
const sched_hybrid = @import("sched_hybrid.zig");
/// this is one implementation of the concepts described in readme.md
/// this leaves out the class 0 mechanism (spinning) because its to inefficient on GP OS
/// if you need lower latency, use a RT optimized OS with lower sleep times
///
pub const ClassConfig = struct {
    num_threads: usize = 2,
    queue_size: usize = std.math.powi(usize, 2, 12) catch unreachable,
};
pub const Sched4ClassConfig = struct {
    class_1_sleep_ns: u64 = 2 * 1_000_000,
    class_1_config: ClassConfig = .{},
    class_2_config: ClassConfig = .{ .num_threads = 4 },
    class_3_config: ClassConfig = .{ .num_threads = 4 },
    class_4_config: ClassConfig = .{ .num_threads = 4 },

    pub fn init_default_with_core_count(self: *Sched4ClassConfig) void {
        const core_num: f32 = @floatFromInt(@max(std.Thread.getCpuCount() catch 4, 4));
        self.class_1_config.num_threads = @intFromFloat(core_num * 0.5);
        self.class_2_config.num_threads = @intFromFloat(core_num * 0.75);
        self.class_3_config.num_threads = @intFromFloat(core_num * 0.75);
        self.class_4_config.num_threads = @intFromFloat(core_num * 1);
    }
};

pub const Sched4Class = @This();

class_1: sched_hybrid.Sched = undefined,
class_2: sched_gp.Sched = undefined,
class_3: sched_gp.Sched = undefined,
class_4: sched_gp.Sched = undefined,

pub fn init(self: *Sched4Class, alloc: std.mem.Allocator, cfg: Sched4ClassConfig) !void {
    try self.class_1.init(alloc, .{
        .N_threads = cfg.class_1_config.num_threads,
        .N_queue_capacity = cfg.class_1_config.queue_size,
        .startup_fn = thread.prio.set_realtime_critical_highest,
        .sleep_ns = cfg.class_1_sleep_ns,
    });
    errdefer self.class_1.deinit(alloc);
    try self.class_2.init(alloc, .{
        .N_threads = cfg.class_2_config.num_threads,
        .N_queue_capacity = cfg.class_2_config.queue_size,
        .startup_fn = thread.prio.set_realtime_critical_high,
    });
    errdefer self.class_2.deinit(alloc);
    try self.class_3.init(alloc, .{
        .N_threads = cfg.class_3_config.num_threads,
        .N_queue_capacity = cfg.class_3_config.queue_size,
        .startup_fn = thread.prio.set_elevated,
    });
    errdefer self.class_3.deinit(alloc);
    try self.class_4.init(alloc, .{
        .N_threads = cfg.class_4_config.num_threads,
        .N_queue_capacity = cfg.class_4_config.queue_size,
        .startup_fn = nothing,
    });
    errdefer self.class_4.deinit(alloc);
}
pub fn deinit(self: *Sched4Class, alloc: std.mem.Allocator) void {
    self.class_4.deinit(alloc);
    self.class_3.deinit(alloc);
    self.class_2.deinit(alloc);
    self.class_1.deinit(alloc);
}

fn nothing() anyerror!void {}
