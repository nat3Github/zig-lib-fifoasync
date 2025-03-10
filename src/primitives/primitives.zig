const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("../lib.zig");
const WThread = root.threads.wthread.WThread;

/// for safe use of from two threads (T is either available at the local thread or at the second thread)
/// NOTE: when using a T which allocates you have to manually free that, this does not call deinit on T
pub fn OneAccessToT(T: type) type {
    return struct {
        const This = @This();
        thread_t: ?*T = null,
        local_t: ?*T = null,
        /// dont attempt to use T passed into this directly
        pub fn init(alloc: Allocator, inst: T) !*This {
            const self = try alloc.create(This);
            const ubf = try alloc.create(T);
            ubf.* = inst;
            var this = This{};
            @atomicStore(?*T, &this.local_t, ubf, .release);
            self.* = this;
            return self;
        }
        pub fn deinit(self: *This, alloc: Allocator) void {
            if (self.local_get()) |d| {
                alloc.destroy(d);
            } else {
                alloc.destroy(self.thread_get().?);
            }
            alloc.destroy(self);
        }
        /// this should be called on the local thread
        pub fn local_get(self: *This) ?*T {
            const mb = @atomicLoad(?*T, &self.local_t, .acquire);
            return mb;
        }
        /// this should be called on the local thread
        /// if you finished using T from local_get, submit it so the second thread can load it
        pub fn local_submit(self: *This) void {
            @atomicStore(?*T, &self.thread_t, self.local_t, .release);
            @atomicStore(?*T, &self.local_t, null, .release);
        }

        /// this should be called on the second thread
        pub fn thread_get(self: *This) ?*T {
            const mb = @atomicLoad(?*T, &self.thread_t, .acquire);
            return mb;
        }
        /// this should be called on the second thread
        /// if you finished using T from thread_get, submit it so the local thread can load it
        pub fn thread_submit(self: *This) void {
            @atomicStore(?*T, &self.local_t, self.thread_t, .release);
            @atomicStore(?*T, &self.thread_t, null, .release);
        }
    };
}
