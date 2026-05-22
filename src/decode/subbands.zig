//! Per-(resolution, subband) geometry: extents, subband partitioning,
//! and code-block grid sizes. T.800 Annex F + B.7.
//!
//! Conventions (single-tile, image-origin = (0,0); explicit tile
//! origins land when M2 supports multi-tile codestreams):
//!
//!   numresolutions  = num_decomp_levels + 1
//!   resolution r    = 0 (smallest, LL only) .. R = num_decomp_levels (full image)
//!   at resolution r, the "full extent" =
//!     ceil(W / 2^(R-r)) × ceil(H / 2^(R-r))
//!   r == 0:  one subband (LL), dims == full extent at r=0
//!   r >= 1:  three subbands HL, LH, HH that fill the delta
//!            between resolution (r-1) and resolution (r):
//!     HL_r: width  = res_r.w  - res_{r-1}.w
//!           height = res_{r-1}.h
//!     LH_r: width  = res_{r-1}.w
//!           height = res_r.h  - res_{r-1}.h
//!     HH_r: width  = res_r.w  - res_{r-1}.w
//!           height = res_r.h  - res_{r-1}.h
//!
//! Default precincts (Scod bit 0 = 0): each (resolution, subband)
//! has exactly one precinct, sized 2^15 × 2^15 — i.e. larger than
//! any practical image. The code-block grid for that single
//! precinct is just ceil(subband.w / cblk.w) × ceil(subband.h /
//! cblk.h).

const std = @import("std");

pub const SubbandKind = enum(u8) {
    ll, // only at resolution 0
    hl, // only at resolution >= 1
    lh, // only at resolution >= 1
    hh, // only at resolution >= 1
};

pub const SubbandInfo = struct {
    kind: SubbandKind,
    width: u32,
    height: u32,
};

pub const GridSize = struct {
    width: u32,
    height: u32,
};

/// Full extent (the LL "image" plus accumulated HF detail) at the
/// given resolution. For r = num_decomp_levels (= R), this returns
/// the original image size.
pub fn resolutionExtent(image_w: u32, image_h: u32, num_decomp_levels: u8, r: u8) GridSize {
    std.debug.assert(r <= num_decomp_levels);
    const shift: u5 = @intCast(num_decomp_levels - r);
    return .{
        .width = ceilShift(image_w, shift),
        .height = ceilShift(image_h, shift),
    };
}

/// Number of subbands at resolution r: 1 (LL) at r=0, 3 (HL/LH/HH) at r>=1.
pub fn subbandCount(r: u8) u8 {
    return if (r == 0) 1 else 3;
}

/// Get the i-th subband (0..subbandCount(r)) at resolution r.
/// At r == 0, only i == 0 is valid (LL). At r >= 1, i == 0/1/2 maps
/// to HL/LH/HH respectively.
pub fn subbandDims(
    image_w: u32,
    image_h: u32,
    num_decomp_levels: u8,
    r: u8,
    i: u8,
) SubbandInfo {
    std.debug.assert(i < subbandCount(r));
    if (r == 0) {
        const ext = resolutionExtent(image_w, image_h, num_decomp_levels, 0);
        return .{ .kind = .ll, .width = ext.width, .height = ext.height };
    }
    const cur = resolutionExtent(image_w, image_h, num_decomp_levels, r);
    const prev = resolutionExtent(image_w, image_h, num_decomp_levels, r - 1);
    return switch (i) {
        0 => .{ .kind = .hl, .width = cur.width - prev.width, .height = prev.height },
        1 => .{ .kind = .lh, .width = prev.width, .height = cur.height - prev.height },
        2 => .{ .kind = .hh, .width = cur.width - prev.width, .height = cur.height - prev.height },
        else => unreachable,
    };
}

/// Code-block grid size for one precinct's portion of a subband,
/// assuming default precincts (one precinct per subband).
/// cblk_w_exp / cblk_h_exp are the COD-encoded exponents — actual
/// code-block dimension = 2^(exp + 2).
pub fn codeBlockGrid(subband: SubbandInfo, cblk_w_exp: u8, cblk_h_exp: u8) GridSize {
    const cblk_w: u32 = @as(u32, 1) << @intCast(cblk_w_exp + 2);
    const cblk_h: u32 = @as(u32, 1) << @intCast(cblk_h_exp + 2);
    return .{
        .width = ceilDivU32(subband.width, cblk_w),
        .height = ceilDivU32(subband.height, cblk_h),
    };
}

/// Total code-blocks across every resolution and subband (single
/// component, single precinct per subband). Useful as a sanity
/// metric for "what does it take to walk one (component, layer)
/// pair through all packets?"
pub fn totalCodeBlocksPerLayerPerComponent(
    image_w: u32,
    image_h: u32,
    num_decomp_levels: u8,
    cblk_w_exp: u8,
    cblk_h_exp: u8,
) u32 {
    var total: u32 = 0;
    var r: u8 = 0;
    while (r <= num_decomp_levels) : (r += 1) {
        const n = subbandCount(r);
        var i: u8 = 0;
        while (i < n) : (i += 1) {
            const sb = subbandDims(image_w, image_h, num_decomp_levels, r, i);
            const grid = codeBlockGrid(sb, cblk_w_exp, cblk_h_exp);
            total += grid.width * grid.height;
        }
    }
    return total;
}

fn ceilShift(n: u32, shift: u5) u32 {
    if (shift == 0) return n;
    const divisor: u32 = @as(u32, 1) << shift;
    return ceilDivU32(n, divisor);
}

fn ceilDivU32(a: u32, b: u32) u32 {
    return (a + b - 1) / b;
}

// ── Tests ──────────────────────────────────────────────────────────

test "resolutionExtent: c1_mono.j2c (303x179, 5 decomp) — LL is 10x6, full is 303x179" {
    const r0 = resolutionExtent(303, 179, 5, 0);
    try std.testing.expectEqual(@as(u32, 10), r0.width);
    try std.testing.expectEqual(@as(u32, 6), r0.height);
    const r5 = resolutionExtent(303, 179, 5, 5);
    try std.testing.expectEqual(@as(u32, 303), r5.width);
    try std.testing.expectEqual(@as(u32, 179), r5.height);
}

test "subbandDims: r=0 is single LL; r>=1 has HL/LH/HH that sum to delta" {
    // At r=1: full extent is 19x12, previous (r=0) is 10x6.
    // HL_1: width = 19-10 = 9, height = 6.
    // LH_1: width = 10,       height = 12-6 = 6.
    // HH_1: width = 9,        height = 6.
    const ll = subbandDims(303, 179, 5, 0, 0);
    try std.testing.expectEqual(SubbandKind.ll, ll.kind);
    try std.testing.expectEqual(@as(u32, 10), ll.width);
    try std.testing.expectEqual(@as(u32, 6), ll.height);

    const hl1 = subbandDims(303, 179, 5, 1, 0);
    try std.testing.expectEqual(SubbandKind.hl, hl1.kind);
    try std.testing.expectEqual(@as(u32, 9), hl1.width);
    try std.testing.expectEqual(@as(u32, 6), hl1.height);

    const lh1 = subbandDims(303, 179, 5, 1, 1);
    try std.testing.expectEqual(SubbandKind.lh, lh1.kind);
    try std.testing.expectEqual(@as(u32, 10), lh1.width);
    try std.testing.expectEqual(@as(u32, 6), lh1.height);

    const hh1 = subbandDims(303, 179, 5, 1, 2);
    try std.testing.expectEqual(SubbandKind.hh, hh1.kind);
    try std.testing.expectEqual(@as(u32, 9), hh1.width);
    try std.testing.expectEqual(@as(u32, 6), hh1.height);
}

test "subbandDims: r=5 (full res) subbands cover the WxH plus the r=4 LL" {
    // r=5: full extent = 303x179, r=4 extent = 152x90.
    // HL_5: 303-152=151 × 90.
    // LH_5: 152 × 179-90=89.
    // HH_5: 151 × 89.
    const hl = subbandDims(303, 179, 5, 5, 0);
    try std.testing.expectEqual(@as(u32, 151), hl.width);
    try std.testing.expectEqual(@as(u32, 90), hl.height);
    const lh = subbandDims(303, 179, 5, 5, 1);
    try std.testing.expectEqual(@as(u32, 152), lh.width);
    try std.testing.expectEqual(@as(u32, 89), lh.height);
    const hh = subbandDims(303, 179, 5, 5, 2);
    try std.testing.expectEqual(@as(u32, 151), hh.width);
    try std.testing.expectEqual(@as(u32, 89), hh.height);
}

test "codeBlockGrid: 64x64 code-blocks against various subbands" {
    // 10x6 subband, 64x64 cblk → 1x1
    const g_small = codeBlockGrid(.{ .kind = .ll, .width = 10, .height = 6 }, 4, 4);
    try std.testing.expectEqual(@as(u32, 1), g_small.width);
    try std.testing.expectEqual(@as(u32, 1), g_small.height);

    // 76x45 subband, 64x64 cblk → 2x1
    const g_mid = codeBlockGrid(.{ .kind = .hl, .width = 76, .height = 45 }, 4, 4);
    try std.testing.expectEqual(@as(u32, 2), g_mid.width);
    try std.testing.expectEqual(@as(u32, 1), g_mid.height);

    // 151x90 subband, 64x64 cblk → 3x2 (ceil)
    const g_big = codeBlockGrid(.{ .kind = .hl, .width = 151, .height = 90 }, 4, 4);
    try std.testing.expectEqual(@as(u32, 3), g_big.width);
    try std.testing.expectEqual(@as(u32, 2), g_big.height);
}

test "totalCodeBlocksPerLayerPerComponent: c1_mono.j2c = 34" {
    // Hand-counted:
    //   r=0 (LL 10x6):         1
    //   r=1 (HF 9x6,10x6,9x6): 3
    //   r=2 (HF 19x12,19x11,19x11): 3
    //   r=3 (HF 38x23,38x22,38x22): 3
    //   r=4 (HF 76x45,76x45,76x45): 3 * 2*1 = 6
    //   r=5 (HF 151x90,152x89,151x89): 3 * 3*2 = 18
    //   Total: 1 + 3 + 3 + 3 + 6 + 18 = 34
    const n = totalCodeBlocksPerLayerPerComponent(303, 179, 5, 4, 4);
    try std.testing.expectEqual(@as(u32, 34), n);
}
