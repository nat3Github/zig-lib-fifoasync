const std = @import("std");
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
