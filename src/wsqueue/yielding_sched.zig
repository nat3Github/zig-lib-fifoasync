/// scheduler which supports yielding using coroutines
const std = @import("std");
const Allocator = std.mem.Allocator;
const ResetEvent = std.Thread.ResetEvent;
const root = @import("../root.zig");
const Task = root.sched.Task;
const AsyncExecutor = root.sched.AsyncExecutor;

const coro = @import("../zigcoro/coro.zig");

const assert = std.debug.assert;
const expect = std.testing.expect;

pub const YieldSched = struct {
    pub const Config = struct {
        max_concurrency: usize = 32,
        stack_size: usize = 1024 * 32, // if this is to low it can lead to Stack Overflow / BUS Error crash
        alloc: Allocator,
    };

    const QueueRef = FixedQueue(*ExecutionItem);
    const ExecutionItem = struct {
        coro_ref: *coro.Coro = undefined,
        stack: coro.StackT,
        t: Task,
        exec: AsyncExecutor,
        fn run() void {
            const storage: *@This() = coro.xframe().getStorage(ExecutionItem);
            const task = storage.t;
            const exec = storage.exec;
            task.call(exec);
        }
        fn init_coro(item: *@This(), fun: Task, this_exec: AsyncExecutor) !void {
            item.t = fun;
            item.exec = this_exec;
            item.coro_ref = try coro.Coro.init(ExecutionItem.run, item.stack, false, @ptrCast(item));
        }
    };
    stack: []u8 = undefined,
    cfg: Config = undefined,
    slots: std.ArrayList(ExecutionItem) = .{},
    storage: QueueRef = undefined,
    active: QueueRef = undefined,
    arena: std.heap.ArenaAllocator = undefined,
    /// scheduler which supports yielding using coroutines
    pub fn init(self: *@This(), cfg: Config) Allocator.Error!void {
        self.* = .{};
        self.cfg = cfg;
        self.arena = .init(cfg.alloc);
        errdefer self.arena.deinit();
        const alloc = self.arena.allocator();
        const aligned_stack_size = std.mem.alignForward(usize, cfg.stack_size, 16);
        try self.storage.init(alloc, cfg.max_concurrency);
        try self.active.init(alloc, cfg.max_concurrency);
        try self.slots.appendNTimes(alloc, undefined, cfg.max_concurrency);
        for (self.slots.items) |*it| {
            it.stack = try alloc.alignedAlloc(u8, std.mem.Alignment.@"16", aligned_stack_size);
            self.storage.push(it) catch unreachable;
        }
    }
    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
    }
    pub fn yield() void {
        coro.xsuspend();
    }
    fn get_slot(self: *@This()) *ExecutionItem {
        for (self.slots.items) |*it| {
            if (it.cor.status == .Done) return it;
        }
    }
    pub fn has_backlog(self: *@This()) bool {
        return self.active.len() > 0;
    }

    pub fn process_backlog(self: *@This()) void {
        for (0..self.active.len()) |_| {
            const item = self.active.pop().?;
            coro.xresume(item.coro_ref); // resume coro
            if (item.coro_ref.status == .Done) {
                self.storage.push(item) catch unreachable;
            } else self.active.push(item) catch unreachable;
        }
    }

    pub fn execute(self: *@This(), T: type, alive_t: T, alive: *const fn (T) bool, fun: Task, this_exec: AsyncExecutor) !void {
        self.process_backlog();
        if (self.storage.pop()) |item| {
            try item.init_coro(fun, this_exec);
            coro.xresume(item.coro_ref); // start the coroutine
            if (!alive(alive_t)) return;
            if (item.coro_ref.status == .Done) {
                self.storage.push(item) catch unreachable;
            } else self.active.push(item) catch unreachable;
            return;
        } else {
            for (0..self.active.len()) |_| {
                const item = self.active.pop().?;
                coro.xresume(item.coro_ref); // resume coro
                if (!alive(alive_t)) return;
                if (item.coro_ref.status == .Done) {
                    try item.init_coro(fun, this_exec);
                    coro.xresume(item.coro_ref); // start the coroutine
                    if (!alive(alive_t)) return;
                    if (item.coro_ref.status == .Done) {
                        self.storage.push(item) catch unreachable;
                    } else self.active.push(item) catch unreachable;
                    return;
                } else self.active.push(item) catch unreachable;
            }
        }
        return error.NoSlot; // no active item has finished its work
    }
};

pub fn FixedQueue(comptime T: type) type {
    return struct {
        buffer: []T = undefined,
        _head: usize = 0,
        _tail: usize = 0,
        _len: usize = 0,
        pub fn init(self: *@This(), alloc: Allocator, cap: usize) Allocator.Error!void {
            self.* = .{};
            self.buffer = try alloc.alloc(T, cap);
        }
        pub fn reset(self: *@This()) void {
            self._head = 0;
            self._tail = 0;
            self._len = 0;
        }
        pub fn deinit(self: *@This(), alloc: Allocator) void {
            alloc.free(self.buffer);
            self.* = undefined;
        }
        pub fn push(self: *@This(), item: T) !void {
            if (self._len == self.buffer.len) {
                return error.BufferFull;
            }
            self.buffer[self._tail] = item;
            self._tail = (self._tail + 1) % self.buffer.len;
            self._len += 1;
        }
        pub fn pop(self: *@This()) ?T {
            if (self._len == 0) return null;
            const item = self.buffer[self._head];
            self._head = (self._head + 1) % self.buffer.len;
            self._len -= 1;
            return item;
        }
        pub fn len(self: *const @This()) usize {
            return self._len;
        }
    };
}
