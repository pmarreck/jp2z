//! Inverse discrete wavelet transform — reversible 5/3 (lossless),
//! T.800 Annex F / G. Cleanroom integer lifting; cross-referenced
//! against OpenJPEG dwt.c (opj_idwt53) for byte-exactness but not
//! copied.
//!
//! The tile-component buffer is in Mallat (interleaved-by-quadrant)
//! layout: at each resolution step the region [0,rw)×[0,rh) holds the
//! four deinterleaved quadrants [LL HL; LH HH], where LL is the
//! previous (coarser) resolution. One inverse step does all rows
//! (horizontal) then all columns (vertical), turning each axis's
//! [low | high] split into interleaved spatial samples. Steps run
//! coarse→fine until the full resolution is reconstructed.
//!
//! All `>>` here are arithmetic (floor) shifts on i32; the band→tile
//! pre-scale uses truncating `@divTrunc(v, 2)` (NOT `>>1`), matching
//! OpenJPEG (negative odd values differ).

const std = @import("std");
const subbands = @import("subbands.zig");

/// Even (low-pass) sample at interleaved position 2i, clamped to
/// [0, bound-1] for symmetric (edge-replication) boundary extension.
inline fn sClamp(a: []const i32, bound: usize, i: isize) i32 {
    const c: usize = if (i < 0) 0 else if (@as(usize, @intCast(i)) >= bound) bound - 1 else @intCast(i);
    return a[2 * c];
}
/// Odd (high-pass) sample at interleaved position 2i+1, edge-clamped.
inline fn dClamp(a: []const i32, bound: usize, i: isize) i32 {
    const c: usize = if (i < 0) 0 else if (@as(usize, @intCast(i)) >= bound) bound - 1 else @intCast(i);
    return a[2 * c + 1];
}

/// Inverse 5/3 lifting over one line. `line` holds the deinterleaved
/// `[ low(0..sn) | high(0..dn) ]` split on input; on return it holds
/// `sn+dn` interleaved spatial samples. `tmp` must be at least
/// `sn+dn` long (scratch for the interleave). `cas` is the parity of
/// the resolution origin (0 ⇒ first spatial sample is low-pass).
pub fn idwt53Line(line: []i32, sn: usize, dn: usize, cas: u1, tmp: []i32) void {
    const len = sn + dn;
    if (len == 0) return;
    // Interleave [low|high] → spatial positions: low(k) → tmp[cas+2k],
    // high(k) → tmp[(1-cas)+2k] (T.800 / opj_dwt_interleave).
    {
        var k: usize = 0;
        while (k < sn) : (k += 1) tmp[cas + 2 * k] = line[k];
        k = 0;
        while (k < dn) : (k += 1) tmp[(1 - cas) + 2 * k] = line[sn + k];
    }

    if (cas == 0) {
        // S(i) -= (D(i-1)+D(i)+2)>>2 ; then D(i) += (S(i)+S(i+1))>>1.
        if (dn > 0) {
            var i: usize = 0;
            while (i < sn) : (i += 1) {
                const dm1 = dClamp(tmp, dn, @as(isize, @intCast(i)) - 1);
                const d0 = dClamp(tmp, dn, @intCast(i));
                tmp[2 * i] -%= (dm1 +% d0 +% 2) >> 2;
            }
            i = 0;
            while (i < dn) : (i += 1) {
                const s0 = sClamp(tmp, sn, @intCast(i));
                const s1 = sClamp(tmp, sn, @as(isize, @intCast(i)) + 1);
                tmp[2 * i + 1] +%= (s0 +% s1) >> 1;
            }
        }
    } else {
        // cas == 1: origin on an odd coordinate.
        if (sn == 0 and dn == 1) {
            tmp[0] = @divTrunc(tmp[0], 2);
        } else {
            // D(i) -= (S(i)+S(i+1)+2)>>2 [S clamped to dn]; then
            // S(i) += (D(i)+D(i-1))>>1 [D clamped to sn].
            var i: usize = 0;
            while (i < sn) : (i += 1) {
                const s0 = sClamp(tmp, dn, @intCast(i));
                const s1 = sClamp(tmp, dn, @as(isize, @intCast(i)) + 1);
                tmp[2 * i + 1] -%= (s0 +% s1 +% 2) >> 2;
            }
            i = 0;
            while (i < dn) : (i += 1) {
                const d0 = dClamp(tmp, sn, @intCast(i));
                const dm1 = dClamp(tmp, sn, @as(isize, @intCast(i)) - 1);
                tmp[2 * i] +%= (d0 +% dm1) >> 1;
            }
        }
    }
    @memcpy(line[0..len], tmp[0..len]);
}

/// Full inverse 5/3 DWT over a tile-component buffer `tile` of size
/// `tile_w × tile_h` (= the finest-resolution dims), row-major. The
/// buffer must already hold the per-resolution Mallat quadrants. After
/// this returns, `tile[0..tile_w*tile_h]` holds the spatial samples.
/// `num_decomp` = number of decomposition levels (R); when 0 the buffer
/// is already the image. Tile origin is assumed (0,0) ⇒ cas == 0.
pub fn idwt53(
    allocator: std.mem.Allocator,
    tile: []i32,
    tile_w: u32,
    image_w: u32,
    image_h: u32,
    num_decomp: u8,
) std.mem.Allocator.Error!void {
    if (num_decomp == 0) return;
    const max_dim = @max(image_w, image_h);
    const tmp = try allocator.alloc(i32, max_dim);
    defer allocator.free(tmp);
    const col = try allocator.alloc(i32, image_h);
    defer allocator.free(col);

    var r: u8 = 1;
    while (r <= num_decomp) : (r += 1) {
        const cur = subbands.resolutionExtent(image_w, image_h, num_decomp, r);
        const prev = subbands.resolutionExtent(image_w, image_h, num_decomp, r - 1);
        const rw = cur.width;
        const rh = cur.height;
        if (rw == 0 or rh == 0) continue;
        const sn_h = prev.width;
        const dn_h = rw - prev.width;
        const sn_v = prev.height;
        const dn_v = rh - prev.height;
        // Tile origin (0,0): resolution origins are 0 ⇒ cas = 0 on both axes.
        const cas_x: u1 = 0;
        const cas_y: u1 = 0;

        // Horizontal pass: every row, transform its first `rw` samples.
        var j: usize = 0;
        while (j < rh) : (j += 1) {
            const base = j * tile_w;
            idwt53Line(tile[base .. base + rw], sn_h, dn_h, cas_x, tmp);
        }

        // Vertical pass: every column, gather → transform → scatter.
        var i: usize = 0;
        while (i < rw) : (i += 1) {
            var k: usize = 0;
            while (k < rh) : (k += 1) col[k] = tile[k * tile_w + i];
            idwt53Line(col[0..rh], sn_v, dn_v, cas_y, tmp);
            k = 0;
            while (k < rh) : (k += 1) tile[k * tile_w + i] = col[k];
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────

/// Forward 5/3 lifting (test oracle only) — inverse of `idwt53Line`
/// for cas==0. Input: `sn+dn` spatial samples; output: deinterleaved
/// [low | high]. Used purely to prove the inverse is a true inverse.
fn fdwt53Line_cas0(line: []i32, sn: usize, dn: usize, tmp: []i32) void {
    const len = sn + dn;
    if (len == 0) return;
    @memcpy(tmp[0..len], line[0..len]);
    // Forward: D(i) -= (S(i)+S(i+1))>>1 ; then S(i) += (D(i-1)+D(i)+2)>>2.
    if (dn > 0) {
        var i: usize = 0;
        while (i < dn) : (i += 1) {
            const s0 = sClamp(tmp, sn, @intCast(i));
            const s1 = sClamp(tmp, sn, @as(isize, @intCast(i)) + 1);
            tmp[2 * i + 1] -%= (s0 +% s1) >> 1;
        }
        i = 0;
        while (i < sn) : (i += 1) {
            const dm1 = dClamp(tmp, dn, @as(isize, @intCast(i)) - 1);
            const d0 = dClamp(tmp, dn, @intCast(i));
            tmp[2 * i] +%= (dm1 +% d0 +% 2) >> 2;
        }
    }
    // Deinterleave: low(k)=tmp[2k] → line[k]; high(k)=tmp[2k+1] → line[sn+k].
    var k: usize = 0;
    while (k < sn) : (k += 1) line[k] = tmp[2 * k];
    k = 0;
    while (k < dn) : (k += 1) line[sn + k] = tmp[2 * k + 1];
}

test "idwt53Line: round-trips forward 5/3 for various lengths (cas 0)" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rnd = prng.random();
    const lens = [_]usize{ 1, 2, 3, 4, 5, 8, 13, 64, 89 };
    for (lens) |len| {
        const sn = (len + 1) / 2; // even-coordinate count for cas 0
        const dn = len - sn;
        const orig = try allocator.alloc(i32, len);
        defer allocator.free(orig);
        const work = try allocator.alloc(i32, len);
        defer allocator.free(work);
        const tmp = try allocator.alloc(i32, len);
        defer allocator.free(tmp);
        for (orig) |*v| v.* = rnd.intRangeAtMost(i32, -1000, 1000);
        @memcpy(work, orig);
        fdwt53Line_cas0(work, sn, dn, tmp); // spatial → [low|high]
        idwt53Line(work, sn, dn, 0, tmp); // [low|high] → spatial
        try std.testing.expectEqualSlices(i32, orig, work);
    }
}

test "idwt53Line: len 1 cas 0 is identity (single low sample)" {
    var line = [_]i32{42};
    var tmp = [_]i32{0};
    idwt53Line(&line, 1, 0, 0, &tmp);
    try std.testing.expectEqual(@as(i32, 42), line[0]);
}

test "idwt53: 2D round-trip via separable forward (cas 0, full-image)" {
    // Build a small image, forward-transform (separable rows then cols)
    // into Mallat layout for a 1-level decomposition, then idwt53 must
    // recover it exactly.
    const allocator = std.testing.allocator;
    const w: u32 = 6;
    const h: u32 = 4;
    var img = [_]i32{
        10, 20, 30, 40, 50, 60,
        15, 25, 35, 45, 55, 65,
        12, 22, 32, 42, 52, 62,
        18, 28, 38, 48, 58, 68,
    };
    var orig: [24]i32 = undefined;
    @memcpy(&orig, &img);

    const tmp = try allocator.alloc(i32, @max(w, h));
    defer allocator.free(tmp);
    const sn_h = (w + 1) / 2;
    const dn_h = w - sn_h;
    const sn_v = (h + 1) / 2;
    const dn_v = h - sn_v;
    // Forward rows.
    var j: usize = 0;
    while (j < h) : (j += 1) fdwt53Line_cas0(img[j * w .. j * w + w], sn_h, dn_h, tmp);
    // Forward cols.
    var i: usize = 0;
    while (i < w) : (i += 1) {
        var coltmp: [4]i32 = undefined;
        var k: usize = 0;
        while (k < h) : (k += 1) coltmp[k] = img[k * w + i];
        fdwt53Line_cas0(&coltmp, sn_v, dn_v, tmp);
        k = 0;
        while (k < h) : (k += 1) img[k * w + i] = coltmp[k];
    }
    // Now `img` is the 1-level Mallat buffer. Invert (num_decomp=1).
    try idwt53(allocator, &img, w, w, h, 1);
    try std.testing.expectEqualSlices(i32, &orig, &img);
}

// ── Irreversible 9/7 inverse DWT (fixed-point) ──────────────────────
//
// OpenJPEG decodes 9/7 in float; the project rule mandates integer math,
// so this is a fixed-point (Q16) reimplementation. It converges to the
// mathematically-ideal transform rather than reproducing float's
// round-off, so output matches openjpeg within a small tolerance (the
// JPEG2000 lossy-decode standard), not bit-exactly. Constants and step
// order mirror opj_v8dwt_decode (incl. the decoder's two_invK quirk).

const Q97: u6 = 16;
const Q97_ONE: i64 = 1 << Q97;

fn qConst(comptime v: f64) i64 {
    return @intFromFloat(@round(v * @as(f64, @floatFromInt(Q97_ONE))));
}
const K_Q = qConst(1.230174105); // even (low) scale
const TWO_INVK_Q = qConst(1.625732422); // odd (high) scale (decoder quirk)
const NDELTA_Q = qConst(-0.443506852); // -delta (even update)
const NGAMMA_Q = qConst(-0.882911075); // -gamma (odd predict)
const NBETA_Q = qConst(0.052980118); // -beta  (even update)
const NALPHA_Q = qConst(1.586134342); // -alpha (odd predict)

/// Fixed-point fractional bits used by the 9/7 path (Q16).
pub const FP_Q: u6 = Q97;
pub const FP_ONE: i64 = Q97_ONE;

/// Build a Q16 constant from a float literal (comptime only).
pub fn fpConst(comptime v: f64) i64 {
    return qConst(v);
}

/// (a · c) >> Q with round-half-up (a is Q16, c is a Q16 constant).
pub fn fpMul(a: i64, c: i64) i64 {
    return (a * c + (Q97_ONE >> 1)) >> Q97;
}
const mulQ = fpMul;

/// Round a Q16 fixed-point value to the nearest integer, ties to even
/// (matches lrintf's default rounding).
pub fn fpRound(x: i64) i32 {
    const fl = x >> Q97; // arithmetic floor
    const frac = x - (fl << Q97); // 0..Q97_ONE-1
    const half = Q97_ONE >> 1;
    var r = fl;
    if (frac > half) {
        r += 1;
    } else if (frac == half) {
        if (@mod(fl, 2) != 0) r += 1; // round to even
    }
    return @intCast(r);
}
inline fn sClamp64(a: []const i64, bound: usize, i: isize) i64 {
    const c: usize = if (i < 0) 0 else if (@as(usize, @intCast(i)) >= bound) bound - 1 else @intCast(i);
    return a[2 * c];
}
inline fn dClamp64(a: []const i64, bound: usize, i: isize) i64 {
    const c: usize = if (i < 0) 0 else if (@as(usize, @intCast(i)) >= bound) bound - 1 else @intCast(i);
    return a[2 * c + 1];
}

/// Inverse 9/7 lifting over one line of Q16 fixed-point samples. `line`
/// holds deinterleaved `[low | high]` on input; interleaved spatial
/// (still Q16) on return. cas==0 only (single-tile origin (0,0)).
pub fn idwt97Line(line: []i64, sn: usize, dn: usize, cas: u1, tmp: []i64) void {
    const len = sn + dn;
    if (len == 0) return;
    {
        var k: usize = 0;
        while (k < sn) : (k += 1) tmp[cas + 2 * k] = line[k];
        k = 0;
        while (k < dn) : (k += 1) tmp[(1 - cas) + 2 * k] = line[sn + k];
    }
    // Scale: even (low) ×K, odd (high) ×two_invK.
    {
        var i: usize = 0;
        while (i < sn) : (i += 1) tmp[2 * i] = mulQ(tmp[2 * i], K_Q);
        i = 0;
        while (i < dn) : (i += 1) tmp[2 * i + 1] = mulQ(tmp[2 * i + 1], TWO_INVK_Q);
    }
    if (dn > 0) {
        // δ: S(i) += -delta·(D(i-1)+D(i))
        var i: usize = 0;
        while (i < sn) : (i += 1) {
            const d = dClamp64(tmp, dn, @as(isize, @intCast(i)) - 1) + dClamp64(tmp, dn, @intCast(i));
            tmp[2 * i] += mulQ(d, NDELTA_Q);
        }
        // γ: D(i) += -gamma·(S(i)+S(i+1))
        i = 0;
        while (i < dn) : (i += 1) {
            const sm = sClamp64(tmp, sn, @intCast(i)) + sClamp64(tmp, sn, @as(isize, @intCast(i)) + 1);
            tmp[2 * i + 1] += mulQ(sm, NGAMMA_Q);
        }
        // β: S(i) += -beta·(D(i-1)+D(i))
        i = 0;
        while (i < sn) : (i += 1) {
            const d = dClamp64(tmp, dn, @as(isize, @intCast(i)) - 1) + dClamp64(tmp, dn, @intCast(i));
            tmp[2 * i] += mulQ(d, NBETA_Q);
        }
        // α: D(i) += -alpha·(S(i)+S(i+1))
        i = 0;
        while (i < dn) : (i += 1) {
            const sm = sClamp64(tmp, sn, @intCast(i)) + sClamp64(tmp, sn, @as(isize, @intCast(i)) + 1);
            tmp[2 * i + 1] += mulQ(sm, NALPHA_Q);
        }
    }
    @memcpy(line[0..len], tmp[0..len]);
}

/// Full inverse 9/7 DWT over a Q16 tile buffer (i64), tile origin (0,0).
pub fn idwt97(
    allocator: std.mem.Allocator,
    tile: []i64,
    tile_w: u32,
    image_w: u32,
    image_h: u32,
    num_decomp: u8,
) std.mem.Allocator.Error!void {
    if (num_decomp == 0) return;
    const max_dim = @max(image_w, image_h);
    const tmp = try allocator.alloc(i64, max_dim);
    defer allocator.free(tmp);
    const col = try allocator.alloc(i64, image_h);
    defer allocator.free(col);

    var r: u8 = 1;
    while (r <= num_decomp) : (r += 1) {
        const cur = subbands.resolutionExtent(image_w, image_h, num_decomp, r);
        const prev = subbands.resolutionExtent(image_w, image_h, num_decomp, r - 1);
        const rw = cur.width;
        const rh = cur.height;
        if (rw == 0 or rh == 0) continue;
        const sn_h = prev.width;
        const dn_h = rw - prev.width;
        const sn_v = prev.height;
        const dn_v = rh - prev.height;
        var j: usize = 0;
        while (j < rh) : (j += 1) {
            const base = j * tile_w;
            idwt97Line(tile[base .. base + rw], sn_h, dn_h, 0, tmp);
        }
        var i: usize = 0;
        while (i < rw) : (i += 1) {
            var k: usize = 0;
            while (k < rh) : (k += 1) col[k] = tile[k * tile_w + i];
            idwt97Line(col[0..rh], sn_v, dn_v, 0, tmp);
            k = 0;
            while (k < rh) : (k += 1) tile[k * tile_w + i] = col[k];
        }
    }
}

test "idwt97Line: identity-ish — all-zero stays zero, single low sample passes K scale" {
    var line = [_]i64{Q97_ONE}; // value 1.0 in Q16, single low sample
    var tmp = [_]i64{0};
    idwt97Line(&line, 1, 0, 0, &tmp);
    // dn==0 → only the K scale applies to the lone low sample.
    try std.testing.expectEqual(mulQ(Q97_ONE, K_Q), line[0]);
}
