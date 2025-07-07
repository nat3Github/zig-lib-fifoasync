const std = @import("std");
const root = @import("../root.zig");
const StdAtomic = std.atomic.Value;

pub fn UnorderedAtomic(T: type) type {
    return struct {
        raw: StdAtomic(T),
        pub fn init(val: T) @This() {
            return @This(){
                .raw = StdAtomic(T).init(val),
            };
        }
        pub fn load(self: *const @This()) T {
            return self.raw.load(.unordered);
        }
        pub fn store(self: *@This(), val: T) void {
            self.raw.store(val, .unordered);
        }
    };
}
pub fn AcqRelAtomic(T: type) type {
    return struct {
        raw: StdAtomic(T),
        pub fn init(val: T) @This() {
            return @This(){
                .raw = StdAtomic(T).init(val),
            };
        }
        pub fn load(self: *const @This()) T {
            return self.raw.load(.acquire);
        }
        pub fn store(self: *@This(), val: T) void {
            self.raw.store(val, .release);
        }
    };
}

pub fn SpinLocked(T: type) type {
    return struct {
        raw: T,
        mtx: root.prim.Spinlock = .{},
        pub fn init(val: T) @This() {
            return @This(){
                .raw = val,
            };
        }
        pub fn load(self: *@This()) T {
            self.mtx.lock();
            defer self.mtx.unlock();
            return self.raw;
        }
        pub fn store(self: *@This(), val: T) void {
            self.mtx.lock();
            defer self.mtx.unlock();
            self.raw = val;
        }
    };
}
