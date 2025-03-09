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
const OneError = OneAccessToT(?anyerror);

test "test oneaccess to" {
    const alloc = std.testing.allocator;
    const Stack = struct {
        const This = @This();
        const TWT = WThread(.{ .debug_name = "test oneaccess", .T_stack_type = This });
        ae: *OneError,
        pub fn f(selfx: This, threadx: TWT.ArgumentType) anyerror!void {
            var self = selfx;
            var thread = threadx;
            var k: u32 = 0;
            std.log.warn("now running", .{});
            while (thread.should_run()) {
                if (k % 3 == 0) {
                    while (thread.should_run()) if (self.ae.thread_get()) |z| {
                        z.* = error.InterestingError;
                        self.ae.thread_submit();
                        break;
                    };
                } else {
                    while (thread.should_run()) if (self.ae.thread_get()) |z| {
                        z.* = null;
                        self.ae.thread_submit();
                        break;
                    };
                }
                k += 1;
            }
        }
    };
    var atomic_error = try OneError.init(alloc, null);
    defer atomic_error.deinit(alloc);

    var thandle = try Stack.TWT.init(alloc, .{
        .ae = atomic_error,
    }, Stack.f);
    thandle.spinwait_for_startup();

    std.Thread.sleep(1e6);
    for (0..10) |i| {
        const res = atomic_error.local_get();
        if (res) |e| {
            const err = e.*;
            std.debug.print("iteration {}: {any}\n", .{ i, err });
            atomic_error.local_submit();
        }
        std.Thread.sleep(1e6);
    }

    thandle.stop_or_timeout(1e9) catch unreachable;
    thandle.deinit(alloc);
    std.Thread.sleep(1e6);
}
