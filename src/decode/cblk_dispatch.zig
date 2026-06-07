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

/// Run EBCOT tier-1 decode on a single plan. `msb_bp` is the bit
/// position of the most-significant non-zero bit-plane (= numbps - 1
/// in OpenJPEG terms, where numbps = M_b - zero_bitplanes). Returns a
/// heap-owned `Cblk` carrying the decoded coefficients; caller must
/// deinit.
pub fn decodePlan(
    allocator: Allocator,
    plan: CblkDecodePlan,
    msb_bp: u5,
) Allocator.Error!ebcot.Cblk {
    var cblk = try ebcot.Cblk.init(allocator, plan.width(), plan.height());
    errdefer cblk.deinit(allocator);
    if (plan.data.len == 0) return cblk;
    var ctxs = ebcot.initContexts();
    var dec = mq.Decoder.initDec(plan.data);
    const orient = orientationFromBand(plan.band);
    ebcot.decodeCblkPasses(&dec, &cblk, &ctxs, orient, msb_bp, plan.total_passes);
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
        .zero_bitplanes = 0, .total_passes = 0, .cblksty = 0,
        .data = try allocator.alloc(u8, 0),
    };
    defer plan.deinit(allocator);
    var cblk = try decodePlan(allocator, plan, 7);
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
        .zero_bitplanes = 2, .total_passes = 1, .cblksty = 0,
        .data = try allocator.dupe(u8, &[_]u8{ 0x80, 0x80, 0x00, 0x00, 0xFF, 0xAC }),
    };
    defer plan.deinit(allocator);
    var cblk = try decodePlan(allocator, plan, 5);
    defer cblk.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 4), cblk.width);
    try std.testing.expectEqual(@as(u32, 4), cblk.height);
    // .visited reset at end of decode (per the bit-plane orchestrator).
    for (cblk.coeffs) |c| try std.testing.expect(!c.visited);
}
