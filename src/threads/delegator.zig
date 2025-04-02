const root = @import("../lib.zig");
const std = @import("std");
const delegator_mod = root.codegen;
const Atomic = std.atomic.Value;
const Allocator = std.mem.Allocator;
const AtomicOrder = std.builtin.AtomicOrder;
const AtomicBool = Atomic(bool);
const spsc = root.spsc;
const wthread = root.threads.wthread;
const ResetEvent = std.Thread.ResetEvent;
/// the Channel used by Delegator Thread, its also compatible with auto generated Delegators.
pub const DelegatorChannel = spsc.LinkedChannel;
// like LThreadHandle but no control to stop other to return error
// no sleeping
pub fn BusyThread(T: type, alloc: Allocator, instance: T, f: fn (*T) anyerror!void) !void {
    const thr = struct {
        fn exe(instancex: T, fx: fn (*T) anyerror!void) void {
            var t: T = instancex;
            std.log.debug("busy thread started", .{});
            while (true) {
                fx(&t) catch |e| {
                    std.log.err("busy thread will exit with error: {any}", .{e});
                    break;
                };
            }
            std.log.warn("busy thread has terminated\n", .{});
        }
    };
    const thread = try std.Thread.spawn(.{ .allocator = alloc }, thr.exe, .{ instance, f });
    thread.detach();
}

/// A Blocking thread for auto generated Delegators.
///
/// T: instance Type
/// D: auto generated Delegator type
/// internal channel:
/// uses Messages for communication:
/// Args: the Send Type
/// Ret: the Return Type
/// capacity the internal capacity of the channel (how many functions do you call at once on a delegator? set this number accordingly)
pub fn DelegatorThread(D: type, T: type, DServerChannel: type) type {
    return struct {
        const This = @This();
        pub const InitReturnType = ThreadT.InitReturnType;
        const ThreadTConfig = wthread.WThreadConfig{
            .T_stack_type = T_wrapper,
            .debug_name = "Delegator",
        };
        const ThreadT = wthread.WThread(ThreadTConfig);
        thread: ThreadT.InitReturnType,
        const T_wrapper = struct {
            channel: DServerChannel,
            instance: T,
        };
        /// launches a background thread with the instances T
        /// the instance then can be called through an Delegator instance
        pub fn init(alloc: Allocator, instance: T, serverfifo: DServerChannel) !This {
            const inst = T_wrapper{
                .instance = instance,
                .channel = serverfifo,
            };
            const t = try ThreadT.init(alloc, inst, f);
            return This{
                .thread = t,
            };
        }
        fn f(inst: T_wrapper, th: ThreadT.ArgumentType) !void {
            // std.log.debug("\nwoke up will proces now", .{});
            var chan = inst.channel;
            var instance = inst.instance;
            while (th.should_run()) {
                while (chan.receive()) |msg| {
                    const ret = D.__message_handler(&instance, msg);
                    try chan.send(ret);
                }
                th.thread_sets_handle_waits.set();
                th.handle_sets_thread_waits.reset();
                th.handle_sets_thread_waits.timedWait(std.math.maxInt(u64)) catch unreachable;
            }
            // sleep maximum amount
        }
    };
}

/// Handle that is used by the WakeThread
pub const RtsWakeUpHandle = struct {
    const This = @This();
    inner_handle: *AtomicBool,
    pub fn wake(self: *const This) void {
        self.inner_handle.store(true, AtomicOrder.unordered);
    }
    pub fn deinit(self: *const This, gpa: Allocator) void {
        gpa.destroy(self.inner_handle);
    }
};

/// you can register std.Thread.ResetEvent, the returned WakeUpHandle can be used to set the ResetEvent in a RealTime Safe manner
///
/// this implements a busy loops which checks all wake up handles and calls .set() on the reset Events.
/// capacity = how many handles can be handled by / added to this Struct at runtime
pub fn RtsWakeUp(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const ABoolResetEvent = struct { if_wakeup: *AtomicBool, wake_up: *std.Thread.ResetEvent };
        counter: usize = 0,
        fifo: *spsc.Fifo(ABoolResetEvent, capacity),
        cleanup_server_slots: []ABoolResetEvent,
        alloc: Allocator,
        const WakeStruct = struct {
            const wSelf = @This();
            fifo_ptr: *spsc.Fifo(ABoolResetEvent, capacity),
            counter: usize = 0,
            slots: []ABoolResetEvent,
            fn f(self: *wSelf) !void {
                if (self.fifo_ptr.pop()) |b| {
                    if (self.counter == self.slots.len) return error.RtsWakupNoSlots;
                    self.slots[self.counter] = b;
                    self.counter += 1;
                }
                for (self.slots[0..self.counter]) |*reset_event| {
                    if (reset_event.if_wakeup.load(AtomicOrder.acquire)) {
                        reset_event.if_wakeup.store(false, AtomicOrder.release);
                        reset_event.wake_up.set();
                    }
                }
            }
        };
        // poll interval specifies how long the thread sleeps after it checked all wakeup slots
        pub fn init(alloc: Allocator) !Self {
            const server_slots = try alloc.alloc(Self.ABoolResetEvent, capacity);
            const fifo = try spsc.Fifo(ABoolResetEvent, capacity).init(alloc);
            const wakestruct = WakeStruct{
                .fifo_ptr = fifo,
                .slots = server_slots,
            };
            try BusyThread(WakeStruct, alloc, wakestruct, WakeStruct.f);
            return Self{
                .fifo = fifo,
                .alloc = alloc,
                .cleanup_server_slots = server_slots,
            };
        }
        /// returns a WakeUpHandle. you are responsible to deinit it
        pub fn register(self: *Self, gpa: Allocator, wakeup_handle: *ResetEvent) !RtsWakeUpHandle {
            if (self.counter == capacity) return error.AllWakeUpSlotsAreOccupied;
            const atb_ptr = try gpa.create(AtomicBool);
            atb_ptr.* = AtomicBool.init(false);
            const rsevent = ABoolResetEvent{ .if_wakeup = atb_ptr, .wake_up = wakeup_handle };
            try self.fifo.push(rsevent);
            self.counter += 1;
            return RtsWakeUpHandle{ .inner_handle = atb_ptr };
        }
    };
}
pub const BlockingWakeUpHandle = struct {
    const This = @This();
    inner_handle: *std.Thread.ResetEvent,
    pub fn wake(self: *const This) void {
        self.inner_handle.set();
    }
};

pub const DelegatorServerConfig = struct {
    const This = @This();
    max_num_delegators: usize = 16,
    internal_channel_buffersize: usize = 16,
    D: fn (type, type, type) type,
    Args: type,
    Ret: type,
    realtime_safe: bool = true,
    pub fn init(import: anytype) This {
        return This{
            .Args = @field(import, delegator_mod.RESERVED_ARGS),
            .Ret = @field(import, delegator_mod.RESERVED_RET),
            .D = @field(import, delegator_mod.RESERVED_NAME),
        };
    }
    pub fn init_ex(import: anytype, delegator_cap: usize, channel_msg_cap: usize) This {
        return This{
            .Args = @field(import, delegator_mod.RESERVED_ARGS),
            .Ret = @field(import, delegator_mod.RESERVED_RET),
            .D = @field(import, delegator_mod.RESERVED_NAME),
            .max_num_delegators = delegator_cap,
            .internal_channel_buffersize = channel_msg_cap,
        };
    }
};
/// Real time safe Server for use with auto generated Delegator
/// setup your build.zig to autogenerate an Delegator for the struct you want to use asynchronously (look at example.zig and devtools.zig)
///
/// this uses 1 polling server which checks all wake handles and wakes up the respective threads
/// this uses up to max_num_delegators backround threads that wait to be woken up (through the Delegator)
///
/// max_num_delegators = how often you can call register_delegator
///
///
/// note: does not free allocated memory
/// has a constant bound of needed memory (wont allocate indefinitely)
pub fn DelegatorServer(config: DelegatorServerConfig) type {
    const Args = config.Args;
    const Ret = config.Ret;
    const CHANNEL_CAP = config.internal_channel_buffersize;
    const INSTANCE_CAP = config.max_num_delegators;
    const T_DChannel = DelegatorChannel(Args, Ret, CHANNEL_CAP);
    const T_DServerChannel = DelegatorChannel(Ret, Args, CHANNEL_CAP);
    const T_WakeupHandle =
        switch (config.realtime_safe) {
            true => RtsWakeUpHandle,
            false => BlockingWakeUpHandle,
        };
    const T_Delegator = config.D(T_DChannel, T_WakeupHandle, *std.Thread.ResetEvent);
    const T = T_Delegator.Type;
    const T_Wthread = switch (config.realtime_safe) {
        true => RtsWakeUp(INSTANCE_CAP),
        false => wthread.VoidType,
    };
    const T_DThread = DelegatorThread(T_Delegator, T, T_DServerChannel);

    return struct {
        const This = @This();
        _dcount: usize = 0,
        _alloc: Allocator,
        wakeup_thread: T_Wthread,
        delegator_threads: [INSTANCE_CAP]T_DThread = undefined,
        pub fn init(alloc: Allocator) !This {
            const wkt = switch (config.realtime_safe) {
                true => try T_Wthread.init(alloc),
                else => wthread.Void,
            };
            return This{
                .wakeup_thread = wkt,
                ._alloc = alloc,
            };
        }
        // will consume an instance of T and return an Delegator (the autogenerated Delegator)
        pub fn register_delegator(self: *This, inst: T) !T_Delegator {
            if (self._dcount == INSTANCE_CAP) return error.DelegatorServerLimitIsFull;
            const bichannel = try spsc.get_bidirectional_linked_channels(self._alloc, Args, Ret, CHANNEL_CAP);
            const basefifo = bichannel.A_to_B_channel;
            const serverfifo = bichannel.B_to_A_channel;
            const dthread = try T_DThread.init(self._alloc, inst, serverfifo);
            self.delegator_threads[self._dcount] = dthread;
            self._dcount += 1;
            const wh = switch (config.realtime_safe) {
                true => try self.wakeup_thread.register(self._alloc, dthread.thread.handle_sets_thread_waits),
                else => BlockingWakeUpHandle{ .inner_handle = dthread.thread.handle_sets_thread_waits },
            };
            return T_Delegator{
                .channel = basefifo,
                .wakeup_handle = wh,
                .wait_handle = dthread.thread.thread_sets_handle_waits,
            };
        }
    };
}

test "test all refs" {
    // std.debug.print("\ndelegatar.zig semantic test", .{});
    std.testing.refAllDeclsRecursive(@This());
}
