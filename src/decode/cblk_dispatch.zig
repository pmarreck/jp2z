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
    const msb_bp: u5 = @intCast(plan.numbps);
    if (plan.segments.len == 0) {
        // No per-segment breakdown (synthetic test plans): decode the whole
        // slice as one continuous MQ stream.
        var dec = mq.Decoder.initDec(plan.data);
        ebcot.decodeCblkPasses(&dec, &cblk, &ctxs, orient, msb_bp, plan.total_passes);
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

/// Bit-plane position at which to insert OpenJPEG's "+0.5 of last bin"
/// reconstruction half-bit. T.800 D.4 (and OpenJPEG t1.c) keep the
/// post-decode coefficient centred in its quantization interval by
/// adding `(1 << (bp_min - 1))` to the magnitude, where `bp_min` is the
/// deepest bit-plane that received a coding pass. When the decoder ran
/// down to bp=0 the half-bit collapses to bit 0 of the magnitude.
///
/// Pass schedule (matches `decodeCblkPasses`): pass 0 is CL@msb_bp,
/// then every group of 3 subsequent passes drops one bit-plane.
pub fn halfBitPos(msb_bp: u5, total_passes: u32) u5 {
    if (total_passes == 0) return 0;
    // ceil((total_passes - 1) / 3) = (total_passes + 1) / 3 for tp >= 1.
    const decrements: u32 = (total_passes + 1) / 3;
    if (decrements >= msb_bp) return 0;
    const bp_min: u32 = @as(u32, msb_bp) - decrements;
    return if (bp_min == 0) 0 else @intCast(bp_min - 1);
}

/// Convert one `ebcot.Coeff` into the i32 sign-magnitude layout that
/// OpenJPEG's `t1_decode_cblk` writes to `t1->data`:
///
///   - not significant      → 0
///   - significant, sign=0  → +(|magnitude| | (1 << half_bit_pos))
///   - significant, sign=1  → -(|magnitude| | (1 << half_bit_pos))
///
/// The bit-OR places the half-bit reconstruction marker that OpenJPEG
/// adds via `oneplushalf` / `poshalf` adjustments during decode.
pub fn coeffToOpenJpegI32(coeff: ebcot.Coeff, half_bit_pos: u5) i32 {
    if (!coeff.significant) return 0;
    const mag: u32 = coeff.magnitude | (@as(u32, 1) << half_bit_pos);
    const mag_i32: i32 = @intCast(mag);
    return if (coeff.sign == 0) mag_i32 else -mag_i32;
}

test "halfBitPos: total_passes=0 → 0 (degenerate)" {
    try std.testing.expectEqual(@as(u5, 0), halfBitPos(7, 0));
}

test "halfBitPos: total_passes=1 → msb_bp-1 (only CL at msb_bp, bp_min=msb_bp)" {
    try std.testing.expectEqual(@as(u5, 6), halfBitPos(7, 1));
    try std.testing.expectEqual(@as(u5, 2), halfBitPos(3, 1));
}

test "halfBitPos: total_passes=4 → msb_bp-2 (CL@k, SP+MR+CL@k-1)" {
    // bp_min = msb_bp - 1, half = bp_min - 1 = msb_bp - 2.
    try std.testing.expectEqual(@as(u5, 5), halfBitPos(7, 4));
}

test "halfBitPos: full depth (all bp processed) → 0" {
    // msb_bp=7: total_passes = 1 + 3*7 = 22. bp_min=0. half_bit=0.
    try std.testing.expectEqual(@as(u5, 0), halfBitPos(7, 22));
    // msb_bp=3: total_passes = 1 + 3*3 = 10.
    try std.testing.expectEqual(@as(u5, 0), halfBitPos(3, 10));
}

test "halfBitPos: decrements clamp at msb_bp (over-truncated input)" {
    // Pathological: more passes than the bit-plane budget allows.
    // Should still return 0 (we've gone past the LSB).
    try std.testing.expectEqual(@as(u5, 0), halfBitPos(2, 100));
}

test "coeffToOpenJpegI32: not significant → 0" {
    const c: ebcot.Coeff = .{ .significant = false, .sign = 0, .magnitude = 0, .visited = false, .refined = false };
    try std.testing.expectEqual(@as(i32, 0), coeffToOpenJpegI32(c, 6));
}

test "coeffToOpenJpegI32: sig only at bp=3 (no refines), half_bit=2 → +oneplushalf_3 = 12" {
    const c: ebcot.Coeff = .{ .significant = true, .sign = 0, .magnitude = 8, .visited = false, .refined = false };
    try std.testing.expectEqual(@as(i32, 12), coeffToOpenJpegI32(c, 2));
}

test "coeffToOpenJpegI32: sig+refs full depth (half_bit=0) matches hand-derived OJ values" {
    // Hand-derived from t1.c: sig at bp=3 followed by MR at bp=2,1,0
    // with arbitrary refinement bits.
    //
    //   bits decoded: sig@3=1, MR@2=0, MR@1=1, MR@0=0 → our mag = 1010 = 10
    //   OJ trace: 12 → 10 → 11 → 11.
    const c1: ebcot.Coeff = .{ .significant = true, .sign = 0, .magnitude = 10, .visited = false, .refined = false };
    try std.testing.expectEqual(@as(i32, 11), coeffToOpenJpegI32(c1, 0));
    // Same example with negative sign → -11.
    const c1_neg: ebcot.Coeff = .{ .significant = true, .sign = 1, .magnitude = 10, .visited = false, .refined = false };
    try std.testing.expectEqual(@as(i32, -11), coeffToOpenJpegI32(c1_neg, 0));
    //
    //   bits decoded: sig@3=1, MR@2=1, MR@1=1, MR@0=1 → our mag = 1111 = 15
    //   OJ trace: 12 → 14 → 15 → 15.
    const c2: ebcot.Coeff = .{ .significant = true, .sign = 0, .magnitude = 15, .visited = false, .refined = false };
    try std.testing.expectEqual(@as(i32, 15), coeffToOpenJpegI32(c2, 0));
    //
    //   bits decoded: sig@3=1, MR@2=0, MR@1=0, MR@0=0 → our mag = 1000 = 8
    //   OJ trace: 12 → 10 → 9 → 9.
    const c3: ebcot.Coeff = .{ .significant = true, .sign = 0, .magnitude = 8, .visited = false, .refined = false };
    try std.testing.expectEqual(@as(i32, 9), coeffToOpenJpegI32(c3, 0));
}

test "coeffToOpenJpegI32: partial depth (bp_min=2, half_bit=1)" {
    // sig at bp=3, MR at bp=2 with v=0 → our mag = 8.
    // OJ trace: 12 → 10. half_bit=1 → 8 | 2 = 10.
    const c1: ebcot.Coeff = .{ .significant = true, .sign = 0, .magnitude = 8, .visited = false, .refined = false };
    try std.testing.expectEqual(@as(i32, 10), coeffToOpenJpegI32(c1, 1));
    // sig at bp=3, MR at bp=2 with v=1 → our mag = 12.
    // OJ: 12 → 14. half_bit=1 → 12 | 2 = 14.
    const c2: ebcot.Coeff = .{ .significant = true, .sign = 0, .magnitude = 12, .visited = false, .refined = false };
    try std.testing.expectEqual(@as(i32, 14), coeffToOpenJpegI32(c2, 1));
}
