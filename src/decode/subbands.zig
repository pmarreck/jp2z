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

/// Number of precincts at resolution `r` for an image of size
/// `image_w × image_h` with `num_decomp_levels` decompositions
/// and precinct exponents `(ppx, ppy)`. T.800 B.6 (single tile,
/// origin (0, 0)): numprecincts_x = ceil(trx1 / 2^PPx_r),
/// numprecincts_y = ceil(try1 / 2^PPy_r). Returns (0, 0) on a
/// degenerate (zero-extent) resolution.
pub fn numPrecincts(
    image_w: u32,
    image_h: u32,
    num_decomp_levels: u8,
    r: u8,
    ppx: u4,
    ppy: u4,
) GridSize {
    const ext = resolutionExtent(image_w, image_h, num_decomp_levels, r);
    if (ext.width == 0 or ext.height == 0) return .{ .width = 0, .height = 0 };
    const px: u32 = @as(u32, 1) << @intCast(ppx);
    const py: u32 = @as(u32, 1) << @intCast(ppy);
    return .{
        .width = ceilDivU32(ext.width, px),
        .height = ceilDivU32(ext.height, py),
    };
}

/// Stride (in reference-grid units) of one precinct at resolution
/// `r`. Resolution-r data sits at scale 2^(R - r) of the reference
/// grid, so a precinct of size 2^PPx_r on the resolution-r grid
/// spans 2^(PPx_r + R - r) reference-grid units. Used by PCRL /
/// CPRL outer iteration: the (x, y) loop steps by the *minimum*
/// stride across all (resolution, component) pairs, then asks
/// each (r, c) "is (x, y) on a precinct boundary for me?".
pub fn referenceGridStride(num_decomp_levels: u8, r: u8, ppx: u4, ppy: u4) GridSize {
    std.debug.assert(r <= num_decomp_levels);
    const x_shift: u5 = @intCast(@as(u8, ppx) + num_decomp_levels - r);
    const y_shift: u5 = @intCast(@as(u8, ppy) + num_decomp_levels - r);
    return .{
        .width = @as(u32, 1) << x_shift,
        .height = @as(u32, 1) << y_shift,
    };
}

/// Precinct index at resolution `r` containing reference-grid
/// position `(x, y)`. Row-major (precinct.y * precincts_at_r.width
/// + precinct.x). Caller guarantees (x, y) is within the resolution-r
/// extent. Useful for PCRL/CPRL: at each outer-loop (x, y), call
/// this for each (r, c) to learn which precinct to emit packets for.
pub fn precinctIndexAt(
    image_w: u32,
    image_h: u32,
    num_decomp_levels: u8,
    r: u8,
    ppx: u4,
    ppy: u4,
    x: u32,
    y: u32,
) u32 {
    const stride = referenceGridStride(num_decomp_levels, r, ppx, ppy);
    const pwidth = numPrecincts(image_w, image_h, num_decomp_levels, r, ppx, ppy).width;
    const px = x / stride.width;
    const py = y / stride.height;
    return py * pwidth + px;
}

/// Is reference-grid `(x, y)` aligned to a precinct boundary at
/// resolution `r`? Used by PCRL/CPRL outer iteration to avoid
/// re-emitting the same (r, precinct) for adjacent reference-grid
/// positions (only the precinct's TOP-LEFT corner triggers).
pub fn isOnPrecinctBoundary(num_decomp_levels: u8, r: u8, ppx: u4, ppy: u4, x: u32, y: u32) bool {
    const stride = referenceGridStride(num_decomp_levels, r, ppx, ppy);
    return (x % stride.width == 0) and (y % stride.height == 0);
}

/// Code-block count inside one precinct's portion of one subband.
/// Returns (0, 0) when the precinct doesn't overlap the subband
/// (which is common — most precincts at fine resolutions sit
/// outside the HF subband areas, and most precincts at coarse
/// resolutions span only the LL band).
///
/// The math:
///   1. Precinct rect on resolution-r grid = (px·2^PPx, py·2^PPy)
///      to ((px+1)·2^PPx, (py+1)·2^PPy), clipped to res extent.
///   2. Subband rect on resolution-r grid:
///        r=0 LL: full (0,0)-(res_0.w, res_0.h)
///        r≥1 HL: (res_{r-1}.w, 0)-(res_r.w,  res_{r-1}.h)
///        r≥1 LH: (0, res_{r-1}.h)-(res_{r-1}.w, res_r.h)
///        r≥1 HH: (res_{r-1}.w, res_{r-1}.h)-(res_r.w, res_r.h)
///   3. Intersect (1) and (2); translate to subband-internal coords.
///   4. Cblks tile the subband on a 2^(cblk_w_exp+2) grid starting
///      at (0, 0) subband-internal. Count distinct cblk indices that
///      overlap the precinct's local rect.
pub fn cblksInPrecinctSubband(
    image_w: u32,
    image_h: u32,
    num_decomp_levels: u8,
    r: u8,
    sb_idx: u8,
    precinct_x: u32,
    precinct_y: u32,
    ppx: u4,
    ppy: u4,
    cblk_w_exp: u8,
    cblk_h_exp: u8,
) GridSize {
    const res_ext = resolutionExtent(image_w, image_h, num_decomp_levels, r);
    // 1. Precinct rect on resolution-r grid, clipped to res extent.
    const pdx: u32 = @as(u32, 1) << @intCast(ppx);
    const pdy: u32 = @as(u32, 1) << @intCast(ppy);
    const prc_x0 = precinct_x * pdx;
    const prc_y0 = precinct_y * pdy;
    if (prc_x0 >= res_ext.width or prc_y0 >= res_ext.height) {
        return .{ .width = 0, .height = 0 };
    }
    const prc_x1 = @min(prc_x0 + pdx, res_ext.width);
    const prc_y1 = @min(prc_y0 + pdy, res_ext.height);

    // 2. Subband rect on resolution-r grid.
    var sb_x0: u32 = 0;
    var sb_y0: u32 = 0;
    var sb_x1: u32 = res_ext.width;
    var sb_y1: u32 = res_ext.height;
    if (r > 0) {
        const prev = resolutionExtent(image_w, image_h, num_decomp_levels, r - 1);
        switch (sb_idx) {
            0 => { // HL — upper-right
                sb_x0 = prev.width;
                sb_y1 = prev.height;
            },
            1 => { // LH — lower-left
                sb_x1 = prev.width;
                sb_y0 = prev.height;
            },
            2 => { // HH — lower-right
                sb_x0 = prev.width;
                sb_y0 = prev.height;
            },
            else => return .{ .width = 0, .height = 0 },
        }
    }

    // 3. Intersection on res-r grid.
    const ix0 = @max(prc_x0, sb_x0);
    const iy0 = @max(prc_y0, sb_y0);
    const ix1 = @min(prc_x1, sb_x1);
    const iy1 = @min(prc_y1, sb_y1);
    if (ix1 <= ix0 or iy1 <= iy0) return .{ .width = 0, .height = 0 };

    // 4. Translate to subband-internal coords + cblk count.
    const local_x0 = ix0 - sb_x0;
    const local_y0 = iy0 - sb_y0;
    const local_x1 = ix1 - sb_x0;
    const local_y1 = iy1 - sb_y0;
    // T.800 A.6.1 cap: the actual cblk size for a subband is the
    // smaller of 2^(cblk_exp+2) and the precinct dim in the subband
    // domain. For r=0 LL the subband-domain precinct dim is 2^PPx;
    // for r≥1 HF it's halved to 2^(PPx-1) (the wavelet downsampling
    // halves the precinct in subband space).
    const precinct_dim_x_exp: u8 = if (r == 0) @as(u8, @intCast(ppx)) else @as(u8, @intCast(ppx)) - 1;
    const precinct_dim_y_exp: u8 = if (r == 0) @as(u8, @intCast(ppy)) else @as(u8, @intCast(ppy)) - 1;
    const cblk_w_exp_actual: u8 = @min(cblk_w_exp + 2, precinct_dim_x_exp);
    const cblk_h_exp_actual: u8 = @min(cblk_h_exp + 2, precinct_dim_y_exp);
    const cblk_w: u32 = @as(u32, 1) << @intCast(cblk_w_exp_actual);
    const cblk_h: u32 = @as(u32, 1) << @intCast(cblk_h_exp_actual);
    // Cblks tile the subband on a fixed grid (origins at multiples
    // of cblk_w/cblk_h, starting at (0, 0)). A cblk "belongs to"
    // this precinct iff its ORIGIN is in [local_x0, local_x1) ×
    // [local_y0, local_y1) — NOT merely if the cblk overlaps the
    // rect. (Overlap-counting would double-count cblks straddling
    // a precinct boundary.)
    const first_x = (local_x0 + cblk_w - 1) / cblk_w; // ceil
    const last_x = (local_x1 - 1) / cblk_w; // floor of (x1-1)
    const first_y = (local_y0 + cblk_h - 1) / cblk_h;
    const last_y = (local_y1 - 1) / cblk_h;
    const cblk_x_count: u32 = if (last_x >= first_x) last_x - first_x + 1 else 0;
    const cblk_y_count: u32 = if (last_y >= first_y) last_y - first_y + 1 else 0;
    return .{ .width = cblk_x_count, .height = cblk_y_count };
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

test "numPrecincts: c1_mono.j2c (default 2^15 precincts) — every resolution has 1×1" {
    // c1_mono image 303×179, num_decomp_levels=5, all precincts (15, 15).
    var r: u8 = 0;
    while (r <= 5) : (r += 1) {
        const grid = numPrecincts(303, 179, 5, r, 15, 15);
        try std.testing.expectEqual(@as(u32, 1), grid.width);
        try std.testing.expectEqual(@as(u32, 1), grid.height);
    }
}

test "numPrecincts: d1_colr.j2c (64×64 precincts) — r=5: 4×3, r=4: 2×2, r≤3: 1×1" {
    // d1_colr image 256×149, num_decomp_levels=5, all precincts (6, 6) = 64×64.
    const r5 = numPrecincts(256, 149, 5, 5, 6, 6);
    try std.testing.expectEqual(@as(u32, 4), r5.width);
    try std.testing.expectEqual(@as(u32, 3), r5.height);

    const r4 = numPrecincts(256, 149, 5, 4, 6, 6);
    try std.testing.expectEqual(@as(u32, 2), r4.width);
    try std.testing.expectEqual(@as(u32, 2), r4.height);

    const r3 = numPrecincts(256, 149, 5, 3, 6, 6);
    try std.testing.expectEqual(@as(u32, 1), r3.width);
    try std.testing.expectEqual(@as(u32, 1), r3.height);

    const r0 = numPrecincts(256, 149, 5, 0, 6, 6);
    try std.testing.expectEqual(@as(u32, 1), r0.width);
    try std.testing.expectEqual(@as(u32, 1), r0.height);
}

test "referenceGridStride: d1_colr 64x64 precincts at every res — stride doubles each level coarser" {
    // num_decomp_levels=5, ppx=ppy=6. Strides: r=5→64, r=4→128, ..., r=0→2048.
    try std.testing.expectEqual(@as(u32, 64), referenceGridStride(5, 5, 6, 6).width);
    try std.testing.expectEqual(@as(u32, 128), referenceGridStride(5, 4, 6, 6).width);
    try std.testing.expectEqual(@as(u32, 256), referenceGridStride(5, 3, 6, 6).width);
    try std.testing.expectEqual(@as(u32, 2048), referenceGridStride(5, 0, 6, 6).width);
}

test "precinctIndexAt: d1_colr 256x149, r=5 — finest-resolution positions map row-major" {
    // d1_colr r=5: 4×3 = 12 precincts. Stride 64.
    // (0,0)→0, (64,0)→1, (128,0)→2, (192,0)→3
    // (0,64)→4, (64,64)→5, ..., (192,64)→7
    // (0,128)→8, (64,128)→9, ..., (192,128)→11
    try std.testing.expectEqual(@as(u32, 0), precinctIndexAt(256, 149, 5, 5, 6, 6, 0, 0));
    try std.testing.expectEqual(@as(u32, 1), precinctIndexAt(256, 149, 5, 5, 6, 6, 64, 0));
    try std.testing.expectEqual(@as(u32, 3), precinctIndexAt(256, 149, 5, 5, 6, 6, 192, 0));
    try std.testing.expectEqual(@as(u32, 4), precinctIndexAt(256, 149, 5, 5, 6, 6, 0, 64));
    try std.testing.expectEqual(@as(u32, 11), precinctIndexAt(256, 149, 5, 5, 6, 6, 192, 128));
}

test "isOnPrecinctBoundary: PCRL outer iteration determines which (r) fires at each (x,y)" {
    // At reference (x=64, y=0) for d1_colr (5, 6, 6):
    //   r=5 stride=64: on boundary (64 % 64 == 0)
    //   r=4 stride=128: NOT on boundary (64 % 128 != 0)
    //   r=3 stride=256: NOT on boundary
    try std.testing.expectEqual(true, isOnPrecinctBoundary(5, 5, 6, 6, 64, 0));
    try std.testing.expectEqual(false, isOnPrecinctBoundary(5, 4, 6, 6, 64, 0));
    try std.testing.expectEqual(false, isOnPrecinctBoundary(5, 3, 6, 6, 64, 0));

    // At reference (x=128, y=0):
    //   r=5: on boundary (128 % 64 == 0)
    //   r=4: on boundary (128 % 128 == 0)
    //   r=3: NOT (128 % 256 != 0)
    try std.testing.expectEqual(true, isOnPrecinctBoundary(5, 5, 6, 6, 128, 0));
    try std.testing.expectEqual(true, isOnPrecinctBoundary(5, 4, 6, 6, 128, 0));
    try std.testing.expectEqual(false, isOnPrecinctBoundary(5, 3, 6, 6, 128, 0));

    // At (0, 0): on boundary for every resolution.
    var r: u8 = 0;
    while (r <= 5) : (r += 1) {
        try std.testing.expectEqual(true, isOnPrecinctBoundary(5, r, 6, 6, 0, 0));
    }
}

test "cblksInPrecinctSubband: d1_colr r=5 precinct (0,0) — outside HF area → 0 cblks for every HF subband" {
    // d1_colr image 256×149, num_decomp_levels=5, precincts 64×64, cblks 64×64.
    // Precinct (0,0) at r=5 covers res-r grid (0,0)–(64,64), entirely inside
    // the LL_4 quadrant. All three HF subbands at r=5 start past x=128 or
    // y=75, so the precinct intersects none of them.
    var sb: u8 = 0;
    while (sb < 3) : (sb += 1) {
        const g = cblksInPrecinctSubband(256, 149, 5, 5, sb, 0, 0, 6, 6, 4, 4);
        try std.testing.expectEqual(@as(u32, 0), g.width);
        try std.testing.expectEqual(@as(u32, 0), g.height);
    }
}

test "cblksInPrecinctSubband: d1_colr r=5 precinct (2,0) HL → 2×2 cblks (cblk capped to 32 by precinct)" {
    // Precinct (2,0) covers res-r (128,0)-(192,64). Intersects HL_5
    // (res-r (128,0)-(256,75)) → (128,0)-(192,64). 64×64.
    // In HL subband-internal: (0,0)-(64,64). T.800 A.6.1 cap: HF
    // cblk = min(2^(4+2)=64, 2^(PPx-1)=32) = 32. Cblk origins at
    // (0,0), (32,0), (0,32), (32,32) — all 4 in rect → 2×2.
    const g = cblksInPrecinctSubband(256, 149, 5, 5, 0, 2, 0, 6, 6, 4, 4);
    try std.testing.expectEqual(@as(u32, 2), g.width);
    try std.testing.expectEqual(@as(u32, 2), g.height);
}

test "cblksInPrecinctSubband: d1_colr r=5 precinct (3,2) HH (image edge) → 2×1 cblks" {
    // Precinct (3,2) covers res-r (192,128)-(256,192), clipped to image
    // extent → (192,128)-(256,149). Intersects HH_5 (res-r (128,75)-
    // (256,149)) → (192,128)-(256,149). 64×21.
    // HH subband-internal: (64,53)-(128,74). With 32×32 cblks (capped),
    // origins in rect: (64,64) and (96,64) → 2×1.
    const g = cblksInPrecinctSubband(256, 149, 5, 5, 2, 3, 2, 6, 6, 4, 4);
    try std.testing.expectEqual(@as(u32, 2), g.width);
    try std.testing.expectEqual(@as(u32, 1), g.height);
}

test "cblksInPrecinctSubband: c1_mono default precincts → whole subband per precinct" {
    // c1_mono image 303×179, default precincts 2^15. Every (resolution,
    // subband) has exactly one precinct that contains the entire subband.
    // r=5 HL subband: 151×90 → cblk grid 3×2 = 6.
    const g = cblksInPrecinctSubband(303, 179, 5, 5, 0, 0, 0, 15, 15, 4, 4);
    try std.testing.expectEqual(@as(u32, 3), g.width);
    try std.testing.expectEqual(@as(u32, 2), g.height);
}

test "cblksInPrecinctSubband: r=0 LL — precinct intersects the LL subband" {
    // d1_colr r=0: LL is res_0 extent (8×5). Precinct (0,0) on res-r
    // grid is (0,0)-(64,64) but clipped to (0,0)-(8,5). cblks 64×64: 1×1.
    const g = cblksInPrecinctSubband(256, 149, 5, 0, 0, 0, 0, 6, 6, 4, 4);
    try std.testing.expectEqual(@as(u32, 1), g.width);
    try std.testing.expectEqual(@as(u32, 1), g.height);
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
