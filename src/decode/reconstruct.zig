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

/// Assemble + inverse-DWT one component's tile buffer from its plans.
/// Returns an `image_w × image_h` i32 buffer of spatial samples
/// (pre level-shift, pre-MCT). Caller owns it.
pub fn reconstructComponentTile(
    allocator: Allocator,
    plans: []const cblk_plan.CblkDecodePlan,
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
    while (c < ncomp) : (c += 1) {
        planes[c] = try reconstructComponentTile(allocator, list.plans, c, image_w, image_h, params.num_decomp_levels);
        precs[c] = params.comp_prec[@min(c, 15)];
        done += 1;
    }

    // Inverse MCT (reversible RCT) for 3-component MCT images — M6.
    if (params.mct and ncomp >= 3) {
        inverseRct(planes[0], planes[1], planes[2]);
    }

    // DC level shift + clamp per component.
    c = 0;
    while (c < ncomp) : (c += 1) {
        const is_signed = (params.comp_signed >> @intCast(@min(c, 15))) & 1 != 0;
        levelShift(planes[c], precs[c], is_signed);
    }

    return .{
        .width = image_w,
        .height = image_h,
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
