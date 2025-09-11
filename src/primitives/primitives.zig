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

/// for safe use of from two threads (T is either available at the local thread or at the second thread)
/// NOTE: when using a T which allocates you have to manually free that, this does not call deinit on T
// pub fn OneAccessToT(T: type) type {
//     return struct {
//         const This = @This();
//         thread_t: ?*T = null,
//         local_t: ?*T = null,
//         /// dont attempt to use T passed into this directly
//         pub fn init(alloc: Allocator, inst: T) !*This {
//             const self = try alloc.create(This);
//             const ubf = try alloc.create(T);
//             ubf.* = inst;
//             var this = This{};
//             @atomicStore(?*T, &this.local_t, ubf, .release);
//             self.* = this;
//             return self;
//         }
//         pub fn deinit(self: *This, alloc: Allocator) void {
//             if (self.local_get()) |d| {
//                 alloc.destroy(d);
//             } else {
//                 alloc.destroy(self.thread_get().?);
//             }
//             alloc.destroy(self);
//         }
//         /// this should be called on the local thread
//         pub fn local_get(self: *This) ?*T {
//             const mb = @atomicLoad(?*T, &self.local_t, .acquire);
//             return mb;
//         }
//         /// this should be called on the local thread
//         /// if you finished using T from local_get, submit it so the second thread can load it
//         pub fn local_submit(self: *This) void {
//             @atomicStore(?*T, &self.thread_t, self.local_t, .release);
//             @atomicStore(?*T, &self.local_t, null, .release);
//         }

//         /// this should be called on the second thread
//         pub fn thread_get(self: *This) ?*T {
//             const mb = @atomicLoad(?*T, &self.thread_t, .acquire);
//             return mb;
//         }
//         /// this should be called on the second thread
//         /// if you finished using T from thread_get, submit it so the local thread can load it
//         pub fn thread_submit(self: *This) void {
//             @atomicStore(?*T, &self.local_t, self.thread_t, .release);
//             @atomicStore(?*T, &self.thread_t, null, .release);
//         }
//     };
// }

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
pub fn RefCounted(comptime T: type) type {
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
            std.debug.assert(0 != self.ref_count.fetchAdd(1, .seq_cst));
        }
        /// Decrements the reference count.
        /// Returns true if the count reached zero (meaning the memory can be freed).
        pub fn decrement(self: *@This()) bool {
            return self.ref_count.fetchSub(1, .seq_cst) == 1;
        }
    };
}

/// A "smart pointer" wrapper for RefCounted data.
pub fn RcRef(comptime T: type) type {
    return struct {
        ptr: ?*RefCounted(T),
        pub fn init(allocator: std.mem.Allocator, value: T) !@This() {
            const rc_data = try allocator.create(RefCounted(T));
            rc_data.* = RefCounted(T).init(value);
            return .{ .ptr = rc_data };
        }
        pub fn clone(rc_ptr: *RefCounted(T)) @This() {
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
