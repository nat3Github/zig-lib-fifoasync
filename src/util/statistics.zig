const std = @import("std");
pub fn basic_stats(slc: []u64) void {
    const mean = calc_mean_ms(slc);
    const max = calc_max_ms(slc);
    const maxp90 = calc_mean_maxp(slc, 0.9);
    const maxp95 = calc_mean_maxp(slc, 0.95);
    const minp10 = calc_mean_minp(slc, 0.1);
    const fmt =
        \\
        \\ statistics ({} samples)
        \\ mean: {d:.3} ms
        \\ max: {d:.3} ms
        \\ max p90: {d:.3} ms
        \\ max p95: {d:.3} ms
        \\ min p10: {d:.3} ms
        \\
    ;
    std.debug.print(fmt, .{ slc.len, mean, max, maxp90, maxp95, minp10 });
}
pub fn calc_mean_maxp(slc: []u64, percentile: f32) f64 {
    std.debug.assert(percentile <= 1.0 and percentile >= 0);
    const z = @as(f64, @floatFromInt(slc.len)) * percentile;
    const ind: usize = @intFromFloat(@floor(z));
    const kk = struct {
        const This = @This();
        fn flessthan(v: This, a: u64, b: u64) bool {
            _ = v;
            return a < b;
        }
    };
    std.mem.sort(u64, slc, kk{}, kk.flessthan);
    return calc_mean_ms(slc[ind..]);
}
pub fn calc_mean_minp(slc: []u64, percentile: f32) f64 {
    std.debug.assert(percentile <= 1.0 and percentile >= 0);
    const z = @as(f64, @floatFromInt(slc.len)) * percentile;
    const ind: usize = @intFromFloat(@floor(z));
    const kk = struct {
        const This = @This();
        fn flessthan(v: This, a: u64, b: u64) bool {
            _ = v;
            return a > b;
        }
    };
    std.mem.sort(u64, slc, kk{}, kk.flessthan);
    return calc_mean_ms(slc[ind..]);
}

pub fn ns_to_ms_f64(k: u64) f64 {
    const ns_f: f64 = @floatFromInt(k);
    const ms: f64 = @floatFromInt(1_000_000);
    return ns_f / ms;
}
pub fn calc_mean_ms(slc: []u64) f64 {
    var x: f64 = 0;
    for (slc) |s| {
        x += ns_to_ms_f64(s) / @as(f64, @floatFromInt(slc.len));
    }
    return x;
}
pub fn calc_max_ms(slc: []u64) f64 {
    var x: u64 = 0;
    for (slc) |s| {
        if (s >= x) x = s;
    }
    return ns_to_ms_f64(x);
}
