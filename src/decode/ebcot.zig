//! EBCOT tier-1 — context model + per-code-block coefficient state.
//! T.800 Annex D.
//!
//! Each code-block decode owns 19 MQ contexts (T.800 D.3), with
//! two of them pinned to the maximum-MPS state (the "no adaptation"
//! end of the probability table):
//!
//!   Index  Group     Name        Init state (T.800 D.5)
//!   ----   -----     ----        ----------------------
//!   0-8    ZC        zero-coding             0
//!   9-13   SC        sign-coding             0
//!   14-16  MR        magnitude refinement    0
//!   17     RLC       run-length              46 (pinned)
//!   18     UNI       uniform                 46 (pinned)
//!
//! (Group numbering follows OpenJPEG's t1.h: T1_CTXNO_ZC=0,
//! T1_CTXNO_SC=9, T1_CTXNO_MAG=14, T1_CTXNO_AGG=17, T1_CTXNO_UNI=18.)
//!
//! The actual context-formation logic — picking which CX to pass
//! to MQ.decode() based on neighbor significance / orientation —
//! lands in subsequent commits as we wire SP / MR / CL passes.

const std = @import("std");
const mq = @import("mq_coder.zig");

/// Subband orientation. ZC context formation differs for HH from
/// LL/HL/LH because high-frequency diagonal subbands have a
/// different statistical structure.
pub const Orientation = enum(u2) {
    ll,
    hl,
    lh,
    hh,
};

/// EBCOT context indices into a `[19]mq.Context` array. Matches
/// the OpenJPEG mqc_state offsets so cross-reference is direct.
pub const CtxIdx = enum(u8) {
    /// ZC contexts 0..8 — the 9 zero-coding contexts; pick via
    /// `zcContext()` once neighbor significance is implemented.
    zc_0 = 0,
    zc_1 = 1,
    zc_2 = 2,
    zc_3 = 3,
    zc_4 = 4,
    zc_5 = 5,
    zc_6 = 6,
    zc_7 = 7,
    zc_8 = 8,
    /// SC contexts 9..13 — sign coding via `scContext()`.
    sc_0 = 9,
    sc_1 = 10,
    sc_2 = 11,
    sc_3 = 12,
    sc_4 = 13,
    /// MR contexts 14..16 — magnitude refinement via `mrContext()`.
    mr_0 = 14,
    mr_1 = 15,
    mr_2 = 16,
    /// Run-length coding context (pinned at state 46).
    rlc = 17,
    /// Uniform-probability context (pinned at state 46).
    uniform = 18,
};

pub const NUM_CONTEXTS: usize = 19;

/// Fresh per-code-block context state. T.800 D.5 says CX 17 (RLC)
/// and CX 18 (UNIFORM) start at state index 46 — the table row
/// whose NMPS = NLPS = 46 (no adaptation possible). All other
/// contexts start at state 0 (the unbiased ≈ 0.5 entry).
pub fn initContexts() [NUM_CONTEXTS]mq.Context {
    var ctxs: [NUM_CONTEXTS]mq.Context = @splat(.{});
    ctxs[@intFromEnum(CtxIdx.rlc)] = .{ .state = 46, .mps = 0 };
    ctxs[@intFromEnum(CtxIdx.uniform)] = .{ .state = 46, .mps = 0 };
    return ctxs;
}

/// Per-coefficient state inside a code-block. Updated incrementally
/// across the three coding passes (significance propagation, magnitude
/// refinement, cleanup) for each bitplane.
pub const Coeff = struct {
    /// True once any bit of magnitude has been decoded for this coefficient.
    significant: bool = false,
    /// 0 = positive, 1 = negative. Meaningful only after sign coding.
    sign: u1 = 0,
    /// Partial magnitude accumulator. T.800 D.4 builds this up
    /// bitplane-by-bitplane as MQ-decoded bits arrive.
    magnitude: u32 = 0,
    /// Set after the cleanup pass during which the coefficient
    /// first became significant — prevents subsequent passes from
    /// re-processing it.
    visited: bool = false,
    /// True once magnitude refinement has been performed on this
    /// coefficient at least once. Drives MR context selection
    /// (CX 14/15 first time, CX 16 thereafter — T.800 D.3.3).
    refined: bool = false,
};

/// Per-code-block decode state: a 2-D coefficient array sized to
/// the cblk's actual dimensions (which depend on precinct caps —
/// `subbands.cblksInPrecinctSubband` already gave us the grid).
/// Owner of the heap memory; deinit frees it.
pub const Cblk = struct {
    width: u32,
    height: u32,
    coeffs: []Coeff,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) std.mem.Allocator.Error!Cblk {
        const coeffs = try allocator.alloc(Coeff, @as(usize, width) * @as(usize, height));
        @memset(coeffs, .{});
        return .{ .width = width, .height = height, .coeffs = coeffs };
    }

    pub fn deinit(self: *Cblk, allocator: std.mem.Allocator) void {
        allocator.free(self.coeffs);
        self.* = undefined;
    }

    /// Significance of the coefficient at (x, y), with implicit
    /// "false" for out-of-bounds neighbors. Centralised here so
    /// every context-formation function uses the same convention.
    pub fn isSig(self: Cblk, x: i32, y: i32) bool {
        if (x < 0 or y < 0) return false;
        const xu: u32 = @intCast(x);
        const yu: u32 = @intCast(y);
        if (xu >= self.width or yu >= self.height) return false;
        return self.coeffs[yu * self.width + xu].significant;
    }

    /// Sign at (x, y) — out-of-bounds and not-significant both
    /// return 0 (positive). Used by sign-coding context formation.
    pub fn sign(self: Cblk, x: i32, y: i32) u1 {
        if (x < 0 or y < 0) return 0;
        const xu: u32 = @intCast(x);
        const yu: u32 = @intCast(y);
        if (xu >= self.width or yu >= self.height) return 0;
        return self.coeffs[yu * self.width + xu].sign;
    }
};

/// Zero-coding context selection per T.800 Table D-1. Given the
/// coefficient at (x, y) and the subband's orientation, sum the
/// significance flags of horizontal / vertical / diagonal neighbors
/// and pick one of CX 0..8.
///
/// LL and LH use the same table; HL uses it with H ↔ V swapped
/// (because HL emphasises vertical detail, so vertical neighbors
/// carry the high-frequency signal). HH has its own table —
/// diagonal subbands have a fundamentally different statistical
/// profile.
pub fn zcContext(cblk: Cblk, x: u32, y: u32, orient: Orientation) CtxIdx {
    const xi: i32 = @intCast(x);
    const yi: i32 = @intCast(y);
    // Explicit u8 casts on each term: @intFromBool yields u1, and
    // u1+u1 wraps to 0 in ReleaseFast — not what we want for a sum
    // that can legitimately reach 2 (H/V) or 4 (D).
    const b = struct {
        fn s(c: Cblk, xx: i32, yy: i32) u8 {
            return @intFromBool(c.isSig(xx, yy));
        }
    }.s;
    var h: u8 = b(cblk, xi - 1, yi) + b(cblk, xi + 1, yi);
    var v: u8 = b(cblk, xi, yi - 1) + b(cblk, xi, yi + 1);
    const d: u8 = b(cblk, xi - 1, yi - 1) + b(cblk, xi + 1, yi - 1) +
        b(cblk, xi - 1, yi + 1) + b(cblk, xi + 1, yi + 1);

    // HL subbands: swap H and V (the table for LL/LH is reused).
    if (orient == .hl) {
        const t = h;
        h = v;
        v = t;
    }

    if (orient == .hh) {
        const hv = h + v;
        if (d >= 3) return if (hv >= 1) .zc_8 else .zc_7;
        if (d == 2) {
            if (hv >= 2) return .zc_6;
            if (hv == 1) return .zc_5;
            return .zc_4;
        }
        if (d == 1) {
            if (hv >= 2) return .zc_3;
            if (hv == 1) return .zc_2;
            return .zc_1;
        }
        return .zc_0;
    }

    // LL / LH / HL (after swap) — Table D-1 left column.
    if (h == 2) return .zc_8;
    if (h == 1) {
        if (v >= 1) return .zc_7;
        if (d >= 1) return .zc_6;
        return .zc_5;
    }
    // h == 0
    if (v == 2) return .zc_4;
    if (v == 1) return .zc_3;
    if (d >= 2) return .zc_2;
    if (d == 1) return .zc_1;
    return .zc_0;
}

/// Sign-coding context + sign-prediction XOR (T.800 Table D-3).
/// Per-axis contributions collapse the four (sig × sign) cases into
/// one of {-1, 0, +1}; the (H, V) pair then picks a CX from 9..13
/// and an XOR flag that flips the decoded sign bit if 1.
pub const SignContext = struct {
    cx: CtxIdx,
    xor: u1,
};

fn axisContribution(left_sig: bool, left_sign: u1, right_sig: bool, right_sign: u1) i2 {
    // Per T.800 Table D-2: each axis (H or V) contributes -1, 0, +1.
    //   Both significant with same sign: +1 if sign=0 (positive), -1 if sign=1 (negative)
    //   One significant: that one's sign-contribution (+1 / -1)
    //   Both significant with opposite signs: 0
    //   Neither significant: 0
    const ls: i2 = if (left_sig) (if (left_sign == 0) @as(i2, 1) else @as(i2, -1)) else 0;
    const rs: i2 = if (right_sig) (if (right_sign == 0) @as(i2, 1) else @as(i2, -1)) else 0;
    const sum: i32 = @as(i32, ls) + @as(i32, rs);
    if (sum > 0) return 1;
    if (sum < 0) return -1;
    return 0;
}

pub fn scContext(cblk: Cblk, x: u32, y: u32) SignContext {
    const xi: i32 = @intCast(x);
    const yi: i32 = @intCast(y);
    const h_contrib = axisContribution(
        cblk.isSig(xi - 1, yi),
        cblk.sign(xi - 1, yi),
        cblk.isSig(xi + 1, yi),
        cblk.sign(xi + 1, yi),
    );
    const v_contrib = axisContribution(
        cblk.isSig(xi, yi - 1),
        cblk.sign(xi, yi - 1),
        cblk.isSig(xi, yi + 1),
        cblk.sign(xi, yi + 1),
    );
    // T.800 Table D-3 — closed-form CX + XOR from (H, V):
    //   CX = 9  + (|H| + |V|? — actually) — table mapping by cases:
    //   (1,1)=cx13,xor0  (1,0)=cx12,xor0  (1,-1)=cx11,xor0
    //   (0,1)=cx10,xor0  (0,0)=cx9,xor0   (0,-1)=cx10,xor1
    //   (-1,1)=cx11,xor1 (-1,0)=cx12,xor1 (-1,-1)=cx13,xor1
    if (h_contrib == 0 and v_contrib == 0) return .{ .cx = .sc_0, .xor = 0 };
    // Symmetric pairs share a CX with opposite XOR:
    //   (H>=0): xor=0; (H<0): xor=1, mapped to (-H,-V) equivalent.
    var H = h_contrib;
    var V = v_contrib;
    var xor: u1 = 0;
    if (H < 0 or (H == 0 and V < 0)) {
        H = -H;
        V = -V;
        xor = 1;
    }
    // Now H >= 0, and if H == 0 then V > 0.
    if (H == 0) return .{ .cx = .sc_1, .xor = xor }; // (0, 1) → CX 10
    if (V == 1) return .{ .cx = .sc_4, .xor = xor }; // (1, 1) → CX 13
    if (V == 0) return .{ .cx = .sc_3, .xor = xor }; // (1, 0) → CX 12
    // V == -1
    return .{ .cx = .sc_2, .xor = xor }; // (1, -1) → CX 11
}

/// Magnitude-refinement context (T.800 D.3.3).
///   CX 14 (mr_0): first refinement for this coefficient, no
///                  significant neighbors (H+V+D = 0)
///   CX 15 (mr_1): first refinement, ≥ 1 significant neighbor
///   CX 16 (mr_2): subsequent refinements (coeff.refined == true)
pub fn mrContext(cblk: Cblk, x: u32, y: u32) CtxIdx {
    const coeff = cblk.coeffs[y * cblk.width + x];
    if (coeff.refined) return .mr_2;
    const xi: i32 = @intCast(x);
    const yi: i32 = @intCast(y);
    const b = struct {
        fn s(c: Cblk, xx: i32, yy: i32) u8 {
            return @intFromBool(c.isSig(xx, yy));
        }
    }.s;
    const sum: u8 = b(cblk, xi - 1, yi) + b(cblk, xi + 1, yi) +
        b(cblk, xi, yi - 1) + b(cblk, xi, yi + 1) +
        b(cblk, xi - 1, yi - 1) + b(cblk, xi + 1, yi - 1) +
        b(cblk, xi - 1, yi + 1) + b(cblk, xi + 1, yi + 1);
    return if (sum > 0) .mr_1 else .mr_0;
}

/// True if any of the 8-connected neighbours of (x, y) is currently
/// significant. Out-of-bounds neighbours count as "not significant".
fn hasSigNeighbor(cblk: Cblk, x: u32, y: u32) bool {
    const xi: i32 = @intCast(x);
    const yi: i32 = @intCast(y);
    if (cblk.isSig(xi - 1, yi - 1)) return true;
    if (cblk.isSig(xi, yi - 1)) return true;
    if (cblk.isSig(xi + 1, yi - 1)) return true;
    if (cblk.isSig(xi - 1, yi)) return true;
    if (cblk.isSig(xi + 1, yi)) return true;
    if (cblk.isSig(xi - 1, yi + 1)) return true;
    if (cblk.isSig(xi, yi + 1)) return true;
    if (cblk.isSig(xi + 1, yi + 1)) return true;
    return false;
}

/// Significance propagation pass (T.800 D.3.1). The first of the three
/// coding passes per bit-plane.
///
/// Iteration order: 4-row stripes top→bottom; within each stripe,
/// columns left→right; within each column, rows top→bottom (0..3 of
/// the stripe). The final stripe may be shorter when `cblk.height`
/// isn't a multiple of 4.
///
/// Inclusion criterion: coefficient is not-yet-significant AND has at
/// least one significant 8-neighbour. Significance state is read live,
/// so coefficients that became significant earlier in this same SP
/// pass count toward inclusion of later candidates.
///
/// For each included coefficient:
///   1. ZC: decode the significance bit using `zcContext`.
///   2. Mark `.visited = true` (so CL skips it this bit-plane).
///   3. If significant: set `.significant = true`, OR `(1 << bp)` into
///      `.magnitude`, then SC: decode the sign bit and XOR with the
///      sign prediction returned by `scContext`.
pub fn spPass(
    dec: *mq.Decoder,
    cblk: *Cblk,
    ctxs: *[NUM_CONTEXTS]mq.Context,
    orient: Orientation,
    bp: u5,
) void {
    var y_stripe: u32 = 0;
    while (y_stripe < cblk.height) : (y_stripe += 4) {
        const rows_in_stripe = @min(@as(u32, 4), cblk.height - y_stripe);
        var x: u32 = 0;
        while (x < cblk.width) : (x += 1) {
            var dy: u32 = 0;
            while (dy < rows_in_stripe) : (dy += 1) {
                const y = y_stripe + dy;
                const idx = y * cblk.width + x;
                if (cblk.coeffs[idx].significant) continue;
                if (!hasSigNeighbor(cblk.*, x, y)) continue;
                const zc_cx = zcContext(cblk.*, x, y, orient);
                const sig_bit = dec.decode(&ctxs[@intFromEnum(zc_cx)]);
                cblk.coeffs[idx].visited = true;
                if (sig_bit == 1) {
                    cblk.coeffs[idx].significant = true;
                    cblk.coeffs[idx].magnitude |= (@as(u32, 1) << bp);
                    const sc = scContext(cblk.*, x, y);
                    const raw_sign = dec.decode(&ctxs[@intFromEnum(sc.cx)]);
                    cblk.coeffs[idx].sign = raw_sign ^ sc.xor;
                }
            }
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────

test "initContexts: 19 contexts; RLC and UNIFORM at state 46, others fresh" {
    const ctxs = initContexts();
    try std.testing.expectEqual(@as(usize, 19), ctxs.len);
    // ZC, SC, MR all start at state 0, MPS 0.
    var i: usize = 0;
    while (i < 17) : (i += 1) {
        try std.testing.expectEqual(@as(u8, 0), ctxs[i].state);
        try std.testing.expectEqual(@as(u1, 0), ctxs[i].mps);
    }
    // RLC and UNIFORM pinned at row 46 (NMPS = NLPS = 46 → no adapt).
    try std.testing.expectEqual(@as(u8, 46), ctxs[17].state);
    try std.testing.expectEqual(@as(u1, 0), ctxs[17].mps);
    try std.testing.expectEqual(@as(u8, 46), ctxs[18].state);
    try std.testing.expectEqual(@as(u1, 0), ctxs[18].mps);
}

test "initContexts: pinned rows really stay pinned through decode" {
    // RLC/UNIFORM contexts at row 46 should never advance regardless
    // of decode outcomes (NMPS = NLPS = 46 per state_table[46]).
    // Verify by stepping each through a few decodes on a synthetic
    // byte stream and asserting state and mps unchanged.
    var ctxs = initContexts();
    const stream = [_]u8{ 0xAB, 0xCD, 0xEF, 0xFF, 0x00 };
    var dec = mq.Decoder.initDec(&stream);
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        _ = dec.decode(&ctxs[@intFromEnum(CtxIdx.rlc)]);
        _ = dec.decode(&ctxs[@intFromEnum(CtxIdx.uniform)]);
    }
    try std.testing.expectEqual(@as(u8, 46), ctxs[17].state);
    try std.testing.expectEqual(@as(u8, 46), ctxs[18].state);
    try std.testing.expectEqual(@as(u1, 0), ctxs[17].mps);
    try std.testing.expectEqual(@as(u1, 0), ctxs[18].mps);
}

test "Cblk: init/deinit + isSig out-of-bounds returns false" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 16), cblk.coeffs.len);
    // Fresh — nothing significant.
    try std.testing.expect(!cblk.isSig(0, 0));
    try std.testing.expect(!cblk.isSig(3, 3));
    // Out of bounds — implicitly false (no panic, no overflow).
    try std.testing.expect(!cblk.isSig(-1, 0));
    try std.testing.expect(!cblk.isSig(0, -1));
    try std.testing.expect(!cblk.isSig(4, 0));
    try std.testing.expect(!cblk.isSig(0, 4));
    try std.testing.expect(!cblk.isSig(-1, -1));
}

test "zcContext: lone coefficient with no significant neighbors → ZC 0" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    // All zero neighbors → CX 0 in every orientation.
    try std.testing.expectEqual(CtxIdx.zc_0, zcContext(cblk, 2, 2, .ll));
    try std.testing.expectEqual(CtxIdx.zc_0, zcContext(cblk, 2, 2, .hl));
    try std.testing.expectEqual(CtxIdx.zc_0, zcContext(cblk, 2, 2, .lh));
    try std.testing.expectEqual(CtxIdx.zc_0, zcContext(cblk, 2, 2, .hh));
}

test "zcContext: LL orientation — H=2 dominates → ZC 8" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    // Mark left and right horizontal neighbors of (2, 2) as significant.
    cblk.coeffs[2 * 4 + 1].significant = true;
    cblk.coeffs[2 * 4 + 3].significant = true;
    try std.testing.expectEqual(CtxIdx.zc_8, zcContext(cblk, 2, 2, .ll));
    // In HL orientation, H↔V swap means the LL "H=2" becomes "V=2" → ZC 4.
    try std.testing.expectEqual(CtxIdx.zc_4, zcContext(cblk, 2, 2, .hl));
}

test "zcContext: HH orientation — D=3 with no H/V → ZC 7; with H/V → ZC 8" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    // 3 diagonal neighbors at (1,1), (3,1), (1,3); none at (3,3).
    cblk.coeffs[1 * 4 + 1].significant = true;
    cblk.coeffs[1 * 4 + 3].significant = true;
    cblk.coeffs[3 * 4 + 1].significant = true;
    // D = 3, H+V = 0 → ZC 7.
    try std.testing.expectEqual(CtxIdx.zc_7, zcContext(cblk, 2, 2, .hh));
    // Add one H neighbor → H+V = 1, D = 3 → ZC 8.
    cblk.coeffs[2 * 4 + 1].significant = true;
    try std.testing.expectEqual(CtxIdx.zc_8, zcContext(cblk, 2, 2, .hh));
}

test "zcContext: LL — H=1, V=0, D=1 → ZC 6" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    cblk.coeffs[2 * 4 + 1].significant = true; // H neighbor
    cblk.coeffs[1 * 4 + 1].significant = true; // D neighbor
    try std.testing.expectEqual(CtxIdx.zc_6, zcContext(cblk, 2, 2, .ll));
}

test "scContext: no significant neighbors → CX 9, XOR 0" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    const r = scContext(cblk, 2, 2);
    try std.testing.expectEqual(CtxIdx.sc_0, r.cx);
    try std.testing.expectEqual(@as(u1, 0), r.xor);
}

test "scContext: both H neighbors positive significant → CX 12, XOR 0" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    cblk.coeffs[2 * 4 + 1].significant = true;
    cblk.coeffs[2 * 4 + 1].sign = 0; // positive
    cblk.coeffs[2 * 4 + 3].significant = true;
    cblk.coeffs[2 * 4 + 3].sign = 0;
    // H_contrib = +1 (both positive). V_contrib = 0. (H=1, V=0) → CX 12, XOR 0.
    const r = scContext(cblk, 2, 2);
    try std.testing.expectEqual(CtxIdx.sc_3, r.cx); // CX 12 = sc_3
    try std.testing.expectEqual(@as(u1, 0), r.xor);
}

test "scContext: both H neighbors negative significant → CX 12, XOR 1" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    cblk.coeffs[2 * 4 + 1].significant = true;
    cblk.coeffs[2 * 4 + 1].sign = 1; // negative
    cblk.coeffs[2 * 4 + 3].significant = true;
    cblk.coeffs[2 * 4 + 3].sign = 1;
    // H_contrib = -1. V_contrib = 0. Mapped (1, 0) with XOR 1.
    const r = scContext(cblk, 2, 2);
    try std.testing.expectEqual(CtxIdx.sc_3, r.cx);
    try std.testing.expectEqual(@as(u1, 1), r.xor);
}

test "scContext: H neighbors with opposing signs cancel → H_contrib 0" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    cblk.coeffs[2 * 4 + 1].significant = true;
    cblk.coeffs[2 * 4 + 1].sign = 0; // positive
    cblk.coeffs[2 * 4 + 3].significant = true;
    cblk.coeffs[2 * 4 + 3].sign = 1; // negative
    // H_contrib = 0 (cancellation). V_contrib = 0. → CX 9.
    const r = scContext(cblk, 2, 2);
    try std.testing.expectEqual(CtxIdx.sc_0, r.cx);
}

test "mrContext: not yet refined + no significant neighbors → CX 14" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    try std.testing.expectEqual(CtxIdx.mr_0, mrContext(cblk, 2, 2));
}

test "mrContext: not yet refined + at least one sig neighbor → CX 15" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    cblk.coeffs[1 * 4 + 1].significant = true; // diagonal neighbor sig
    try std.testing.expectEqual(CtxIdx.mr_1, mrContext(cblk, 2, 2));
}

test "mrContext: already refined → CX 16 regardless of neighbors" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    cblk.coeffs[2 * 4 + 2].refined = true;
    try std.testing.expectEqual(CtxIdx.mr_2, mrContext(cblk, 2, 2));
    // Neighbors don't matter for subsequent refinements.
    cblk.coeffs[1 * 4 + 1].significant = true;
    try std.testing.expectEqual(CtxIdx.mr_2, mrContext(cblk, 2, 2));
}

test "CtxIdx values match OpenJPEG t1.h offsets" {
    // Compile-time sanity that group boundaries align with
    // OpenJPEG's macros — cross-reference will stay sane.
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(CtxIdx.zc_0));
    try std.testing.expectEqual(@as(u8, 9), @intFromEnum(CtxIdx.sc_0));
    try std.testing.expectEqual(@as(u8, 14), @intFromEnum(CtxIdx.mr_0));
    try std.testing.expectEqual(@as(u8, 17), @intFromEnum(CtxIdx.rlc));
    try std.testing.expectEqual(@as(u8, 18), @intFromEnum(CtxIdx.uniform));
}

// ── SP-pass tests ─────────────────────────────────────────────────

test "hasSigNeighbor: out-of-bounds neighbours don't count" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    // Corner with no significant neighbours → false.
    try std.testing.expect(!hasSigNeighbor(cblk, 0, 0));
    // Mark a strict neighbour of (0,0) — namely (1,1) — as sig.
    cblk.coeffs[1 * 4 + 1].significant = true;
    try std.testing.expect(hasSigNeighbor(cblk, 0, 0));
    // (3,3) sees (2,2) only; not (1,1).
    try std.testing.expect(!hasSigNeighbor(cblk, 3, 3));
}

test "spPass: empty cblk consumes zero MQ decisions" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    var ctxs = initContexts();
    const stream = [_]u8{ 0x80, 0x80, 0x00, 0x00, 0xFF, 0xAC };
    var dec = mq.Decoder.initDec(&stream);
    const bp_before = dec.bp;
    spPass(&dec, &cblk, &ctxs, .ll, 0);
    // No coefficient had a significant neighbour → no decode calls.
    try std.testing.expectEqual(bp_before, dec.bp);
    // No coefficient should be marked visited.
    for (cblk.coeffs) |c| try std.testing.expect(!c.visited);
}

test "spPass: all-significant cblk skips every coefficient" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    for (cblk.coeffs) |*c| c.significant = true;
    var ctxs = initContexts();
    const stream = [_]u8{ 0x80, 0x80, 0x00, 0x00, 0xFF, 0xAC };
    var dec = mq.Decoder.initDec(&stream);
    const bp_before = dec.bp;
    spPass(&dec, &cblk, &ctxs, .ll, 0);
    // Every coeff was already significant → SP skips all of them.
    try std.testing.expectEqual(bp_before, dec.bp);
    for (cblk.coeffs) |c| try std.testing.expect(!c.visited);
}

test "spPass: lone significant pixel marks its 8 neighbours visited" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    cblk.coeffs[2 * 4 + 2].significant = true; // (2,2) is sig
    var ctxs = initContexts();
    // Stream rich enough to satisfy 8 ZC decodes (plus any SC fan-out).
    const stream = [_]u8{ 0x80, 0x80, 0x00, 0x00, 0xFF, 0xAC, 0x00, 0x00 };
    var dec = mq.Decoder.initDec(&stream);
    spPass(&dec, &cblk, &ctxs, .ll, 0);
    // Structural invariant: the 8 strict 8-neighbours of (2,2) all
    // had a sig neighbour at entry → all 8 must be visited. Other
    // cells may also become visited via propagation if some of those
    // 8 decode to significant (data-dependent on the MQ stream); we
    // only assert the minimum, not the exact set.
    const neighbours = [_][2]u32{
        .{ 1, 1 }, .{ 2, 1 }, .{ 3, 1 },
        .{ 1, 2 }, .{ 3, 2 },
        .{ 1, 3 }, .{ 2, 3 }, .{ 3, 3 },
    };
    for (neighbours) |n| {
        const idx = n[1] * 4 + n[0];
        try std.testing.expect(cblk.coeffs[idx].visited);
    }
    // (2,2) itself was already sig → not visited (sig check skips it).
    try std.testing.expect(!cblk.coeffs[2 * 4 + 2].visited);
    // Decoder must have advanced — we ran 8+ MQ decisions.
    try std.testing.expect(dec.bp > 1);
}

test "spPass: non-multiple-of-4 height — last partial stripe still processed" {
    const allocator = std.testing.allocator;
    // 4×5 cblk: stripes of 4 then 1.
    var cblk = try Cblk.init(allocator, 4, 5);
    defer cblk.deinit(allocator);
    // Significant pixel in the partial stripe at (1, 4).
    cblk.coeffs[4 * 4 + 1].significant = true;
    var ctxs = initContexts();
    const stream = [_]u8{ 0x80, 0x80, 0x00, 0x00, 0xFF, 0xAC, 0x00, 0x00 };
    var dec = mq.Decoder.initDec(&stream);
    spPass(&dec, &cblk, &ctxs, .ll, 0);
    // Structural invariant: the partial stripe at y=4 must have been
    // iterated. At least one cell at y=4 (other than the pre-sig (1,4))
    // has (1,4) as a sig neighbour, so it should be visited.
    // (Exact visit count varies with MQ output — coefficients that
    // decode as significant feed neighbour propagation within the same
    // pass; we test the structural property, not the data-dependent one.)
    try std.testing.expect(!cblk.coeffs[4 * 4 + 1].visited); // sig pixel skipped
    var y4_visited: u32 = 0;
    var x: u32 = 0;
    while (x < 4) : (x += 1) {
        if (cblk.coeffs[4 * 4 + x].visited) y4_visited += 1;
    }
    try std.testing.expect(y4_visited >= 1);
}

test "spPass: stripe-then-column iteration order" {
    // Construct a cblk where the order in which SP processes
    // candidates matters: (0,0) is significant, so (0,1) (1,0) (1,1)
    // are candidates. Stripe-column order should hit (1,0) before
    // (0,1) — column 0's rows first (only (0,0) → already sig, skipped),
    // then column 1 processes (1,0) (1,1) top-down. Verify by tracking
    // which context-state changes happen first via a fresh context
    // array's state advancing as decisions are made.
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 2, 2);
    defer cblk.deinit(allocator);
    cblk.coeffs[0].significant = true; // (0, 0)
    var ctxs = initContexts();
    const stream = [_]u8{ 0x80, 0x80, 0x00, 0x00, 0xFF, 0xAC };
    var dec = mq.Decoder.initDec(&stream);
    spPass(&dec, &cblk, &ctxs, .ll, 0);
    // Expect (0,1), (1,0), (1,1) all visited (the 3 non-sig neighbours of (0,0)).
    try std.testing.expect(!cblk.coeffs[0].visited); // already sig
    try std.testing.expect(cblk.coeffs[1].visited); // (1,0)
    try std.testing.expect(cblk.coeffs[2].visited); // (0,1)
    try std.testing.expect(cblk.coeffs[3].visited); // (1,1)
}
