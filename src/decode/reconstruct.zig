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
/// Assemble + inverse-DWT one component's tile buffer from its plans.
/// Returns an `image_w × image_h` i32 buffer of spatial samples
/// (pre level-shift, pre-MCT). Caller owns it.
pub fn reconstructComponentTile(
    allocator: Allocator,
    plans: []const cblk_plan.CblkDecodePlan,
    tile_index: u32,
    component: u16,
    image_w: u32,
    image_h: u32,
    num_decomp: u8,
) Allocator.Error![]i32 {
    const tile_w = image_w;
    const buf = try allocator.alloc(i32, @as(usize, image_w) * @as(usize, image_h));
    @memset(buf, 0);
    errdefer allocator.free(buf);

    for (plans) |plan| {
        if (plan.tile != tile_index) continue;
        if (plan.component != component) continue;
        if (plan.numbps == 0 or plan.total_passes == 0 or plan.data.len == 0) continue;

        var cblk = try cblk_dispatch.decodePlan(allocator, plan);
        defer cblk.deinit(allocator);

        const msb_bp: u5 = @intCast(plan.numbps);
        const half_bp = cblk_dispatch.halfBitPos(msb_bp, plan.total_passes);

        // Subband quadrant base inside the tile buffer (Mallat layout).
        var base_x: u32 = @intCast(plan.sb_x0);
        var base_y: u32 = @intCast(plan.sb_y0);
        if (plan.resolution >= 1) {
            const prev = subbands.resolutionExtent(image_w, image_h, num_decomp, plan.resolution - 1);
            if (plan.band & 1 != 0) base_x += prev.width; // HL / HH → right quadrant
            if (plan.band & 2 != 0) base_y += prev.height; // LH / HH → bottom quadrant
        }

        const cw = plan.width();
        const ch = plan.height();
        var j: u32 = 0;
        while (j < ch) : (j += 1) {
            var i: u32 = 0;
            while (i < cw) : (i += 1) {
                const coeff = cblk_dispatch.coeffToOpenJpegI32(cblk.coeffs[j * cw + i], half_bp);
                // Reversible band→tile pre-scale: truncating /2 (NOT >>1).
                buf[(base_y + j) * tile_w + (base_x + i)] = @divTrunc(coeff, 2);
            }
        }
    }

    try dwt.idwt53(allocator, buf, tile_w, image_w, image_h, num_decomp);
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

/// Full cleanroom decode of a (reversible, single-tile) JP2/J2K
/// codestream to per-component sample planes. Inverse MCT is applied
/// for the 3-component reversible (RCT) case; otherwise components are
/// independent. (Irreversible 9/7 is M5; this is the 5/3 path.)
pub fn decodeCleanroom(allocator: Allocator, data: []const u8) !Image {
    var report = try codestream.validate(allocator, data);
    defer report.deinit(allocator);
    const params = report.coding_params orelse return error.NoCodingParams;
    const image_w = report.width orelse return error.NoDimensions;
    const image_h = report.height orelse return error.NoDimensions;
    // Output dims. For the multi-tile/sub-sampled 5/3 path these become the
    // component-grid dims (set in that branch); otherwise the ref-grid dims.
    var out_w: u32 = image_w;
    var out_h: u32 = image_h;
    const ncomp = params.num_components;

    var list = try codestream.extractCblkPlans(allocator, data);
    defer list.deinit(allocator);

    const planes = try allocator.alloc([]i32, ncomp);
    errdefer allocator.free(planes);
    const precs = try allocator.alloc(u8, ncomp);
    errdefer allocator.free(precs);

    var done: u16 = 0;
    errdefer for (planes[0..done]) |p| allocator.free(p);
    var c: u16 = 0;
    while (c < ncomp) : (c += 1) precs[c] = params.comp_prec[@min(c, 15)];

    if (params.wavelet == .reversible_5x3) {
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
                tbufs[c] = try reconstructComponentTile(allocator, list.plans, t, c, tcw, tch, params.num_decomp_levels);
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
        // ── Lossy 9/7 path (Q16 fixed-point) ──
        const qplanes = try allocator.alloc([]i64, ncomp);
        var qdone: u16 = 0;
        defer {
            for (qplanes[0..qdone]) |p| allocator.free(p);
            allocator.free(qplanes);
        }
        c = 0;
        while (c < ncomp) : (c += 1) {
            qplanes[c] = try reconstructComponentTile97(allocator, list.plans, c, image_w, image_h, params);
            qdone += 1;
        }
        if (params.mct and ncomp >= 3) inverseIct(qplanes[0], qplanes[1], qplanes[2]);
        // round (ties-to-even) + DC level shift + clamp. `done` (the
        // function-level errdefer counter) now tracks `planes`.
        c = 0;
        while (c < ncomp) : (c += 1) {
            const prec = precs[c];
            const is_signed = (params.comp_signed >> @intCast(@min(c, 15))) & 1 != 0;
            const dc: i32 = if (is_signed) 0 else (@as(i32, 1) << @intCast(prec - 1));
            const lo: i32 = if (is_signed) -(@as(i32, 1) << @intCast(prec - 1)) else 0;
            const hi: i32 = if (is_signed) (@as(i32, 1) << @intCast(prec - 1)) - 1 else (@as(i32, 1) << @intCast(prec)) - 1;
            const plane = try allocator.alloc(i32, qplanes[c].len);
            for (qplanes[c], 0..) |v, i| plane[i] = std.math.clamp(dwt.fpRound(v) + dc, lo, hi);
            planes[c] = plane;
            done += 1;
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

/// Assemble + inverse 9/7 DWT one component into a Q16 (i64) tile buffer.
pub fn reconstructComponentTile97(
    allocator: Allocator,
    plans: []const cblk_plan.CblkDecodePlan,
    component: u16,
    image_w: u32,
    image_h: u32,
    params: codestream.CodingParams,
) Allocator.Error![]i64 {
    const tile_w = image_w;
    const num_decomp = params.num_decomp_levels;
    const prec = params.comp_prec[@min(component, 15)];
    const buf = try allocator.alloc(i64, @as(usize, image_w) * @as(usize, image_h));
    @memset(buf, 0);
    errdefer allocator.free(buf);

    for (plans) |plan| {
        if (plan.component != component) continue;
        if (plan.numbps == 0 or plan.total_passes == 0 or plan.data.len == 0) continue;
        var cblk = try cblk_dispatch.decodePlan(allocator, plan);
        defer cblk.deinit(allocator);

        const msb_bp: u5 = @intCast(plan.numbps);
        const half_bp = cblk_dispatch.halfBitPos(msb_bp, plan.total_passes);
        const sb = codestream.CodingParams.subbandIndex(plan.resolution, plan.band);
        const scale_q = dequantScaleQ(prec, params.qcd_expn[sb], params.qcd_mant[sb]);

        var base_x: u32 = @intCast(plan.sb_x0);
        var base_y: u32 = @intCast(plan.sb_y0);
        if (plan.resolution >= 1) {
            const prev = subbands.resolutionExtent(image_w, image_h, num_decomp, plan.resolution - 1);
            if (plan.band & 1 != 0) base_x += prev.width;
            if (plan.band & 2 != 0) base_y += prev.height;
        }
        const cw = plan.width();
        const ch = plan.height();
        var j: u32 = 0;
        while (j < ch) : (j += 1) {
            var i: u32 = 0;
            while (i < cw) : (i += 1) {
                const t1 = cblk_dispatch.coeffToOpenJpegI32(cblk.coeffs[j * cw + i], half_bp);
                buf[(base_y + j) * tile_w + (base_x + i)] = @as(i64, t1) * scale_q; // Q16
            }
        }
    }

    try dwt.idwt97(allocator, buf, tile_w, image_w, image_h, num_decomp);
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

test "dequantScaleQ: stepsize=1 (mant=0, expn=prec) gives 0.5 in Q16" {
    // stepsize = (1+0)*2^(prec-expn). For expn=prec, stepsize=1 -> 0.5*stepsize=0.5.
    try std.testing.expectEqual(@as(i64, dwt.FP_ONE >> 1), dequantScaleQ(8, 8, 0));
    // expn = prec-1 -> stepsize=2 -> 0.5*stepsize = 1.0 (= FP_ONE).
    try std.testing.expectEqual(@as(i64, dwt.FP_ONE), dequantScaleQ(8, 7, 0));
}

/// Append a finding to a report and escalate its overall severity.
fn appendFinding(report: *codestream.ValidationReport, allocator: Allocator, sev: codestream.Severity, code: codestream.FindingCode, detail: ?[]const u8) Allocator.Error!void {
    // Take ownership of `detail`: on success the finding owns it (freed by
    // report.deinit); on append-OOM free it here so the caller's allocPrint'd
    // string never leaks (reviewer C1, mirrors codestream.emit's errdefer).
    errdefer if (detail) |d| allocator.free(d);
    try report.findings.append(allocator, .{ .severity = sev, .code = code, .offset = null, .detail = detail });
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
    const r = appendFinding(&report, a, .warn, .coding_pass_overflow, detail);
    try testing.expectError(error.OutOfMemory, r);
    try testing.expectEqual(@as(usize, 0), report.findings.items.len);
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

    const sev: codestream.Severity = if (strict) .fail else .warn;
    var over_count: u32 = 0;
    var under_count: u32 = 0;
    var passbudget_count: u32 = 0;
    for (list.plans) |plan| {
        // Coding-pass budget (no decode needed): numbps bit-planes allow at
        // most 1 + 3*(numbps-1) = 3*numbps-2 passes. More is impossible.
        const max_passes: u32 = if (plan.numbps == 0) 0 else 3 * @as(u32, plan.numbps) - 2;
        if (plan.total_passes > max_passes) passbudget_count += 1;
        if (plan.numbps == 0 or plan.total_passes == 0 or plan.data.len == 0) continue;
        var cblk = try cblk_dispatch.decodePlan(allocator, plan);
        defer cblk.deinit(allocator);
        if (cblk.over_read > 2) over_count += 1;
        if (cblk.under_read > 2) under_count += 1;
    }
    if (passbudget_count > 0) {
        const detail = try std.fmt.allocPrint(allocator, "{d} code-block(s) declare more coding passes than numbps allows", .{passbudget_count});
        try appendFinding(&report, allocator, sev, .coding_pass_overflow, detail);
    }
    if (over_count > 0) {
        const detail = try std.fmt.allocPrint(allocator, "{d} code-block(s) over-read past their entropy data (truncated/corrupt)", .{over_count});
        try appendFinding(&report, allocator, sev, .entropy_over_read, detail);
    }
    if (under_count > 0) {
        const detail = try std.fmt.allocPrint(allocator, "{d} code-block(s) left entropy bytes unconsumed (byte-budget mismatch)", .{under_count});
        try appendFinding(&report, allocator, sev, .entropy_under_read, detail);
    }
    return report;
}
