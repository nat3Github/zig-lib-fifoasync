const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const root = @import("../root.zig");

/// writer loses data
/// reader always reads data
/// for simple updates where T is to big for Atomics
pub fn LossyWriter(T: type) type {
    return struct {
        const This = @This();
        raw: T = undefined,
        mtx: root.prim.Spinlock = .{},

        pub fn init(val: T) @This() {
            return .{
                .raw = val,
            };
        }
        /// multiple readers are allowed
        pub fn load(self: *This) T {
            self.mtx.lock();
            defer self.mtx.unlock();
            return self.raw;
        }
        /// only single writer
        pub fn try_write(self: *This, val: T) void {
            if (self.mtx.try_lock()) {
                defer self.mtx.unlock();
                self.raw = val;
            }
        }
    };
}

/// this lock is safe to use in a audio realtime scenario
/// use this when you want to mutate variables of something accesed by the realtime thread
/// mutex = synchronized exclusiv access = only one can have it at a time
/// use try_lock on the audio realtime thread which is wait free and lock on the thread which is blocking
/// aka if (mtx.try_lock) { // proceed to use the variables on the realtime thread }
/// NOTE: a lock is for synchronization and often compromises composability of functions, synchronization is best left to the end user because as he views the circumstances!
pub const Spinlock = struct {
    mtx: std.Thread.Mutex align(root.cpu_cache_line) = .{},
    pub fn lock(self: *Spinlock) void {
        for (0..64) |_| {
            if (self.mtx.tryLock()) return;
            yield_cpu();
        }
        for (0..64) |_| {
            if (self.mtx.tryLock()) return;
            inline for (0..2) |_| yield_cpu();
        }
        for (0..64) |_| {
            if (self.mtx.tryLock()) return;
            inline for (0..4) |_| yield_cpu();
        }
        while (!self.mtx.tryLock()) {
            inline for (0..8) |_| yield_cpu();
        }
    }
    pub fn unlock(self: *Spinlock) void {
        self.mtx.unlock();
    }
    pub fn try_lock(self: *Spinlock) bool {
        return self.mtx.tryLock();
    }
};

/// Yields the CPU to improve efficiency in busy-wait loops.
/// On x86, this emits the `pause` instruction.
/// On ARM64, this emits the `yield` instruction.
/// For other architectures, it currently does nothing.
pub fn yield_cpu() void {
    const current_arch = builtin.target.cpu.arch;
    if (current_arch.isX86()) {
        asm volatile ("pause");
    } else if (current_arch.isAARCH64()) {
        asm volatile ("yield");
    } else {
        @compileError("not available for this architecture");
    }
}

test "yield_cpu does not crash" {
    yield_cpu();
    std.debug.print("yield_cpu called successfully on {s}.\n", .{@tagName(builtin.target.cpu.arch)});
}

/// Shared ReadOnly Memory
pub fn AtomicRefCounted(comptime T: type) type {
    return struct {
        data: T,
        ref_count: std.atomic.Value(u64) = .init(1),
        /// Initializes a new RefCounted instance.
        /// The initial reference count is 1.
        pub fn init(value: T) @This() {
            return @This(){ .data = value };
        }
        /// Increments the reference count.
        pub fn increment(self: *@This()) void {
            const count_last = self.ref_count.fetchAdd(1, .seq_cst);
            if (count_last == 0) @panic("use after free in Atomic Reference Counted");
        }
        /// Decrements the reference count.
        /// Returns true if the count reached zero (meaning the memory must be freed).
        pub fn decrement(self: *@This()) bool {
            const count = self.ref_count.load(.seq_cst);
            if (count == 0) @panic("double free");
            const count_last = self.ref_count.fetchSub(1, .seq_cst);
            if (count_last == 1) return true else return false;
        }
        /// Increments the reference count.
        pub fn clone(self_: *const @This()) *@This() {
            const self = @constCast(self_);
            self.increment();
            return self;
        }
    };
}

/// A "smart pointer" wrapper for RefCounted data.
pub fn RcRef(comptime T: type) type {
    return struct {
        ptr: ?*AtomicRefCounted(T),
        pub fn init(allocator: std.mem.Allocator, value: T) !@This() {
            const rc_data = try allocator.create(AtomicRefCounted(T));
            rc_data.* = AtomicRefCounted(T).init(value);
            return .{ .ptr = rc_data };
        }
        pub fn clone(rc_ptr: *AtomicRefCounted(T)) @This() {
            rc_ptr.increment();
            return .{ .ptr = rc_ptr };
        }
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            if (self.ptr) |p| {
                if (p.decrement()) {
                    allocator.destroy(p);
                }
            }
            self.ptr = null;
        }
        pub fn get(self: @This()) ?*const T {
            if (self.ptr) |p| {
                return p.get();
            }
            return null;
        }
    };
}
