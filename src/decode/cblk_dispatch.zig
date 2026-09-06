//! Tier-1 dispatcher: take a `CblkDecodePlan` (from the walker) and
//! run the full EBCOT pipeline (`ebcot.decodeCblkPasses`) on it,
//! producing a decoded coefficient array.
//!
//! Each cblk gets its own fresh `Cblk` state, fresh MQ `Decoder`
//! seeded from the plan's concatenated byte slice, and fresh
//! `[19]Context` array. After decode the cblk owns the coefficient
//! buffer.
//!
//! M3 brick 9e — the structural bridge between the walker output
//! (CblkDecodePlanList) and the EBCOT entry point (decodeCblkPasses).
//! Byte-perfect comparison against the OpenJPEG t1 dump format lands
//! in brick 10 once `msb_bp` derivation from QCD is wired (today the
//! dispatcher takes `msb_bp` as a per-plan caller-supplied value).

const std = @import("std");
const Allocator = std.mem.Allocator;

const cblk_plan = @import("cblk_plan.zig");
const ebcot = @import("ebcot.zig");
const mq = @import("mq_coder.zig");

pub const CblkDecodePlan = cblk_plan.CblkDecodePlan;
pub const CblkDecodePlanList = cblk_plan.CblkDecodePlanList;

/// Map a `band` field (0..3 — OpenJPEG `bandno`: 0=LL@r=0, 1=HL, 2=LH,
/// 3=HH) to the EBCOT `Orientation` enum (which doesn't have the LL
/// case packed into band-number space).
pub fn orientationFromBand(band: u8) ebcot.Orientation {
    return switch (band) {
        0 => .ll,
        1 => .hl,
        2 => .lh,
        3 => .hh,
        else => .ll, // defensive — unreachable for well-formed plans
    };
}

/// Run EBCOT tier-1 decode on a single plan. `msb_bp` is derived from
/// the plan's `numbps` (= M_b - zero_bitplanes per T.800 E.1 + tag-tree
/// result), so callers don't need to compute it. Returns a heap-owned
/// `Cblk` carrying the decoded coefficients; caller must deinit.
pub fn decodePlan(
    allocator: Allocator,
    plan: CblkDecodePlan,
) Allocator.Error!ebcot.Cblk {
    var cblk = try ebcot.Cblk.init(allocator, plan.width(), plan.height());
    errdefer cblk.deinit(allocator);
    if (plan.data.len == 0 or plan.numbps == 0 or plan.total_passes == 0) return cblk;
    var ctxs = ebcot.initContexts();
    const orient = orientationFromBand(plan.band);
    // OpenJPEG's first bit-plane index is bpno_plus_one = numbps
    // (t1.c: bpno_plus_one = roishift + cblk->numbps). Our `bp` indexing
    // is 1:1 with OpenJPEG's bpno_plus_one, so the MSB bp IS numbps,
    // NOT numbps-1. (The lowest bp processed lands at 1, never 0,
    // because a cblk of numbps planes is at most 3*numbps-2 passes.)
    // A coded bit-plane count past 31 (M_b + ROI shift - zero_bitplanes)
    // cannot be represented (openjpeg refuses bpno_plus_one >= 31); leave the
    // block zero — deepValidate reports it as a pass-budget violation.
    if (plan.numbps > 31) return cblk;
    const msb_bp: u5 = @intCast(plan.numbps);
    if (plan.segments.len == 0) {
        // No per-segment breakdown (synthetic test plans): decode the whole
        // slice as one continuous MQ stream.
        var dec = mq.Decoder.initDec(plan.data);
        ebcot.decodeCblkPasses(&dec, &cblk, &ctxs, orient, msb_bp, plan.total_passes);
        cblk.over_read = dec.end_of_stream_count;
        cblk.under_read = if (dec.bp < plan.data.len) @intCast(plan.data.len - dec.bp) else 0;
    } else {
        // Real extracted plans carry the LAZY/TERMALL segment breakdown;
        // decode segment-by-segment (MQ or RAW per segment). For cblksty=0
        // this is a single MQ segment == decodeCblkPasses.
        ebcot.decodeCblkSegments(&cblk, &ctxs, orient, msb_bp, plan.cblksty, plan.data, plan.segments);
    }
    return cblk;
}

test "orientationFromBand: all 4 cases" {
    try std.testing.expectEqual(ebcot.Orientation.ll, orientationFromBand(0));
    try std.testing.expectEqual(ebcot.Orientation.hl, orientationFromBand(1));
    try std.testing.expectEqual(ebcot.Orientation.lh, orientationFromBand(2));
    try std.testing.expectEqual(ebcot.Orientation.hh, orientationFromBand(3));
}

test "decodePlan: empty plan data → empty Cblk (no crash, all-zero coeffs)" {
    const allocator = std.testing.allocator;
    var plan: CblkDecodePlan = .{
        .tile = 0, .component = 0, .resolution = 0, .band = 0, .precinct = 0,
        .sb_x0 = 0, .sb_y0 = 0, .sb_x1 = 4, .sb_y1 = 4,
        .zero_bitplanes = 0, .numbps = 8, .total_passes = 0, .cblksty = 0,
        .data = try allocator.alloc(u8, 0),
    };
    defer plan.deinit(allocator);
    var cblk = try decodePlan(allocator, plan);
    defer cblk.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 4), cblk.width);
    try std.testing.expectEqual(@as(u32, 4), cblk.height);
    for (cblk.coeffs) |c| try std.testing.expect(!c.significant);
}

test "decodePlan: non-empty plan runs the EBCOT pipeline (no crash)" {
    const allocator = std.testing.allocator;
    // Synthetic MQ-encoded-looking byte sequence — exercises CL pass.
    var plan: CblkDecodePlan = .{
        .tile = 0, .component = 0, .resolution = 0, .band = 0, .precinct = 0,
        .sb_x0 = 0, .sb_y0 = 0, .sb_x1 = 4, .sb_y1 = 4,
        .zero_bitplanes = 2, .numbps = 6, .total_passes = 1, .cblksty = 0,
        .data = try allocator.dupe(u8, &[_]u8{ 0x80, 0x80, 0x00, 0x00, 0xFF, 0xAC }),
    };
    defer plan.deinit(allocator);
    var cblk = try decodePlan(allocator, plan);
    defer cblk.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 4), cblk.width);
    try std.testing.expectEqual(@as(u32, 4), cblk.height);
    // .visited reset at end of decode (per the bit-plane orchestrator).
    for (cblk.coeffs) |c| try std.testing.expect(!c.visited);
}

/// Convert one `ebcot.Coeff` into the i32 sign-magnitude layout that
/// OpenJPEG's `t1_decode_cblk` writes to `t1->data`:
///
///   - not significant      → 0
///   - significant, sign=0  → +(|magnitude| | (1 << coeff.half_bp))
///   - significant, sign=1  → -(|magnitude| | (1 << coeff.half_bp))
///
/// The OR places the "+0.5 of last bin" reconstruction half-bit (T.800
/// D.4; OpenJPEG's `oneplushalf` / `poshalf` adjustments). Its position
/// is PER COEFFICIENT — one below the bit-plane at which that coefficient
/// was last coded — because a code-block whose final pass is SP or MR
/// leaves the coefficients not visited in that partial plane one plane
/// higher than the visited ones. A uniform per-cblk position derived from
/// the pass count (the retired halfBitPos) reproduced openjpeg only when
/// decoding ended on a cleanup pass (p1_05: 2235 cblks, max_abs 18).
pub fn coeffToOpenJpegI32(coeff: ebcot.Coeff) i32 {
    // magnitude == 0 while significant: the coefficient only became
    // significant in a surplus pass below plane 0 (see codeMagnitudeBit);
    // openjpeg never decoded that pass, so its value is 0.
    if (!coeff.significant or coeff.magnitude == 0) return 0;
    const mag: u32 = coeff.magnitude | (@as(u32, 1) << coeff.half_bp);
    const mag_i32: i32 = @intCast(mag);
    return if (coeff.sign == 0) mag_i32 else -mag_i32;
}

test "coeffToOpenJpegI32: not significant → 0 regardless of half_bp" {
    const c: ebcot.Coeff = .{ .significant = false, .sign = 0, .magnitude = 0, .half_bp = 6 };
    try std.testing.expectEqual(@as(i32, 0), coeffToOpenJpegI32(c));
}

test "coeffToOpenJpegI32: sig only at bp=3 (no refines) → half at 2 → +oneplushalf_3 = 12" {
    const c: ebcot.Coeff = .{ .significant = true, .sign = 0, .magnitude = 8, .half_bp = 2 };
    try std.testing.expectEqual(@as(i32, 12), coeffToOpenJpegI32(c));
}

test "coeffToOpenJpegI32: sig+refs full depth (half at 0) matches hand-derived OJ values" {
    // OJ trace format: value after each pass (sig / MR steps).
    //   bits decoded: sig@3=1, MR@2=0, MR@1=1, MR@0=0 → our mag = 1010 = 10
    //   OJ trace: 12 → 10 → 11 → 11.
    const c1: ebcot.Coeff = .{ .significant = true, .sign = 0, .magnitude = 10, .half_bp = 0 };
    try std.testing.expectEqual(@as(i32, 11), coeffToOpenJpegI32(c1));
    const c1_neg: ebcot.Coeff = .{ .significant = true, .sign = 1, .magnitude = 10, .half_bp = 0 };
    try std.testing.expectEqual(@as(i32, -11), coeffToOpenJpegI32(c1_neg));
    //   bits decoded: sig@3=1, MR@2=1, MR@1=1, MR@0=1 → our mag = 1111 = 15
    //   OJ trace: 12 → 14 → 15 → 15.
    const c2: ebcot.Coeff = .{ .significant = true, .sign = 0, .magnitude = 15, .half_bp = 0 };
    try std.testing.expectEqual(@as(i32, 15), coeffToOpenJpegI32(c2));
    //   bits decoded: sig@3=1, MR@2=0, MR@1=0, MR@0=0 → our mag = 1000 = 8
    //   OJ trace: 12 → 10 → 9 → 9.
    const c3: ebcot.Coeff = .{ .significant = true, .sign = 0, .magnitude = 8, .half_bp = 0 };
    try std.testing.expectEqual(@as(i32, 9), coeffToOpenJpegI32(c3));
}

test "coeffToOpenJpegI32: partial depth (last coded at bp=2 → half at 1)" {
    // sig at bp=3, MR at bp=2 with v=0 → our mag = 8. OJ trace: 12 → 10.
    const c1: ebcot.Coeff = .{ .significant = true, .sign = 0, .magnitude = 8, .half_bp = 1 };
    try std.testing.expectEqual(@as(i32, 10), coeffToOpenJpegI32(c1));
    // sig at bp=3, MR at bp=2 with v=1 → our mag = 12. OJ: 12 → 14.
    const c2: ebcot.Coeff = .{ .significant = true, .sign = 0, .magnitude = 12, .half_bp = 1 };
    try std.testing.expectEqual(@as(i32, 14), coeffToOpenJpegI32(c2));
}

test "coeffToOpenJpegI32: two coefficients of one cblk carry DIFFERENT half positions after a mid-plane stop" {
    // Stop after SP@bp=2: a coefficient refined at bp=3 (half 2) and one
    // that became significant in that SP (half 1) coexist — the case the
    // old uniform position could not represent.
    const refined: ebcot.Coeff = .{ .significant = true, .sign = 0, .magnitude = 16 | 8, .half_bp = 2 };
    const fresh: ebcot.Coeff = .{ .significant = true, .sign = 1, .magnitude = 4, .half_bp = 1 };
    try std.testing.expectEqual(@as(i32, 24 | 4), coeffToOpenJpegI32(refined));
    try std.testing.expectEqual(@as(i32, -(4 | 2)), coeffToOpenJpegI32(fresh));
}
