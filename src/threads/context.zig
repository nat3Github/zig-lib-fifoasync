const std = @import("std");
pub const arch = aarch64;
const x86_64 = struct {
    const Context = struct {
        rsp: usize,
        rip: usize,
        rbp: usize,
        rbx: usize,
        r12: usize,
        r13: usize,
        r14: usize,
        r15: usize,
    };
    const assert = @import("std").debug.assert;

    // Saves the current context to `old_ctx` and restores the context from `new_ctx`.
    // pub fn swap_context(old_ctx: *Context, new_ctx: *Context) callconv(.C) void {
    //     // Arguments are passed in rdi (old_ctx) and rsi (new_ctx) on x86-64.
    //     // We use a volatile assembly block to prevent the compiler from optimizing it away.
    //     asm volatile(
    //         // Save callee-saved registers
    //         "movq %%rsp, (%%rdi)\n" // Store current rsp at old_ctx.rsp
    //         "movq %%rbp, 8(%%rdi)\n" // Store current rbp at old_ctx.rbp
    //         "movq %%rbx, 16(%%rdi)\n" // Store current rbx at old_ctx.rbx
    //         "movq %%r12, 24(%%rdi)\n"
    //         "movq %%r13, 32(%%rdi)\n"
    //         "movq %%r14, 40(%%rdi)\n"
    //         "movq %%r15, 48(%%rdi)\n"
    //         // The return address for this function is on the stack.
    //         // It becomes the new RIP for the old context.
    //         "movq (%%rsp), 56(%%rdi)\n"

    //         // Restore registers for the new context
    //         "movq (%%rsi), %%rsp\n"  // Load new rsp from new_ctx.rsp
    //         "movq 8(%%rsi), %%rbp\n"  // Load new rbp
    //         "movq 16(%%rsi), %%rbx\n" // Load new rbx
    //         "movq 24(%%rsi), %%r12\n"
    //         "movq 32(%%rsi), %%r13\n"
    //         "movq 40(%%rsi), %%r14\n"
    //         "movq 48(%%rsi), %%r15\n"
    //         "movq 56(%%rsi), %%rax\n"  // Load new rip into rax
    //         "jmpq *%%rax\n"            // Jump to the new RIP
    //         : // No outputs
    //         : "{rdi}"(old_ctx), "{rsi}"(new_ctx)
    //         : "memory", "rax" // Clobbered registers
    //     );
    // }
};

pub const aarch64 = struct {
    pub const Context = struct {
        x19: u64,
        x20: u64,
        x21: u64,
        x22: u64,
        x23: u64,
        x24: u64,
        x25: u64,
        x26: u64,
        x27: u64,
        x28: u64,
        fp: u64, // Frame Pointer (x29)
        lr: u64, // Link Register (x30)
        sp: u64, // Stack Pointer
    };
    pub fn swap_context(old_ctx: *aarch64.Context, new_ctx: *aarch64.Context) callconv(.C) void {
        _ = new_ctx;
        _ = old_ctx;
        // asm volatile (
        //     \\stp x19, x20, [%[old_ctx]]
        //     \\stp x21, x22, [%[old_ctx], #16]
        //     \\stp x23, x24, [%[old_ctx], #32]
        //     \\stp x25, x26, [%[old_ctx], #48]
        //     \\stp x27, x28, [%[old_ctx], #64]
        //     \\stp x29, x30, [%[old_ctx], #80]
        //     \\mov x10, sp
        //     \\str x10, [%[old_ctx], #96]
        //     \\ldp x19, x20, [%[new_ctx]]
        //     \\ldp x21, x22, [%[new_ctx], #16]
        //     \\ldp x23, x24, [%[new_ctx], #32]
        //     \\ldp x25, x26, [%[new_ctx], #48]
        //     \\ldp x27, x28, [%[new_ctx], #64]
        //     \\ldp x29, x30, [%[new_ctx], #80]
        //     \\ldr x10, [%[new_ctx], #96]
        //     \\mov sp, x10
        //     \\ret
        //     : // This colon is necessary to separate the assembly string from the constraints.
        //     : [old_ctx] "r" (old_ctx),
        //       [new_ctx] "r" (new_ctx), // Inputs
        //     : "x10", "memory" // Clobbered registers
        // );
    }
    pub fn align_ptr(ptr: usize) usize {
        const not: usize = 0xF;
        return ptr & ~not;
    }
    pub fn init_context(
        ctx: *aarch64.Context,
        stack_ptr: usize,
        entry_point: *const fn () void,
    ) void {
        const aligned_stack_ptr = align_ptr(stack_ptr);

        // Set the stack pointer
        ctx.sp = aligned_stack_ptr;

        // The 'ret' instruction jumps to the address in the link register.
        // We set the link register to our entry point.
        ctx.lr = @intFromPtr(entry_point);

        // Set other registers to 0 for a clean start.
        ctx.x19 = 0;
        ctx.x20 = 0;
        ctx.x21 = 0;
        ctx.x22 = 0;
        ctx.x23 = 0;
        ctx.x24 = 0;
        ctx.x25 = 0;
        ctx.x26 = 0;
        ctx.x27 = 0;
        ctx.x28 = 0;
        ctx.fp = 0;
    }
};
