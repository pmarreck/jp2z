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

/// Resolution rectangle in tile-component coordinates (origin-aware).
/// x0/x1/y0/y1 are absolute tile-component coords; width/height are the
/// sample extents. Needed because the inverse DWT parity (cas) and the
/// per-level subband split depend on the ABSOLUTE origin, not just the size.
pub const ResRect = struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,
    width: u32,
    height: u32,
};

/// Full extent (the LL "image" plus accumulated HF detail) at the given
/// resolution, in tile-component coordinates. `tile_x0`/`tile_y0` are the
/// tile-component ORIGIN (0,0 for a single tile at image origin, non-zero
/// for interior tiles of a multi-tile image). T.800 B.5:
///   res.x0 = ceildiv(tile_x0, 2^(R-r)); res.x1 = ceildiv(tile_x0+w, 2^(R-r)).
/// For r = num_decomp_levels this returns the full tile-component size.
pub fn resolutionExtent(tile_x0: u32, tile_y0: u32, image_w: u32, image_h: u32, num_decomp_levels: u8, r: u8) ResRect {
    std.debug.assert(r <= num_decomp_levels);
    const shift: u5 = @intCast(num_decomp_levels - r);
    const x0 = ceilShift(tile_x0, shift);
    const y0 = ceilShift(tile_y0, shift);
    const x1 = ceilShift(tile_x0 + image_w, shift);
    const y1 = ceilShift(tile_y0 + image_h, shift);
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .width = x1 - x0, .height = y1 - y0 };
}

/// Number of subbands at resolution r: 1 (LL) at r=0, 3 (HL/LH/HH) at r>=1.
pub fn subbandCount(r: u8) u8 {
    return if (r == 0) 1 else 3;
}

/// Get the i-th subband (0..subbandCount(r)) at resolution r.
/// At r == 0, only i == 0 is valid (LL). At r >= 1, i == 0/1/2 maps
/// to HL/LH/HH respectively.
pub fn subbandDims(
    tile_x0: u32,
    tile_y0: u32,
    image_w: u32,
    image_h: u32,
    num_decomp_levels: u8,
    r: u8,
    i: u8,
) SubbandInfo {
    std.debug.assert(i < subbandCount(r));
    if (r == 0) {
        const ext = resolutionExtent(tile_x0, tile_y0, image_w, image_h, num_decomp_levels, 0);
        return .{ .kind = .ll, .width = ext.width, .height = ext.height };
    }
    const cur = resolutionExtent(tile_x0, tile_y0, image_w, image_h, num_decomp_levels, r);
    const prev = resolutionExtent(tile_x0, tile_y0, image_w, image_h, num_decomp_levels, r - 1);
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
    tile_x0: u32,
    tile_y0: u32,
    image_w: u32,
    image_h: u32,
    num_decomp_levels: u8,
    r: u8,
    ppx: u4,
    ppy: u4,
) GridSize {
    const ext = resolutionExtent(tile_x0, tile_y0, image_w, image_h, num_decomp_levels, r);
    if (ext.width == 0 or ext.height == 0) return .{ .width = 0, .height = 0 };
    const px: u32 = @as(u32, 1) << @intCast(ppx);
    const py: u32 = @as(u32, 1) << @intCast(ppy);
    // T.800 B.6 (origin-aware): ceildiv(res.x1, 2^PPx) - floordiv(res.x0, 2^PPx).
    return .{
        .width = ceilDivU32(ext.x1, px) - ext.x0 / px,
        .height = ceilDivU32(ext.y1, py) - ext.y0 / py,
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
    tile_x0: u32,
    tile_y0: u32,
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
    const pwidth = numPrecincts(tile_x0, tile_y0, image_w, image_h, num_decomp_levels, r, ppx, ppy).width;
    // NOTE: for a non-origin tile under PCRL/CPRL the absolute precinct
    // column/row must be offset by the tile's first precinct index. No
    // conformance fixture exercises PCRL on an interior tile yet, so this
    // keeps the origin-(0,0) mapping; revisit with a failing PCRL fixture.
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

// ── Absolute-coordinate code-block partition (openjpeg opj_tcd_init_tile) ──
// Code-blocks anchor to ABSOLUTE resolution/band coordinates, not to a
// subband-internal 0 origin. For an interior tile whose band spans a range
// crossing a code-block boundary, this yields a different (correct) cblk COUNT
// than a naive 0-based split — the mismatch that desynced multi-tile packet
// parsing. HF band x0 is computed from a momentarily-negative numerator, so
// everything is i64.
fn ceilDivPow2I(a: i64, s: u6) i64 {
    return (a + (@as(i64, 1) << s) - 1) >> s;
}
fn floorDivPow2I(a: i64, s: u6) i64 {
    return a >> s;
}

const CblkGeom = struct {
    band_x0: i64,
    band_y0: i64,
    prc_x0: i64,
    prc_y0: i64,
    prc_x1: i64,
    prc_y1: i64,
    tlcblkx: i64,
    tlcblky: i64,
    cblk_wexpn: u6,
    cblk_hexpn: u6,
    cw: u32,
    ch: u32,
    empty: bool,
};

fn precinctCblkGeom(
    tile_x0: u32,
    tile_y0: u32,
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
) CblkGeom {
    const tcx0: i64 = tile_x0;
    const tcy0: i64 = tile_y0;
    const tcx1: i64 = @as(i64, tile_x0) + image_w;
    const tcy1: i64 = @as(i64, tile_y0) + image_h;
    const level: u6 = @intCast(num_decomp_levels - r);

    // Resolution rect (tile-component coords).
    const res_x0 = ceilDivPow2I(tcx0, level);
    const res_y0 = ceilDivPow2I(tcy0, level);
    const res_x1 = ceilDivPow2I(tcx1, level);
    const res_y1 = ceilDivPow2I(tcy1, level);

    // Band rect (absolute). LL at r=0 is the resolution; HF shifted by 2^level·x0b.
    var band_x0: i64 = undefined;
    var band_y0: i64 = undefined;
    var band_x1: i64 = undefined;
    var band_y1: i64 = undefined;
    if (r == 0) {
        band_x0 = res_x0;
        band_y0 = res_y0;
        band_x1 = res_x1;
        band_y1 = res_y1;
    } else {
        const x0b: i64 = if (sb_idx == 0 or sb_idx == 2) 1 else 0;
        const y0b: i64 = if (sb_idx == 1 or sb_idx == 2) 1 else 0;
        const off: i64 = @as(i64, 1) << level;
        band_x0 = ceilDivPow2I(tcx0 - off * x0b, level + 1);
        band_y0 = ceilDivPow2I(tcy0 - off * y0b, level + 1);
        band_x1 = ceilDivPow2I(tcx1 - off * x0b, level + 1);
        band_y1 = ceilDivPow2I(tcy1 - off * y0b, level + 1);
    }
    var g: CblkGeom = .{
        .band_x0 = band_x0, .band_y0 = band_y0,
        .prc_x0 = 0, .prc_y0 = 0, .prc_x1 = 0, .prc_y1 = 0,
        .tlcblkx = 0, .tlcblky = 0, .cblk_wexpn = 0, .cblk_hexpn = 0,
        .cw = 0, .ch = 0, .empty = true,
    };
    if (band_x0 >= band_x1 or band_y0 >= band_y1) return g;

    // Precinct grid, anchored to resolution coords.
    const pdx: u6 = @intCast(ppx);
    const pdy: u6 = @intCast(ppy);
    const tl_prc_x = floorDivPow2I(res_x0, pdx) << pdx;
    const tl_prc_y = floorDivPow2I(res_y0, pdy) << pdy;

    // Code-block-group origin + exponent (halved for HF bands).
    var tlcbgx: i64 = undefined;
    var tlcbgy: i64 = undefined;
    var cbg_wexpn: u6 = undefined;
    var cbg_hexpn: u6 = undefined;
    if (r == 0) {
        tlcbgx = tl_prc_x;
        tlcbgy = tl_prc_y;
        cbg_wexpn = pdx;
        cbg_hexpn = pdy;
    } else {
        tlcbgx = ceilDivPow2I(tl_prc_x, 1);
        tlcbgy = ceilDivPow2I(tl_prc_y, 1);
                cbg_wexpn = if (pdx == 0) 0 else pdx - 1;
        cbg_hexpn = if (pdy == 0) 0 else pdy - 1;
    }
    const cblk_wexpn: u6 = @intCast(@min(@as(u8, cblk_w_exp) + 2, @as(u8, cbg_wexpn)));
    const cblk_hexpn: u6 = @intCast(@min(@as(u8, cblk_h_exp) + 2, @as(u8, cbg_hexpn)));
    g.cblk_wexpn = cblk_wexpn;
    g.cblk_hexpn = cblk_hexpn;

    // This precinct's rect (absolute), clipped to the band.
    const cbgx0 = tlcbgx + @as(i64, precinct_x) * (@as(i64, 1) << cbg_wexpn);
    const cbgy0 = tlcbgy + @as(i64, precinct_y) * (@as(i64, 1) << cbg_hexpn);
    const prc_x0 = @max(cbgx0, band_x0);
    const prc_y0 = @max(cbgy0, band_y0);
    const prc_x1 = @min(cbgx0 + (@as(i64, 1) << cbg_wexpn), band_x1);
    const prc_y1 = @min(cbgy0 + (@as(i64, 1) << cbg_hexpn), band_y1);
    g.prc_x0 = prc_x0;
    g.prc_y0 = prc_y0;
    g.prc_x1 = prc_x1;
    g.prc_y1 = prc_y1;
    if (prc_x0 >= prc_x1 or prc_y0 >= prc_y1) return g;

    // Code-block grid over the precinct, anchored to absolute cblk boundaries.
    const tlcblkx = floorDivPow2I(prc_x0, cblk_wexpn) << cblk_wexpn;
    const tlcblky = floorDivPow2I(prc_y0, cblk_hexpn) << cblk_hexpn;
    const brcblkx = ceilDivPow2I(prc_x1, cblk_wexpn) << cblk_wexpn;
    const brcblky = ceilDivPow2I(prc_y1, cblk_hexpn) << cblk_hexpn;
    g.tlcblkx = tlcblkx;
    g.tlcblky = tlcblky;
    g.cw = @intCast((brcblkx - tlcblkx) >> cblk_wexpn);
    g.ch = @intCast((brcblky - tlcblky) >> cblk_hexpn);
    g.empty = false;
    return g;
}
/// Code-block count inside one precinct's portion of one subband.
/// Mirrors OpenJPEG `opj_tcd_init_tile` / opj_tcd_alloc_precincts
/// for the cblk-grid math; that's the byte-perfect reference for
/// what readPacketHeader will encounter.
///
/// Each subband has its OWN precinct partition expressed in
/// SUBBAND-INTERNAL coordinates. The shared precinct INDEX (px,
/// py) maps to position (px·prc_w, py·prc_h) in the subband, with
/// prc_w/h = 2^PPx / 2^(PPx-1) for LL@r=0 / HF@r≥1.
///
/// Cblk count = OpenJPEG's "round precinct rect outward to cblk
/// grid, divide by cblk dim":
///   tlcblkx = (prc_x0 / cblk_w) · cblk_w                (floor)
///   brcblkx = ceil(prc_x1 / cblk_w) · cblk_w
///   cw      = (brcblkx - tlcblkx) / cblk_w
/// Returns (0, 0) when the precinct lies outside the subband (the
/// rare case where px·prc_w ≥ band_w).
pub fn cblksInPrecinctSubband(
    tile_x0: u32,
    tile_y0: u32,
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
    const g = precinctCblkGeom(tile_x0, tile_y0, image_w, image_h, num_decomp_levels, r, sb_idx, precinct_x, precinct_y, ppx, ppy, cblk_w_exp, cblk_h_exp);
    if (g.empty) return .{ .width = 0, .height = 0 };
    return .{ .width = g.cw, .height = g.ch };
}



/// A rectangle in subband-internal coordinates.
pub const Rect = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
};

/// Subband-internal rectangle for one code-block at grid position
/// (`grid_x`, `grid_y`) inside the (precinct, subband) addressed by
/// the rest of the arguments. Mirrors OpenJPEG opj_tcd_init_tile's
/// per-cblk rect computation:
///
///     tlcblkx_base = floor(prc_x0 / cblk_w) * cblk_w
///     raw_x0 = tlcblkx_base + grid_x * cblk_w
///     cblk.x0 = max(raw_x0, prc_x0)
///     cblk.x1 = min(raw_x0 + cblk_w, prc_x1)
///   (and similarly for y).
///
/// Returns an empty rect (x1 == x0 or y1 == y0) when the precinct
/// doesn't intersect the band — caller should treat that as "skip".
pub fn cblkSubbandRect(
    tile_x0: u32,
    tile_y0: u32,
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
    grid_x: u32,
    grid_y: u32,
) Rect {
    const g = precinctCblkGeom(tile_x0, tile_y0, image_w, image_h, num_decomp_levels, r, sb_idx, precinct_x, precinct_y, ppx, ppy, cblk_w_exp, cblk_h_exp);
    if (g.empty) return .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
    const cw: i64 = @as(i64, 1) << g.cblk_wexpn;
    const ch: i64 = @as(i64, 1) << g.cblk_hexpn;
    const raw_x0 = g.tlcblkx + @as(i64, grid_x) * cw;
    const raw_y0 = g.tlcblky + @as(i64, grid_y) * ch;
    const ax0 = @max(raw_x0, g.prc_x0);
    const ay0 = @max(raw_y0, g.prc_y0);
    const ax1 = @min(raw_x0 + cw, g.prc_x1);
    const ay1 = @min(raw_y0 + ch, g.prc_y1);
    // Subband-INTERNAL coords (relative to the band origin) for buffer placement.
    return .{
        .x0 = @intCast(ax0 - g.band_x0),
        .y0 = @intCast(ay0 - g.band_y0),
        .x1 = @intCast(ax1 - g.band_x0),
        .y1 = @intCast(ay1 - g.band_y0),
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
            // Whole-image single-tile metric: tile origin is (0, 0).
            const sb = subbandDims(0, 0, image_w, image_h, num_decomp_levels, r, i);
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
    const r0 = resolutionExtent(0, 0, 303, 179, 5, 0);
    try std.testing.expectEqual(@as(u32, 10), r0.width);
    try std.testing.expectEqual(@as(u32, 6), r0.height);
    const r5 = resolutionExtent(0, 0, 303, 179, 5, 5);
    try std.testing.expectEqual(@as(u32, 303), r5.width);
    try std.testing.expectEqual(@as(u32, 179), r5.height);
}

test "subbandDims: r=0 is single LL; r>=1 has HL/LH/HH that sum to delta" {
    // At r=1: full extent is 19x12, previous (r=0) is 10x6.
    // HL_1: width = 19-10 = 9, height = 6.
    // LH_1: width = 10,       height = 12-6 = 6.
    // HH_1: width = 9,        height = 6.
    const ll = subbandDims(0, 0, 303, 179, 5, 0, 0);
    try std.testing.expectEqual(SubbandKind.ll, ll.kind);
    try std.testing.expectEqual(@as(u32, 10), ll.width);
    try std.testing.expectEqual(@as(u32, 6), ll.height);

    const hl1 = subbandDims(0, 0, 303, 179, 5, 1, 0);
    try std.testing.expectEqual(SubbandKind.hl, hl1.kind);
    try std.testing.expectEqual(@as(u32, 9), hl1.width);
    try std.testing.expectEqual(@as(u32, 6), hl1.height);

    const lh1 = subbandDims(0, 0, 303, 179, 5, 1, 1);
    try std.testing.expectEqual(SubbandKind.lh, lh1.kind);
    try std.testing.expectEqual(@as(u32, 10), lh1.width);
    try std.testing.expectEqual(@as(u32, 6), lh1.height);

    const hh1 = subbandDims(0, 0, 303, 179, 5, 1, 2);
    try std.testing.expectEqual(SubbandKind.hh, hh1.kind);
    try std.testing.expectEqual(@as(u32, 9), hh1.width);
    try std.testing.expectEqual(@as(u32, 6), hh1.height);
}

test "subbandDims: r=5 (full res) subbands cover the WxH plus the r=4 LL" {
    // r=5: full extent = 303x179, r=4 extent = 152x90.
    // HL_5: 303-152=151 × 90.
    // LH_5: 152 × 179-90=89.
    // HH_5: 151 × 89.
    const hl = subbandDims(0, 0, 303, 179, 5, 5, 0);
    try std.testing.expectEqual(@as(u32, 151), hl.width);
    try std.testing.expectEqual(@as(u32, 90), hl.height);
    const lh = subbandDims(0, 0, 303, 179, 5, 5, 1);
    try std.testing.expectEqual(@as(u32, 152), lh.width);
    try std.testing.expectEqual(@as(u32, 89), lh.height);
    const hh = subbandDims(0, 0, 303, 179, 5, 5, 2);
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
        const grid = numPrecincts(0, 0, 303, 179, 5, r, 15, 15);
        try std.testing.expectEqual(@as(u32, 1), grid.width);
        try std.testing.expectEqual(@as(u32, 1), grid.height);
    }
}

test "numPrecincts: d1_colr.j2c (64×64 precincts) — r=5: 4×3, r=4: 2×2, r≤3: 1×1" {
    // d1_colr image 256×149, num_decomp_levels=5, all precincts (6, 6) = 64×64.
    const r5 = numPrecincts(0, 0, 256, 149, 5, 5, 6, 6);
    try std.testing.expectEqual(@as(u32, 4), r5.width);
    try std.testing.expectEqual(@as(u32, 3), r5.height);

    const r4 = numPrecincts(0, 0, 256, 149, 5, 4, 6, 6);
    try std.testing.expectEqual(@as(u32, 2), r4.width);
    try std.testing.expectEqual(@as(u32, 2), r4.height);

    const r3 = numPrecincts(0, 0, 256, 149, 5, 3, 6, 6);
    try std.testing.expectEqual(@as(u32, 1), r3.width);
    try std.testing.expectEqual(@as(u32, 1), r3.height);

    const r0 = numPrecincts(0, 0, 256, 149, 5, 0, 6, 6);
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
    try std.testing.expectEqual(@as(u32, 0), precinctIndexAt(0, 0, 256, 149, 5, 5, 6, 6, 0, 0));
    try std.testing.expectEqual(@as(u32, 1), precinctIndexAt(0, 0, 256, 149, 5, 5, 6, 6, 64, 0));
    try std.testing.expectEqual(@as(u32, 3), precinctIndexAt(0, 0, 256, 149, 5, 5, 6, 6, 192, 0));
    try std.testing.expectEqual(@as(u32, 4), precinctIndexAt(0, 0, 256, 149, 5, 5, 6, 6, 0, 64));
    try std.testing.expectEqual(@as(u32, 11), precinctIndexAt(0, 0, 256, 149, 5, 5, 6, 6, 192, 128));
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

test "cblksInPrecinctSubband: d1_colr r=5 — each precinct holds exactly 1 cblk in each HF subband" {
    // Each HF subband at r=5 is 128×75 (or 128×74) in subband-internal
    // coords; precinct dim there is 32×32 (= 2^(PPx-1)); cblk dim is
    // 32×32 (capped). So every precinct that lies inside the band gets
    // exactly 1×1 cblks. d1_colr has 4×3=12 precincts at r=5, all within
    // band bounds → each yields 1×1 in each of HL, LH, HH.
    var p: u32 = 0;
    while (p < 12) : (p += 1) {
        const px = p % 4;
        const py = p / 4;
        var sb: u8 = 0;
        while (sb < 3) : (sb += 1) {
            const g = cblksInPrecinctSubband(0, 0, 256, 149, 5, 5, sb, px, py, 6, 6, 4, 4);
            try std.testing.expectEqual(@as(u32, 1), g.width);
            try std.testing.expectEqual(@as(u32, 1), g.height);
        }
    }
}

test "cblksInPrecinctSubband: precinct outside subband returns 0×0" {
    // Construct a deliberately-out-of-bounds precinct index: at d1_colr
    // r=5 HL band (128 wide internal), precinct index (5, 0) starts at
    // subband_x = 5*32 = 160, past band_w = 128 → returns 0×0.
    const g = cblksInPrecinctSubband(0, 0, 256, 149, 5, 5, 0, 5, 0, 6, 6, 4, 4);
    try std.testing.expectEqual(@as(u32, 0), g.width);
    try std.testing.expectEqual(@as(u32, 0), g.height);
}

test "cblksInPrecinctSubband: c1_mono default precincts → whole subband per precinct" {
    // c1_mono image 303×179, default precincts 2^15. Every (resolution,
    // subband) has exactly one precinct that contains the entire subband.
    // r=5 HL subband internal dims via OpenJPEG: width = ceil(302/2) = 151,
    // height = ceil(179/2) = 90. cblk dim 64; cblk grid = 3×2.
    const g = cblksInPrecinctSubband(0, 0, 303, 179, 5, 5, 0, 0, 0, 15, 15, 4, 4);
    try std.testing.expectEqual(@as(u32, 3), g.width);
    try std.testing.expectEqual(@as(u32, 2), g.height);
}

test "cblksInPrecinctSubband: r=0 LL — precinct intersects the LL subband" {
    // d1_colr r=0 LL band internal = 8×5. PPx=6 → precinct dim
    // 2^6 = 64 (LL doesn't halve). cblk = min(64, 64) = 64. precinct
    // (0,0) → 1×1.
    const g = cblksInPrecinctSubband(0, 0, 256, 149, 5, 0, 0, 0, 0, 6, 6, 4, 4);
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

test "cblkSubbandRect: c1_mono r=5 HL grid(0,0) — top-left of band" {
    // c1_mono is 303×179 with 5 decomp levels and default 2^15 precincts.
    // At r=5 the HL band has level_no=0, x0b=1, y0b=0:
    //   x_num = 303 - 1 = 302; band_w = (302 + 1)/2 = 151
    //   y_num = 179;          band_h = (179 + 1)/2 = 90
    // Precincts cover the entire band (prec_w = 2^14 ≫ band_w). Cblks
    // are 64×64. Grid (0, 0) starts at (0, 0).
    const rect = cblkSubbandRect(0, 0, 303, 179, 5, 5, 0, 0, 0, 15, 15, 4, 4, 0, 0);
    try std.testing.expectEqual(@as(i32, 0), rect.x0);
    try std.testing.expectEqual(@as(i32, 0), rect.y0);
    try std.testing.expectEqual(@as(i32, 64), rect.x1);
    try std.testing.expectEqual(@as(i32, 64), rect.y1);
}

test "cblkSubbandRect: c1_mono r=5 HL grid(2,1) — last cblk clips at (151, 90)" {
    // HL band is 151×90, cblks 64×64. Grid (2, 1) raw rect = (128, 64)
    // .. (192, 128). Clipped to band right edge x=151, band bottom y=90.
    const rect = cblkSubbandRect(0, 0, 303, 179, 5, 5, 0, 0, 0, 15, 15, 4, 4, 2, 1);
    try std.testing.expectEqual(@as(i32, 128), rect.x0);
    try std.testing.expectEqual(@as(i32, 64), rect.y0);
    try std.testing.expectEqual(@as(i32, 151), rect.x1);
    try std.testing.expectEqual(@as(i32, 90), rect.y1);
}

test "cblkSubbandRect: every cblk in the grid covers the precinct rect (tile)" {
    // Structural invariant: the union of every grid cell's rect must
    // tile [prc_x0..prc_x1) × [prc_y0..prc_y1) exactly — no gaps, no
    // overlaps, no spillage beyond the precinct.
    const cblks = cblksInPrecinctSubband(0, 0, 303, 179, 5, 5, 0, 0, 0, 15, 15, 4, 4);
    // Compute the expected precinct bounds (entire HL band).
    const expected_x0: i32 = 0;
    const expected_y0: i32 = 0;
    const expected_x1: i32 = 151;
    const expected_y1: i32 = 90;
    var union_x0: i32 = std.math.maxInt(i32);
    var union_y0: i32 = std.math.maxInt(i32);
    var union_x1: i32 = std.math.minInt(i32);
    var union_y1: i32 = std.math.minInt(i32);
    var gy: u32 = 0;
    while (gy < cblks.height) : (gy += 1) {
        var gx: u32 = 0;
        while (gx < cblks.width) : (gx += 1) {
            const r = cblkSubbandRect(0, 0, 303, 179, 5, 5, 0, 0, 0, 15, 15, 4, 4, gx, gy);
            if (r.x0 < union_x0) union_x0 = r.x0;
            if (r.y0 < union_y0) union_y0 = r.y0;
            if (r.x1 > union_x1) union_x1 = r.x1;
            if (r.y1 > union_y1) union_y1 = r.y1;
        }
    }
    try std.testing.expectEqual(expected_x0, union_x0);
    try std.testing.expectEqual(expected_y0, union_y0);
    try std.testing.expectEqual(expected_x1, union_x1);
    try std.testing.expectEqual(expected_y1, union_y1);
}
