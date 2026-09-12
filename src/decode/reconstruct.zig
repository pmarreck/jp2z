//! Cleanroom image reconstruction: tier-1 coefficients → image samples.
//!
//! Pipeline (T.800, reversible path): for each component, decode every
//! code-block (tier-1 EBCOT), scale by /2 (the t1 half-bit removal),
//! place into the component's tile buffer by subband quadrant, run the
//! inverse 5/3 DWT, then — after the inverse MCT for multi-component
//! images (M6) — apply the DC level shift + clamp. This mirrors
//! OpenJPEG's tcd decode order (T1 → DWT → MCT → DC-shift) but is a
//! fresh integer implementation validated byte-perfect against it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const subbands = @import("subbands.zig");
const dwt = @import("dwt.zig");
const cblk_dispatch = @import("cblk_dispatch.zig");
const cblk_plan = @import("cblk_plan.zig");
const codestream = @import("codestream.zig");

pub const CblkDecodePlanList = cblk_plan.CblkDecodePlanList;

/// A decoded image: per-component sample planes (post level shift),
/// each `width × height` row-major i32 in [0, 2^prec) for unsigned.
pub const Image = struct {
    width: u32,
    height: u32,
    num_components: u16,
    /// Per-component plane; each is `width*height` long, row-major.
    planes: [][]i32,
    precs: []u8,

    pub fn deinit(self: *Image, allocator: Allocator) void {
        for (self.planes) |p| allocator.free(p);
        allocator.free(self.planes);
        allocator.free(self.precs);
        self.* = undefined;
    }
};


/// Ceiling division for component-grid geometry (T.800 B.2): a component
/// coordinate is ceil(reference_coordinate / sub_sampling_factor).
inline fn ceilDiv(a: u32, b: u32) u32 {
    return (a + b - 1) / b;
}

/// Order plans by (tile, component) so they can be bucketed by a single
/// forward sweep instead of an O(tiles·components·plans) re-scan.
fn planTileCompLess(_: void, a: cblk_plan.CblkDecodePlan, b: cblk_plan.CblkDecodePlan) bool {
    if (a.tile != b.tile) return a.tile < b.tile;
    return a.component < b.component;
}

/// True if `plan` sorts strictly before (tile, component).
fn planBeforeTileComp(plan: cblk_plan.CblkDecodePlan, tile: u32, component: u16) bool {
    if (plan.tile != tile) return plan.tile < tile;
    return plan.component < component;
}

/// Bucket lookup over plans sorted by planTileCompLess: return the contiguous
/// run matching (tile, component), advancing `cursor` past it. Visiting every
/// (tile, component) in ascending order touches each plan exactly once, so the
/// whole reconstruction sweep is O(plans) — not O(tiles·components·plans).
/// complexity: O(plans) amortized across a full ascending sweep.
fn planRangeFor(
    plans: []const cblk_plan.CblkDecodePlan,
    cursor: *usize,
    tile: u32,
    component: u16,
) []const cblk_plan.CblkDecodePlan {
    // Defensive: skip any plan ordered before (tile, component) (none, given an
    // ascending sweep over valid tags — guards against a stuck cursor).
    while (cursor.* < plans.len and planBeforeTileComp(plans[cursor.*], tile, component)) cursor.* += 1;
    const start = cursor.*;
    while (cursor.* < plans.len and plans[cursor.*].tile == tile and plans[cursor.*].component == component) cursor.* += 1;
    return plans[start..cursor.*];
}
/// Assemble + inverse-DWT one component's tile buffer from its plans.
/// Returns an `image_w × image_h` i32 buffer of spatial samples
/// (pre level-shift, pre-MCT). Caller owns it.
pub fn reconstructComponentTile(
    allocator: Allocator,
    // Pre-filtered to a single (tile, component) — the caller buckets plans by
    // (tile, component) once so each plan is visited O(1) times (was a
    // quadratic full re-scan per tile×component).
    plans: []const cblk_plan.CblkDecodePlan,
    // Tile-component ORIGIN in tile-component coords (0,0 for a single tile at
    // the image origin; non-zero for interior tiles). Drives the origin-aware
    // subband split + inverse-DWT parity.
    tile_x0: u32,
    tile_y0: u32,
    image_w: u32,
    image_h: u32,
    num_decomp: u8,
) Allocator.Error![]i32 {
    const tile_w = image_w;
    const buf = try allocator.alloc(i32, @as(usize, image_w) * @as(usize, image_h));
    @memset(buf, 0);
    errdefer allocator.free(buf);

    for (plans) |plan| {
        if (plan.numbps == 0 or plan.total_passes == 0 or plan.data.len == 0) continue;

        var cblk = try cblk_dispatch.decodePlan(allocator, plan);
        defer cblk.deinit(allocator);


        // Subband quadrant base inside the tile buffer (Mallat layout). The
        // low-pass width/height (prev resolution) is the quadrant offset, and
        // must be origin-aware so it matches idwt53's sn/dn split for this tile.
        var base_x: u32 = @intCast(plan.sb_x0);
        var base_y: u32 = @intCast(plan.sb_y0);
        if (plan.resolution >= 1) {
            const prev = subbands.resolutionExtent(tile_x0, tile_y0, image_w, image_h, num_decomp, plan.resolution - 1);
            if (plan.band & 1 != 0) base_x += prev.width; // HL / HH → right quadrant
            if (plan.band & 2 != 0) base_y += prev.height; // LH / HH → bottom quadrant
        }

        const cw = plan.width();
        const ch = plan.height();
        var j: u32 = 0;
        while (j < ch) : (j += 1) {
            var i: u32 = 0;
            while (i < cw) : (i += 1) {
                const coeff = roiDescale(cblk_dispatch.coeffToOpenJpegI32(cblk.coeffs[j * cw + i]), plan.roishift);
                // Reversible band→tile pre-scale: truncating /2 (NOT >>1).
                buf[(base_y + j) * tile_w + (base_x + i)] = @divTrunc(coeff, 2);
            }
        }
    }

    try dwt.idwt53(allocator, buf, tile_w, tile_x0, tile_y0, image_w, image_h, num_decomp);
    return buf;
}


/// DC level shift + clamp, in place. Unsigned: `+2^(prec-1)`, clamp to
/// `[0, 2^prec-1]`. Signed: clamp to `[-2^(prec-1), 2^(prec-1)-1]`.
pub fn levelShift(buf: []i32, prec: u8, is_signed: bool) void {
    if (is_signed) {
        const lo: i32 = -(@as(i32, 1) << @intCast(prec - 1));
        const hi: i32 = (@as(i32, 1) << @intCast(prec - 1)) - 1;
        for (buf) |*v| v.* = std.math.clamp(v.*, lo, hi);
    } else {
        const dc: i32 = @as(i32, 1) << @intCast(prec - 1);
        const hi: i32 = (@as(i32, 1) << @intCast(prec)) - 1;
        for (buf) |*v| v.* = std.math.clamp(v.* +% dc, 0, hi);
    }
}

/// Undo an RGN ROI up-shift (T.800 H.2, openjpeg t1 `opj_t1_clbl_decode_processor`):
/// a magnitude at or above 2^shift belongs to the ROI and is scaled back
/// down by `shift`; smaller magnitudes are background and stay. Operates on
/// the openjpeg sign-magnitude representation (half-bit included).
fn roiDescale(v: i32, shift: u8) i32 {
    if (shift == 0) return v;
    if (shift >= 31) return 0;
    const thresh: i32 = @as(i32, 1) << @intCast(shift);
    const mag: i32 = if (v < 0) -v else v;
    if (mag < thresh) return v;
    const scaled = mag >> @intCast(shift);
    return if (v < 0) -scaled else scaled;
}

test "roiDescale: background below 2^shift unchanged; ROI magnitudes shifted down; sign kept" {
    try std.testing.expectEqual(@as(i32, 5), roiDescale(5, 0));
    try std.testing.expectEqual(@as(i32, 100), roiDescale(100, 7)); // < 128: background
    try std.testing.expectEqual(@as(i32, 2), roiDescale(256 + 3, 7)); // 259 >> 7 = 2
    try std.testing.expectEqual(@as(i32, -2), roiDescale(-(256 + 3), 7));
    try std.testing.expectEqual(@as(i32, 0), roiDescale(123456, 31));
}

/// Full cleanroom decode of a (reversible, single-tile) JP2/J2K
/// codestream to per-component sample planes. Inverse MCT is applied
/// for the 3-component reversible (RCT) case; otherwise components are
/// independent. (Irreversible 9/7 is M5; this is the 5/3 path.)
pub fn decodeCleanroom(allocator: Allocator, data: []const u8) !Image {
    var report = try codestream.validate(allocator, data);
    defer report.deinit(allocator);
    return decodeFromReport(allocator, data, &report);
}

/// decodeCleanroom over a report the caller already holds (the public
/// decode route validates once and keeps the report for colr / palette).
pub fn decodeFromReport(allocator: Allocator, data: []const u8, report: *const codestream.ValidationReport) !Image {
    const params = report.coding_params orelse return error.NoCodingParams;
    const image_w = report.width orelse return error.NoDimensions;
    const image_h = report.height orelse return error.NoDimensions;
    // Output dims. For the multi-tile/sub-sampled 5/3 path these become the
    // component-grid dims (set in that branch); otherwise the ref-grid dims.
    var out_w: u32 = image_w;
    var out_h: u32 = image_h;
    const ncomp = params.num_components;
    // The per-tile scratch buffers below are fixed 16-slot arrays. The
    // validator accepts any Csiz (reading components past the 16th through
    // slot 15); the decoder refuses rather than index past the arrays.
    if (ncomp > 16) return error.TooManyComponents;

    var list = try codestream.extractCblkPlans(allocator, data);
    defer list.deinit(allocator);
    // A tile-part COD that changes decomposition/wavelet/MCT is validated
    // with the tile's params but would be reconstructed with the main
    // header's below: refuse rather than mis-render.
    if (list.tile_override_unsupported) return error.UnsupportedTileCodingOverride;
    if (list.ht_unsupported) return error.UnsupportedHtCodeBlocks;
    // COC may give components different wavelets (p0_06: 9/7 on three
    // components, 5/3 on the fourth). The integer path below is exact for
    // an all-5/3 image; anything else goes through the Q16 path, where each
    // component picks its own transform and 5/3 output is widened to Q16.
    var all_reversible = true;
    {
        var k: u16 = 0;
        while (k < ncomp) : (k += 1) if (params.codingFor(k).wavelet != .reversible_5x3) {
            all_reversible = false;
        };
    }
    // Bucket plans by (tile, component) once. The reconstruction sweep then
    // visits each plan O(1) times via a forward cursor (planRangeFor), instead
    // of re-scanning the whole flat list per tile×component — which was
    // quadratic in tile count (the fleet Big-O gate). complexity: O(plans).
    std.mem.sort(cblk_plan.CblkDecodePlan, list.plans, {}, planTileCompLess);

    const planes = try allocator.alloc([]i32, ncomp);
    errdefer allocator.free(planes);
    const precs = try allocator.alloc(u8, ncomp);
    errdefer allocator.free(precs);

    var done: u16 = 0;
    errdefer for (planes[0..done]) |p| allocator.free(p);
    var c: u16 = 0;
    while (c < ncomp) : (c += 1) precs[c] = params.comp_prec[@min(c, 15)];

    // C3 (T.800 Annex G): the inverse MCT mixes the first 3 components
    // sample-for-sample, so MCT REQUIRES uniform sub-sampling across them.
    // Non-uniform comp_dx/dy makes the per-component tile buffers different
    // lengths → inverseRct/inverseIct would read+write past the shorter
    // planes (silent heap corruption in ReleaseFast). Reject, don't corrupt.
    if (params.mct and ncomp >= 3) {
        const dx0 = params.comp_dx[0];
        const dy0 = params.comp_dy[0];
        var k: u16 = 1;
        while (k < 3) : (k += 1) {
            if (params.comp_dx[@min(k, 15)] != dx0 or params.comp_dy[@min(k, 15)] != dy0)
                return error.MctNonUniformSubsampling;
        }
    }

    if (all_reversible) {
        // ── Lossless 5/3 path (integer), multi-tile + sub-sampling aware ──
        // Reconstruct each tile at COMPONENT resolution (sub-sampled grid,
        // T.800 B.2/B.3), apply inverse MCT + DC level shift PER TILE (tiles
        // are independent), then composite into the full per-component
        // planes. For a single, non-sub-sampled tile this reduces to the
        // whole image at (0,0).
        const xsiz = params.image_x0 + image_w;
        const ysiz = params.image_y0 + image_h;

        // Per-component sample-plane dimensions on the sub-sampled grid.
        var comp_w: [16]u32 = @splat(0);
        var comp_h: [16]u32 = @splat(0);
        c = 0;
        while (c < ncomp) : (c += 1) {
            const ci = @min(c, 15);
            const dx: u32 = params.comp_dx[ci];
            const dy: u32 = params.comp_dy[ci];
            comp_w[ci] = ceilDiv(xsiz, dx) - ceilDiv(params.image_x0, dx);
            comp_h[ci] = ceilDiv(ysiz, dy) - ceilDiv(params.image_y0, dy);
        }

        // Allocate + zero every component plane up front.
        c = 0;
        while (c < ncomp) : (c += 1) {
            const ci = @min(c, 15);
            const plane = try allocator.alloc(i32, @as(usize, comp_w[ci]) * @as(usize, comp_h[ci]));
            @memset(plane, 0);
            planes[c] = plane;
            done += 1;
        }

        const nt = params.numTilesXY(xsiz, ysiz);
        const num_tiles = nt.x * nt.y;
        // Forward cursor over the (tile, component)-sorted plans. The tile×comp
        // loops below visit keys in ascending order, so this touches each plan once.
        var plan_cursor: usize = 0;
        var t: u32 = 0;
        while (t < num_tiles) : (t += 1) {
            const tr = params.tileRect(xsiz, ysiz, t);

            // Per-tile, per-component spatial buffers (freed at iter end).
            var tbufs: [16][]i32 = undefined;
            const TileDim = struct { w: u32, h: u32, ox: u32, oy: u32 };
            var tdims: [16]TileDim = undefined;
            var tb_done: u16 = 0;
            defer {
                var k: u16 = 0;
                while (k < tb_done) : (k += 1) allocator.free(tbufs[k]);
            }

            c = 0;
            while (c < ncomp) : (c += 1) {
                const ci = @min(c, 15);
                const dx: u32 = params.comp_dx[ci];
                const dy: u32 = params.comp_dy[ci];
                const tcx0 = ceilDiv(tr.x0, dx);
                const tcy0 = ceilDiv(tr.y0, dy);
                const tcw = ceilDiv(tr.x1, dx) - tcx0;
                const tch = ceilDiv(tr.y1, dy) - tcy0;
                tdims[c] = .{
                    .w = tcw,
                    .h = tch,
                    .ox = tcx0 - ceilDiv(params.image_x0, dx),
                    .oy = tcy0 - ceilDiv(params.image_y0, dy),
                };
                const tc_plans = planRangeFor(list.plans, &plan_cursor, t, c);
                tbufs[c] = try reconstructComponentTile(allocator, tc_plans, tcx0, tcy0, tcw, tch, params.codingFor(c).num_decomp_levels);
                tb_done += 1;
            }

            // Inverse MCT then DC level shift, per tile, before compositing.
            if (params.mct and ncomp >= 3) inverseRct(tbufs[0], tbufs[1], tbufs[2]);
            c = 0;
            while (c < ncomp) : (c += 1) {
                const ci = @min(c, 15);
                const is_signed = (params.comp_signed >> @intCast(ci)) & 1 != 0;
                levelShift(tbufs[c], precs[c], is_signed);
                const d = tdims[c];
                const stride = comp_w[ci];
                var ty: u32 = 0;
                while (ty < d.h) : (ty += 1) {
                    const src = tbufs[c][ty * d.w ..][0..d.w];
                    const dst_off = (d.oy + ty) * stride + d.ox;
                    @memcpy(planes[c][dst_off..][0..d.w], src);
                }
            }
        }

        // RCT requires uniform sub-sampling across the colour components, so
        // all component planes share dimensions; report component-0's.
        out_w = comp_w[0];
        out_h = comp_h[0];
    } else {
        // ── Lossy 9/7 path (Q16 fixed-point), multi-tile aware ──
        // Same per-tile reconstruct → (inverse ICT) → round+DC+clamp →
        // composite shape as the 5/3 branch above; tiles are independent
        // (T.800). For a single tile at the origin this reduces to the
        // whole image at (0,0) — the prior single-tile behavior exactly.
        const xsiz = params.image_x0 + image_w;
        const ysiz = params.image_y0 + image_h;

        var comp_w: [16]u32 = @splat(0);
        var comp_h: [16]u32 = @splat(0);
        c = 0;
        while (c < ncomp) : (c += 1) {
            const ci = @min(c, 15);
            const dx: u32 = params.comp_dx[ci];
            const dy: u32 = params.comp_dy[ci];
            comp_w[ci] = ceilDiv(xsiz, dx) - ceilDiv(params.image_x0, dx);
            comp_h[ci] = ceilDiv(ysiz, dy) - ceilDiv(params.image_y0, dy);
        }
        c = 0;
        while (c < ncomp) : (c += 1) {
            const ci = @min(c, 15);
            const plane = try allocator.alloc(i32, @as(usize, comp_w[ci]) * @as(usize, comp_h[ci]));
            @memset(plane, 0);
            planes[c] = plane;
            done += 1;
        }

        const nt = params.numTilesXY(xsiz, ysiz);
        const num_tiles = nt.x * nt.y;
        var plan_cursor: usize = 0;
        var t: u32 = 0;
        while (t < num_tiles) : (t += 1) {
            const tr = params.tileRect(xsiz, ysiz, t);

            var tqbufs: [16][]i64 = undefined;
            const TileDim = struct { w: u32, h: u32, ox: u32, oy: u32 };
            var tdims: [16]TileDim = undefined;
            var tb_done: u16 = 0;
            defer {
                var k: u16 = 0;
                while (k < tb_done) : (k += 1) allocator.free(tqbufs[k]);
            }

            c = 0;
            while (c < ncomp) : (c += 1) {
                const ci = @min(c, 15);
                const dx: u32 = params.comp_dx[ci];
                const dy: u32 = params.comp_dy[ci];
                const tcx0 = ceilDiv(tr.x0, dx);
                const tcy0 = ceilDiv(tr.y0, dy);
                const tcw = ceilDiv(tr.x1, dx) - tcx0;
                const tch = ceilDiv(tr.y1, dy) - tcy0;
                tdims[c] = .{
                    .w = tcw,
                    .h = tch,
                    .ox = tcx0 - ceilDiv(params.image_x0, dx),
                    .oy = tcy0 - ceilDiv(params.image_y0, dy),
                };
                const tc_plans = planRangeFor(list.plans, &plan_cursor, t, c);
                const cc = params.codingFor(c);
                if (cc.wavelet == .reversible_5x3) {
                    // A 5/3 component inside a mixed image: exact integer
                    // reconstruction, then widened to Q16 so the shared
                    // round + DC + clamp stage below reproduces it exactly.
                    const ibuf = try reconstructComponentTile(allocator, tc_plans, tcx0, tcy0, tcw, tch, cc.num_decomp_levels);
                    defer allocator.free(ibuf);
                    const q = try allocator.alloc(i64, ibuf.len);
                    for (ibuf, q) |v, *o| o.* = @as(i64, v) << 16;
                    tqbufs[c] = q;
                } else {
                    tqbufs[c] = try reconstructComponentTile97(allocator, tc_plans, tcx0, tcy0, tcw, tch, cc.num_decomp_levels, precs[c]);
                }
                tb_done += 1;
            }

            // G.2: the RCT pairs with 5/3, the ICT with 9/7; a mixed image
            // follows component 0 (openjpeg: tccps[0].qmfbid).
            if (params.mct and ncomp >= 3) {
                if (params.codingFor(0).wavelet == .reversible_5x3) inverseRctQ16(tqbufs[0], tqbufs[1], tqbufs[2]) else inverseIct(tqbufs[0], tqbufs[1], tqbufs[2]);
            }

            // round (ties-to-even) + DC level shift + clamp, per tile,
            // compositing straight into the component planes.
            c = 0;
            while (c < ncomp) : (c += 1) {
                const ci = @min(c, 15);
                const prec = precs[c];
                const is_signed = (params.comp_signed >> @intCast(ci)) & 1 != 0;
                const dc: i32 = if (is_signed) 0 else (@as(i32, 1) << @intCast(prec - 1));
                const lo: i32 = if (is_signed) -(@as(i32, 1) << @intCast(prec - 1)) else 0;
                const hi: i32 = if (is_signed) (@as(i32, 1) << @intCast(prec - 1)) - 1 else (@as(i32, 1) << @intCast(prec)) - 1;
                const d = tdims[c];
                const stride = comp_w[ci];
                var ty: u32 = 0;
                while (ty < d.h) : (ty += 1) {
                    var tx: u32 = 0;
                    while (tx < d.w) : (tx += 1) {
                        const v = tqbufs[c][ty * d.w + tx];
                        // usize index + bounds check: fuzzed tile geometry that
                        // survived validation (issue1438) must error, not panic.
                        const idx: usize = (@as(usize, d.oy) + ty) * stride + (@as(usize, d.ox) + tx);
                        if (idx >= planes[c].len) return error.CorruptTileGeometry;
                        planes[c][idx] = std.math.clamp(dwt.fpRound(v) + dc, lo, hi);
                    }
                }
            }
        }
        out_w = comp_w[0];
        out_h = comp_h[0];
    }

    // JP2 cdef (I.5.3.6): deliver planes in COLOUR order. Only a genuine
    // permutation of the components is applied — a partial or repeated map
    // was already reported by the walker.
    if (report.cdef) |cm| {
        if (cm.n == ncomp and ncomp <= 16) {
            var seen: [16]bool = @splat(false);
            var bijective = true;
            var k: u16 = 0;
            while (k < ncomp) : (k += 1) {
                const src = cm.order[k];
                if (src >= ncomp or seen[src]) bijective = false else seen[src] = true;
            }
            if (bijective) {
                var new_planes: [16][]i32 = undefined;
                var new_precs: [16]u8 = undefined;
                k = 0;
                while (k < ncomp) : (k += 1) {
                    new_planes[k] = planes[cm.order[k]];
                    new_precs[k] = precs[cm.order[k]];
                }
                k = 0;
                while (k < ncomp) : (k += 1) {
                    planes[k] = new_planes[k];
                    precs[k] = new_precs[k];
                }
            }
        }
    }

    return .{
        .width = out_w,
        .height = out_h,
        .num_components = ncomp,
        .planes = planes,
        .precs = precs,
    };
}

/// Inverse reversible colour transform (RCT, T.800 G.2). Operates in
/// place on the three component planes (Y, Cb, Cr) → (R, G, B).
fn inverseRct(c0: []i32, c1: []i32, c2: []i32) void {
    const n = c0.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const y = c0[i];
        const cb = c1[i];
        const cr = c2[i];
        const g = y -% ((cb +% cr) >> 2);
        const r = cr +% g;
        const b = cb +% g;
        c0[i] = r;
        c1[i] = g;
        c2[i] = b;
    }
}

/// Per-band Q16 dequant scale for irreversible: `0.5 * stepsize` where
/// stepsize = (1 + mant/2048)*2^(prec - expn) (subband gain folded out,
/// matching the openjpeg decoder which compensates via two_invK in the
/// DWT). Returned as round(0.5*stepsize * 2^16) so `t1 * scale` is Q16.
fn dequantScaleQ(prec: u8, expn: u8, mant: u16) i64 {
    const numerator: i64 = 2048 + @as(i64, mant);
    // 0.5*stepsize*2^16 = (2048+mant) * 2^(prec - expn - 12 + 16).
    const shift: i32 = @as(i32, prec) - @as(i32, expn) + 4;
    if (shift >= 0) return numerator << @intCast(shift);
    const rs: u6 = @intCast(-shift);
    return (numerator + (@as(i64, 1) << @intCast(rs - 1))) >> rs;
}

/// Assemble + inverse 9/7 DWT one (tile, component) into a Q16 (i64)
/// tile buffer. Mirrors reconstructComponentTile's origin-aware subband
/// split and DWT parity exactly (the 5/3 multi-tile shape proven by
/// b1/b3/e1); dequant uses each plan's TILE-stamped (expn, mant), since
/// a tile-part-header QCD overrides the main header per tile (p1_04:
/// 63 of 64 tiles carry one).
pub fn reconstructComponentTile97(
    allocator: Allocator,
    // Pre-filtered to a single (tile, component) by the caller's
    // planRangeFor bucket sweep.
    plans: []const cblk_plan.CblkDecodePlan,
    tile_x0: u32,
    tile_y0: u32,
    image_w: u32,
    image_h: u32,
    num_decomp: u8,
    prec: u8,
) Allocator.Error![]i64 {
    const tile_w = image_w;
    const buf = try allocator.alloc(i64, @as(usize, image_w) * @as(usize, image_h));
    @memset(buf, 0);
    errdefer allocator.free(buf);

    for (plans) |plan| {
        if (plan.numbps == 0 or plan.total_passes == 0 or plan.data.len == 0) continue;
        var cblk = try cblk_dispatch.decodePlan(allocator, plan);
        defer cblk.deinit(allocator);

        const scale_q = dequantScaleQ(prec, plan.qcd_expn, plan.qcd_mant);

        var base_x: u32 = @intCast(plan.sb_x0);
        var base_y: u32 = @intCast(plan.sb_y0);
        if (plan.resolution >= 1) {
            const prev = subbands.resolutionExtent(tile_x0, tile_y0, image_w, image_h, num_decomp, plan.resolution - 1);
            if (plan.band & 1 != 0) base_x += prev.width; // HL / HH → right quadrant
            if (plan.band & 2 != 0) base_y += prev.height; // LH / HH → bottom quadrant
        }
        const cw = plan.width();
        const ch = plan.height();
        var j: u32 = 0;
        while (j < ch) : (j += 1) {
            var i: u32 = 0;
            while (i < cw) : (i += 1) {
                const t1 = roiDescale(cblk_dispatch.coeffToOpenJpegI32(cblk.coeffs[j * cw + i]), plan.roishift);
                buf[(base_y + j) * tile_w + (base_x + i)] = @as(i64, t1) * scale_q; // Q16
            }
        }
    }

    try dwt.idwt97(allocator, buf, tile_w, tile_x0, tile_y0, image_w, image_h, num_decomp);
    return buf;
}

// Inverse ICT coefficients (T.800 G.2) in Q16 fixed-point. Precomputed
// integer literals — no comptime float in source (fleet no-float policy).
// Each = round(coeff * 65536); pinned by the p0_04 (9/7+ICT) oracle test.
const ICT_CR_R: i64 = 91881; // round(1.40200 * 65536)
const ICT_CB_G: i64 = 22553; // round(0.34413 * 65536)
const ICT_CR_G: i64 = 46802; // round(0.71414 * 65536)
const ICT_CB_B: i64 = 116130; // round(1.77200 * 65536)

/// Inverse irreversible colour transform (ICT, T.800 G.3), Q16 in place:
/// (Y,Cb,Cr) → (R,G,B). R=Y+1.402·Cr; G=Y−0.34413·Cb−0.71414·Cr; B=Y+1.772·Cb.
/// Inverse RCT (T.800 G.2.2) over Q16 buffers: the integer lifting is
/// applied to the sample values (Q16 >> 16, floor for negatives) and the
/// result is re-widened, so a 5/3-coded image on the Q16 path reproduces
/// the integer path bit-for-bit. Only reached when component 0 is 5/3 in
/// an image whose other components are 9/7 (or vice versa, via COC).
fn inverseRctQ16(c0: []i64, c1: []i64, c2: []i64) void {
    const n = c0.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const y = c0[i] >> 16;
        const u = c1[i] >> 16;
        const v = c2[i] >> 16;
        const g = y - ((u + v) >> 2);
        const r = v + g;
        const b = u + g;
        c0[i] = r << 16;
        c1[i] = g << 16;
        c2[i] = b << 16;
    }
}

fn inverseIct(c0: []i64, c1: []i64, c2: []i64) void {
    const n = c0.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const y = c0[i];
        const cb = c1[i];
        const cr = c2[i];
        c0[i] = y + dwt.fpMul(cr, ICT_CR_R);
        c1[i] = y - dwt.fpMul(cb, ICT_CB_G) - dwt.fpMul(cr, ICT_CR_G);
        c2[i] = y + dwt.fpMul(cb, ICT_CB_B);
    }
}

test "inverseIct: known YCbCr->RGB vector (Q16) rounds to expected RGB" {
    // Y=100, Cb=10, Cr=20 (Q16). Expected (T.800 G.3):
    //   R = 100 + 1.402*20      = 128.04  -> 128
    //   G = 100 - 0.34413*10 - 0.71414*20 = 82.276 -> 82
    //   B = 100 + 1.772*10      = 117.72  -> 118
    var c0 = [_]i64{100 << dwt.FP_Q};
    var c1 = [_]i64{10 << dwt.FP_Q};
    var c2 = [_]i64{20 << dwt.FP_Q};
    inverseIct(&c0, &c1, &c2);
    try std.testing.expectEqual(@as(i32, 128), dwt.fpRound(c0[0]));
    try std.testing.expectEqual(@as(i32, 82), dwt.fpRound(c1[0]));
    try std.testing.expectEqual(@as(i32, 118), dwt.fpRound(c2[0]));
}

/// Max legitimate past-end 0xFF synthesis (MQ over-read) for a conforming
/// code-block. This is a CORPUS-CALIBRATED bound, not a derived one: T.800
/// (Annex D, codeword truncation) lets an encoder drop trailing codeword
/// bytes as long as decoding with 0xFF fill stays exact, so no hard bound
/// exists without PTERM. The earlier "register lookahead = 4" rationale was
/// falsified by two ISO-conformant encoders whose tier-1 output is
/// byte-identical to openjpeg: p0_08 over-reads up to 10 and file6 up to 8
/// (2026-09-06 census over all 57 conformance fixtures; every other file
/// <= 3). Cap = 12 = observed maximum + 2. Mis-decode/truncation runs far
/// higher (e1_colr desync class: 12-21 and beyond). Re-run the census
/// (`zig build tile-hist` with JP2Z_DUMP_T1 over the corpus) before
/// tightening it.
/// complexity: O(1)
fn overReadCap(cblksty: u8) u32 {
    // PTERM (cblksty bit 0x10, T.800 predictable termination): every terminated
    // pass ends with a full flush, so the legitimate tail IS bounded, at 2 —
    // openjpeg's check_pterm bound, applied here WITH its precondition (and as
    // a strict finding rather than openjpeg's warning-only). The PTERM corpus
    // files (p0_02, p1_01: cbsty 0x34) sit at 2.
    return if (cblksty & 0x10 != 0) 2 else 12;
}

test "overReadCap: classifier over the (cblksty, over_read) boundary domain" {
    const PTERM: u8 = 0x10; // T.800 SPcod cblksty bit 4 — predictable termination
    // Under PTERM every terminated pass ends with a full flush, so the tail is
    // genuinely bounded at 2 (openjpeg t1.c check_pterm's >2, HERE its
    // precondition actually holds). Without PTERM the corpus-calibrated cap
    // of 12 applies (observed valid maximum 10: p0_08; 8: file6).
    const cases = [_]struct { sty: u8, over: u32, flag: bool }{
        // non-PTERM: boundary at 12
        .{ .sty = 0x00, .over = 0, .flag = false },
        .{ .sty = 0x00, .over = 3, .flag = false }, // b1_mono/p0_04 valid case
        .{ .sty = 0x00, .over = 10, .flag = false }, // p0_08 valid case (census max)
        .{ .sty = 0x00, .over = 12, .flag = false },
        .{ .sty = 0x00, .over = 13, .flag = true },
        .{ .sty = 0x00, .over = 21, .flag = true }, // e1_colr desync class
        // PTERM: boundary tightens to 2
        .{ .sty = PTERM, .over = 2, .flag = false },
        .{ .sty = PTERM, .over = 3, .flag = true }, // legal without PTERM, violation with
        .{ .sty = PTERM, .over = 4, .flag = true },
        // PTERM composes with other style bits (BYPASS|TERMALL|PTERM etc.)
        .{ .sty = PTERM | 0x0f, .over = 3, .flag = true },
        .{ .sty = 0x2f, .over = 3, .flag = false }, // c2-style flags, NO pterm bit
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.flag, c.over > overReadCap(c.sty));
    }
}

test "dequantScaleQ: stepsize=1 (mant=0, expn=prec) gives 0.5 in Q16" {
    // stepsize = (1+0)*2^(prec-expn). For expn=prec, stepsize=1 -> 0.5*stepsize=0.5.
    try std.testing.expectEqual(@as(i64, dwt.FP_ONE >> 1), dequantScaleQ(8, 8, 0));
    // expn = prec-1 -> stepsize=2 -> 0.5*stepsize = 1.0 (= FP_ONE).
    try std.testing.expectEqual(@as(i64, dwt.FP_ONE), dequantScaleQ(8, 7, 0));
}

/// Append a finding to a report and escalate its overall severity.
fn appendFinding(report: *codestream.ValidationReport, allocator: Allocator, sev: codestream.Severity, code: codestream.FindingCode, offset: ?u64, detail: ?[]const u8) Allocator.Error!void {
    // Take ownership of `detail`: on success the finding owns it (freed by
    // report.deinit); on append-OOM free it here so the caller's allocPrint'd
    // string never leaks (reviewer C1, mirrors codestream.emit's errdefer).
    errdefer if (detail) |d| allocator.free(d);
    try report.findings.append(allocator, .{ .severity = sev, .code = code, .offset = offset, .detail = detail });
    if (@intFromEnum(sev) > @intFromEnum(report.overall)) report.overall = sev;
}

test "appendFinding frees caller detail when findings.append OOMs (reviewer C1)" {
    const testing = std.testing;
    var report = codestream.ValidationReport{
        .overall = .pass,
        .variant = .unknown,
        .width = null,
        .height = null,
        .findings = .empty,
    };
    defer report.deinit(testing.allocator);
    // Fail the SECOND allocation: index 0 = the detail dupe (succeeds, as
    // deepValidate's allocPrint would), index 1 = findings.append's grow
    // (fails). appendFinding must free `detail` on that unwind — otherwise
    // std.testing.allocator reports a leak when this test ends.
    var fa = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    const a = fa.allocator();
    const detail = try a.dupe(u8, "caller-owned detail");
    const r = appendFinding(&report, a, .warn, .coding_pass_overflow, null, detail);
    try testing.expectError(error.OutOfMemory, r);
    try testing.expectEqual(@as(usize, 0), report.findings.items.len);
}

test "planRangeFor buckets sorted plans, visiting each exactly once (reviewer I2: O(plans))" {
    const Plan = cblk_plan.CblkDecodePlan;
    var empty = [_]u8{};
    const e: []u8 = &empty;
    const mk = struct {
        fn f(tile: u32, comp: u16, data: []u8) Plan {
            return .{
                .tile = tile, .component = comp, .resolution = 0, .band = 0,
                .precinct = 0, .sb_x0 = 0, .sb_y0 = 0, .sb_x1 = 0, .sb_y1 = 0,
                .zero_bitplanes = 0, .numbps = 0, .total_passes = 0, .cblksty = 0,
                .data = data,
            };
        }
    }.f;
    // 3 tiles × 2 components, uneven counts, incl. an EMPTY (tile=1,comp=0) bucket.
    var plans = [_]Plan{
        mk(0, 0, e), mk(0, 0, e), mk(0, 1, e),
        mk(1, 1, e),
        mk(2, 0, e), mk(2, 1, e), mk(2, 1, e),
    };
    std.mem.sort(Plan, &plans, {}, planTileCompLess);

    // Sweep (tile, component) ascending — the order decodeCleanroom uses.
    var cursor: usize = 0;
    var total_visited: usize = 0;
    var tile: u32 = 0;
    while (tile < 3) : (tile += 1) {
        var comp: u16 = 0;
        while (comp < 2) : (comp += 1) {
            const r = planRangeFor(&plans, &cursor, tile, comp);
            for (r) |pl| {
                try std.testing.expectEqual(tile, pl.tile);
                try std.testing.expectEqual(comp, pl.component);
            }
            total_visited += r.len;
        }
    }
    // Every plan landed in exactly its bucket; the cursor consumed the whole
    // list once → O(plans), not O(tiles·components·plans).
    try std.testing.expectEqual(@as(usize, plans.len), total_visited);
    try std.testing.expectEqual(plans.len, cursor);
}

/// Strict deep validation: the structural walk PLUS a full entropy decode
/// of every code-block, emitting deep-integrity findings that permissive
/// libraries (which decode and move on) never report. This is jp2z's
/// `validate`-facing value-add. Returns the augmented ValidationReport.
pub fn deepValidate(allocator: Allocator, data: []const u8, strict: bool) !codestream.ValidationReport {
    var report = try codestream.validate(allocator, data);
    errdefer report.deinit(allocator);
    if (report.coding_params == null) return report; // structural-only

    var list = codestream.extractCblkPlans(allocator, data) catch return report;
    defer list.deinit(allocator);
    // HT code-blocks (T.814) are not MQ/RAW data: a byte budget over them
    // would be noise (Bretagne1_ht: 273 "under-reads"). The structural walk
    // already surfaced the c145 WARN; stop here.
    if (list.ht_unsupported) return report;

    const sev: codestream.Severity = if (strict) .fail else .warn;
    var over_count: u32 = 0;
    var under_count: u32 = 0;
    var passbudget_count: u32 = 0;
    var zbp_overflow_count: u32 = 0;
    // First offender per category: the aggregate finding anchors at its
    // codestream offset and names it, so a consumer (or a future session)
    // can go straight to the cblk instead of re-instrumenting the walk.
    var first_over: ?cblk_plan.CblkDecodePlan = null;
    var first_under: ?cblk_plan.CblkDecodePlan = null;
    var first_passbudget: ?cblk_plan.CblkDecodePlan = null;
    var first_zbp: ?cblk_plan.CblkDecodePlan = null;
    var surplus_count: u32 = 0;
    var first_surplus: ?cblk_plan.CblkDecodePlan = null;
    var segsym_count: u32 = 0;
    var first_segsym: ?cblk_plan.CblkDecodePlan = null;
    for (list.plans) |plan| {
        // numbps == 0 means the zero-bitplane tag tree consumed the whole
        // bit-depth budget (zero_bitplanes >= M_b). A cblk with coding
        // passes over ZERO bit-planes is impossible — a tag-tree/bit-depth
        // corruption whose root cause differs from a pass-count overflow,
        // so it gets its own finding rather than being blamed on the pass
        // count (whose "too many passes" wording would misdirect: the
        // pass count is fine, the bit-plane count is the lie).
        if (plan.numbps == 0) {
            if (plan.total_passes > 0) {
                zbp_overflow_count += 1;
                if (first_zbp == null) first_zbp = plan;
            }
            continue;
        }
        // Coding-pass budget (no decode needed): numbps bit-planes allow at
        // most 1 + 3*(numbps-1) = 3*numbps-2 passes. More is impossible.
        // 31 is the ceiling of the tier-1 bit-plane index (u5; openjpeg
        // refuses bpno_plus_one >= 31): M_b + ROI shift - zero_bitplanes past
        // it cannot be decoded and cannot be conforming.
        if (plan.numbps > 31) {
            passbudget_count += 1;
            if (first_passbudget == null) first_passbudget = plan;
            continue;
        }
        // Surplus passes: more than numbps planes can hold. Real encoders
        // emit them (ClearCanvas/OpenJPEG-1.x DICOM: test_lossless.j2k, +2/
        // +5/+8 on 58 cblks) and every decoder ignores passes below plane 0
        // identically (openjpeg == JasPer byte-for-byte), so this is a
        // WARN in both modes. The passes still run for the budget check
        // below, which is what separates a self-consistent surplus from a
        // garbage pass count (kodak_2layers_lrcp: over-reads of hundreds).
        const max_passes: u32 = 3 * @as(u32, plan.numbps) - 2;
        if (plan.total_passes > max_passes) {
            surplus_count += 1;
            if (first_surplus == null) first_surplus = plan;
        }
        if (plan.total_passes == 0 or plan.data.len == 0) continue;
        var cblk = try cblk_dispatch.decodePlan(allocator, plan);
        defer cblk.deinit(allocator);
        if (cblk.over_read > overReadCap(plan.cblksty)) {
            over_count += 1;
            if (first_over == null) first_over = plan;
        }
        // SEGSYM (cblksty 0x20, T.800 D.5): every cleanup pass ends with the
        // 1010 symbol in the UNIFORM context. A different symbol is the
        // stream's own integrity hook firing on corrupted entropy data,
        // independent of whether the byte budget still balances.
        if (cblk.segsym_error) {
            segsym_count += 1;
            if (first_segsym == null) first_segsym = plan;
        }
        // NOTE: under_read (declared-but-unconsumed bytes) is symmetric and could
        // in principle false-positive up to the same ~4 lookahead, but no valid
        // fixture trips it today (b1/p0_04 under_read=0); revisit with the same
        // register-derived cap if one ever does.
        if (cblk.under_read > 2) {
            under_count += 1;
            if (first_under == null) first_under = plan;
        }
    }
    if (zbp_overflow_count > 0) {
        const p = first_zbp.?;
        const detail = try std.fmt.allocPrint(allocator, "{d} code-block(s) have a zero-bitplane count that consumes the whole bit-depth (numbps=0) yet carry coding passes (first: tile {d} comp {d} r{d} band {d} prc {d})", .{ zbp_overflow_count, p.tile, p.component, p.resolution, p.band, p.precinct });
        try appendFinding(&report, allocator, sev, .zero_bitplane_overflow, p.src_offset, detail);
    }
    if (passbudget_count > 0) {
        const p = first_passbudget.?;
        const detail = try std.fmt.allocPrint(allocator, "{d} code-block(s) declare more coding passes than numbps allows (first: tile {d} comp {d} r{d} band {d} prc {d})", .{ passbudget_count, p.tile, p.component, p.resolution, p.band, p.precinct });
        try appendFinding(&report, allocator, sev, .coding_pass_overflow, p.src_offset, detail);
    }
    if (surplus_count > 0) {
        const p = first_surplus.?;
        const detail = try std.fmt.allocPrint(allocator, "{d} code-block(s) declare more coding passes than their bit-planes hold; passes below bit-plane 0 are ignored by convention (openjpeg, JasPer) and their bytes still count toward the budget (first: tile {d} comp {d} r{d} band {d} prc {d})", .{ surplus_count, p.tile, p.component, p.resolution, p.band, p.precinct });
        // Strict: FAIL. The passes have no defined meaning (B.10.7 / D), so a
        // stream that declares them is nonconforming however decoders cope
        // (Peter, 2026-09-12). Lenient mode keeps the WARN.
        try appendFinding(&report, allocator, sev, .coding_pass_overflow, p.src_offset, detail);
    }
    if (segsym_count > 0) {
        const p = first_segsym.?;
        const detail = try std.fmt.allocPrint(allocator, "{d} code-block(s) ended a cleanup pass without the 1010 segmentation symbol (SEGSYM, T.800 D.5): entropy data corrupted (first: tile {d} comp {d} r{d} band {d} prc {d})", .{ segsym_count, p.tile, p.component, p.resolution, p.band, p.precinct });
        try appendFinding(&report, allocator, sev, .segmentation_symbol_mismatch, p.src_offset, detail);
    }
    if (over_count > 0) {
        const p = first_over.?;
        const detail = try std.fmt.allocPrint(allocator, "{d} code-block(s) over-read past their entropy data (truncated/corrupt) (first: tile {d} comp {d} r{d} band {d} prc {d})", .{ over_count, p.tile, p.component, p.resolution, p.band, p.precinct });
        try appendFinding(&report, allocator, sev, .entropy_over_read, p.src_offset, detail);
    }
    if (under_count > 0) {
        const p = first_under.?;
        const detail = try std.fmt.allocPrint(allocator, "{d} code-block(s) left entropy bytes unconsumed (byte-budget mismatch) (first: tile {d} comp {d} r{d} band {d} prc {d})", .{ under_count, p.tile, p.component, p.resolution, p.band, p.precinct });
        try appendFinding(&report, allocator, sev, .entropy_under_read, p.src_offset, detail);
    }

    // EOC is mandatory (T.800 A.4.4). The structural walk flags a missing
    // terminator as `missing_eoi` at WARN; escalate it to strict severity so
    // strict mode REJECTs a codestream with no EOC, while relaxed mode keeps it
    // a WARN (the body is still decodable). `sev` is .fail when strict and
    // .warn when relaxed, so relaxed is a no-op — missing_eoi is already WARN.
    for (report.findings.items) |*fnd| {
        if (fnd.code == .missing_eoi and @intFromEnum(sev) > @intFromEnum(fnd.severity)) {
            fnd.severity = sev;
            if (@intFromEnum(sev) > @intFromEnum(report.overall)) report.overall = sev;
        }
    }

    return report;
}
