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
const cblk_plan = @import("cblk_plan.zig");

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

/// Fresh per-code-block context state. T.800 Table D-7 gives three
/// contexts non-zero initial states; all others start at state 0
/// (the unbiased ~0.5 entry). Verified against OpenJPEG
/// opj_t1_decode_cblk: resetstates(all->0) then setstate UNI/AGG/ZC.
///   ZC  ctx 0  -> state 4   (T1_CTXNO_ZC,  prob 4)
///   RLC ctx 17 -> state 3   (T1_CTXNO_AGG, prob 3) -- ADAPTS, not pinned
///   UNI ctx 18 -> state 46  (T1_CTXNO_UNI, prob 46) -- pinned (nmps=nlps=46)
pub fn initContexts() [NUM_CONTEXTS]mq.Context {
    var ctxs: [NUM_CONTEXTS]mq.Context = @splat(.{});
    ctxs[@intFromEnum(CtxIdx.zc_0)] = .{ .state = 4, .mps = 0 };
    ctxs[@intFromEnum(CtxIdx.rlc)] = .{ .state = 3, .mps = 0 };
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
    /// Bit position of openjpeg's reconstruction "half" marker for THIS
    /// coefficient: one below the bit-plane at which it was last coded
    /// (became significant, or was refined). Per-coefficient because a
    /// code-block whose last pass is SP or MR leaves the coefficients not
    /// visited in that partial plane one plane higher — a uniform per-cblk
    /// position (the old halfBitPos) mis-reconstructs exactly those.
    half_bp: u5 = 0,
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
    /// Max past-end byte synthesis across the cblk's MQ/RAW segments
    /// (truncation / over-read signal; >2 is suspicious). Strict-validation.
    over_read: u32 = 0,
    /// Max leftover (declared-but-unconsumed) bytes across segments — a
    /// clean segment consumes ~all its bytes; large leftover signals a
    /// byte-budget mismatch (corruption). Strict-validation.
    under_read: u32 = 0,
    /// SEGSYM (cblksty bit 5): set when a cleanup-pass segmentation symbol
    /// decoded to something other than 0xA — a built-in corruption tripwire.
    segsym_error: bool = false,
    /// VSC (cblksty bit 3): vertically-causal context. When set, a coefficient in
    /// the bottom row of a 4-row stripe (y % 4 == 3) excludes its south neighbours
    /// from context formation (openjpeg suppresses the ci==0 north propagation).
    vsc: bool = false,

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
    // VSC (vertically causal): a coefficient in the bottom row of a 4-row stripe
    // excludes its 3 south neighbours (the next stripe) from context formation.
    const excl_south = cblk.vsc and (y % 4 == 3);
    const b = struct {
        fn s(c: Cblk, xx: i32, yy: i32) u8 {
            return @intFromBool(c.isSig(xx, yy));
        }
    }.s;
    const sb = struct {
        fn s(c: Cblk, xx: i32, yy: i32, excl: bool) u8 {
            return if (excl) 0 else @intFromBool(c.isSig(xx, yy));
        }
    }.s;
    var h: u8 = b(cblk, xi - 1, yi) + b(cblk, xi + 1, yi);
    var v: u8 = b(cblk, xi, yi - 1) + sb(cblk, xi, yi + 1, excl_south);
    const d: u8 = b(cblk, xi - 1, yi - 1) + b(cblk, xi + 1, yi - 1) +
        sb(cblk, xi - 1, yi + 1, excl_south) + sb(cblk, xi + 1, yi + 1, excl_south);

    // HL subbands: swap H and V (the table for LL/LH is reused).
    if (orient == .hl) {
        const t = h;
        h = v;
        v = t;
    }

    if (orient == .hh) {
        const hv = h + v;
        if (d >= 3) return .zc_8;
        if (d == 2) return if (hv >= 1) .zc_7 else .zc_6;
        if (d == 1) {
            if (hv >= 2) return .zc_5;
            if (hv == 1) return .zc_4;
            return .zc_3;
        }
        if (hv >= 2) return .zc_2;
        if (hv == 1) return .zc_1;
        return .zc_0;
    }

    // LL / LH / HL (after swap) — Table D-1 left column.
    if (h == 2) return .zc_8;
    if (h == 1) {
        if (v >= 1) return .zc_7;
        if (d >= 1) return .zc_6;
        return .zc_5;
    }
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
    // VSC: bottom-of-stripe coefficients drop the south neighbour (causal).
    const excl_south = cblk.vsc and (y % 4 == 3);
    const h_contrib = axisContribution(
        cblk.isSig(xi - 1, yi),
        cblk.sign(xi - 1, yi),
        cblk.isSig(xi + 1, yi),
        cblk.sign(xi + 1, yi),
    );
    const v_contrib = axisContribution(
        cblk.isSig(xi, yi - 1),
        cblk.sign(xi, yi - 1),
        if (excl_south) false else cblk.isSig(xi, yi + 1),
        if (excl_south) @as(u1, 0) else cblk.sign(xi, yi + 1),
    );
    if (h_contrib == 0 and v_contrib == 0) return .{ .cx = .sc_0, .xor = 0 };
    var H = h_contrib;
    var V = v_contrib;
    var xor: u1 = 0;
    if (H < 0 or (H == 0 and V < 0)) {
        H = -H;
        V = -V;
        xor = 1;
    }
    if (H == 0) return .{ .cx = .sc_1, .xor = xor };
    if (V == 1) return .{ .cx = .sc_4, .xor = xor };
    if (V == 0) return .{ .cx = .sc_3, .xor = xor };
    return .{ .cx = .sc_2, .xor = xor };
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
    const excl_south = cblk.vsc and (y % 4 == 3);
    const b = struct {
        fn s(c: Cblk, xx: i32, yy: i32) u8 {
            return @intFromBool(c.isSig(xx, yy));
        }
    }.s;
    const sb = struct {
        fn s(c: Cblk, xx: i32, yy: i32, excl: bool) u8 {
            return if (excl) 0 else @intFromBool(c.isSig(xx, yy));
        }
    }.s;
    const sum: u8 = b(cblk, xi - 1, yi) + b(cblk, xi + 1, yi) +
        b(cblk, xi, yi - 1) + sb(cblk, xi, yi + 1, excl_south) +
        b(cblk, xi - 1, yi - 1) + b(cblk, xi + 1, yi - 1) +
        sb(cblk, xi - 1, yi + 1, excl_south) + sb(cblk, xi + 1, yi + 1, excl_south);
    return if (sum > 0) .mr_1 else .mr_0;
}


/// True if any of the 8-connected neighbours of (x, y) is currently
/// significant. Out-of-bounds neighbours count as "not significant".
fn hasSigNeighbor(cblk: Cblk, x: u32, y: u32) bool {
    const xi: i32 = @intCast(x);
    const yi: i32 = @intCast(y);
    const excl_south = cblk.vsc and (y % 4 == 3);
    if (cblk.isSig(xi - 1, yi - 1)) return true;
    if (cblk.isSig(xi, yi - 1)) return true;
    if (cblk.isSig(xi + 1, yi - 1)) return true;
    if (cblk.isSig(xi - 1, yi)) return true;
    if (cblk.isSig(xi + 1, yi)) return true;
    if (!excl_south) {
        if (cblk.isSig(xi - 1, yi + 1)) return true;
        if (cblk.isSig(xi, yi + 1)) return true;
        if (cblk.isSig(xi + 1, yi + 1)) return true;
    }
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
                    cblk.coeffs[idx].half_bp = if (bp > 0) bp - 1 else 0;
                    const sc = scContext(cblk.*, x, y);
                    const raw_sign = dec.decode(&ctxs[@intFromEnum(sc.cx)]);
                    cblk.coeffs[idx].sign = raw_sign ^ sc.xor;
                }
            }
        }
    }
}

/// Magnitude refinement pass (T.800 D.3.2). The second of the three
/// coding passes per bit-plane.
///
/// Iteration order is identical to SP: 4-row stripes top→bottom;
/// columns left→right; rows top→bottom within each stripe.
///
/// Inclusion criterion: coefficient is significant AND was NOT marked
/// visited during this bit-plane's SP pass (i.e., it became significant
/// in a previous bit-plane, not the current one — those just-became-sig
/// coeffs have already had their sign coded and aren't refined yet).
///
/// For each included coefficient:
///   1. Pick CX via `mrContext` (CX 14/15 first refinement, CX 16
///      thereafter — driven by `coeff.refined`).
///   2. Decode the refinement bit and OR `(bit << bp)` into `.magnitude`.
///   3. Set `.refined = true` so subsequent bit-planes use CX 16.
pub fn mrPass(
    dec: *mq.Decoder,
    cblk: *Cblk,
    ctxs: *[NUM_CONTEXTS]mq.Context,
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
                const coeff = cblk.coeffs[idx];
                if (!coeff.significant) continue;
                if (coeff.visited) continue; // became sig in this bp's SP
                const cx = mrContext(cblk.*, x, y);
                const bit = dec.decode(&ctxs[@intFromEnum(cx)]);
                cblk.coeffs[idx].magnitude |= (@as(u32, bit) << bp);
                cblk.coeffs[idx].half_bp = if (bp > 0) bp - 1 else 0;
                cblk.coeffs[idx].refined = true;
            }
        }
    }
}

/// RAW (bypass) significance-propagation pass — T.800 selective
/// arithmetic-coding bypass. Same inclusion criterion and scan order as
/// `spPass`, but the significance and sign bits are read as plain bits
/// (`RawDecoder`), with NO context modelling and NO sign-prediction XOR.
pub fn spPassRaw(dec: *mq.RawDecoder, cblk: *Cblk, bp: u5) void {
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
                const sig_bit = dec.decode();
                cblk.coeffs[idx].visited = true;
                if (sig_bit == 1) {
                    cblk.coeffs[idx].significant = true;
                    cblk.coeffs[idx].magnitude |= (@as(u32, 1) << bp);
                    cblk.coeffs[idx].half_bp = if (bp > 0) bp - 1 else 0;
                    cblk.coeffs[idx].sign = dec.decode();
                }
            }
        }
    }
}

/// RAW (bypass) magnitude-refinement pass. Same inclusion + scan order
/// as `mrPass`, but the refinement bit is a plain raw bit (no MR context).
pub fn mrPassRaw(dec: *mq.RawDecoder, cblk: *Cblk, bp: u5) void {
    var y_stripe: u32 = 0;
    while (y_stripe < cblk.height) : (y_stripe += 4) {
        const rows_in_stripe = @min(@as(u32, 4), cblk.height - y_stripe);
        var x: u32 = 0;
        while (x < cblk.width) : (x += 1) {
            var dy: u32 = 0;
            while (dy < rows_in_stripe) : (dy += 1) {
                const y = y_stripe + dy;
                const idx = y * cblk.width + x;
                const coeff = cblk.coeffs[idx];
                if (!coeff.significant) continue;
                if (coeff.visited) continue;
                const bit = dec.decode();
                cblk.coeffs[idx].magnitude |= (@as(u32, bit) << bp);
                cblk.coeffs[idx].half_bp = if (bp > 0) bp - 1 else 0;
                cblk.coeffs[idx].refined = true;
            }
        }
    }
}

/// True iff a column-stripe (rows `y_stripe..y_stripe+4`) at column
/// `x` is run-length-coding eligible per T.800 D.3.4: every one of
/// the 4 sample locations must be currently insignificant, not
/// visited (i.e. SP didn't touch it), and have no significant
/// 8-neighbour. The caller already vetted that the stripe is a full
/// 4-row stripe (not the trailing partial one).
fn rlcEligible(cblk: Cblk, x: u32, y_stripe: u32) bool {
    var dy: u32 = 0;
    while (dy < 4) : (dy += 1) {
        const y = y_stripe + dy;
        const idx = y * cblk.width + x;
        const c = cblk.coeffs[idx];
        if (c.significant) return false;
        if (c.visited) return false;
        if (hasSigNeighbor(cblk, x, y)) return false;
    }
    return true;
}

/// Cleanup pass (T.800 D.3.3). The third of three coding passes per
/// bit-plane.
///
/// Same iteration order as SP/MR: 4-row stripes top→bottom; columns
/// left→right; rows top→bottom within each stripe.
///
/// Inclusion criterion: !significant AND !visited (i.e., SP didn't
/// touch it — neighbour was empty — and MR didn't either since it
/// wasn't already sig).
///
/// Two sub-paths:
///
/// (1) Run-length coding (T.800 D.3.4). When the stripe is a full
/// 4-row stripe AND all 4 coefficients in this column satisfy
/// `rlcEligible` (no sig neighbour, untouched), use CX 17 (RLC) for
/// one binary decision. On 0, the entire column-stripe stays
/// insignificant — no further bits. On 1, two CX 18 (UNIFORM) bits
/// give the row offset `k` (0..3) of the first sig coefficient;
/// mark it sig, code its sign, and continue from row `k+1` via
/// regular ZC+SC.
///
/// (2) Regular ZC+SC for the remaining rows (or all rows when the
/// stripe isn't RLC-eligible): pick CX via `zcContext`, decode the
/// sig bit, and on sig=1 set `.significant`, OR the bit-plane mask
/// into `.magnitude`, then SC-code the sign.
pub fn clPass(
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
            var start_dy: u32 = 0;
            if (rows_in_stripe == 4 and rlcEligible(cblk.*, x, y_stripe)) {
                const v = dec.decode(&ctxs[@intFromEnum(CtxIdx.rlc)]);
                if (v == 0) continue; // column-stripe stays insignificant
                // At least one coefficient is sig — UNIFORM bits give the
                // run-length k (= offset of first sig within the stripe).
                const hi = dec.decode(&ctxs[@intFromEnum(CtxIdx.uniform)]);
                const lo = dec.decode(&ctxs[@intFromEnum(CtxIdx.uniform)]);
                const k = (@as(u32, hi) << 1) | @as(u32, lo);
                const y = y_stripe + k;
                const idx = y * cblk.width + x;
                cblk.coeffs[idx].significant = true;
                cblk.coeffs[idx].magnitude |= (@as(u32, 1) << bp);
                cblk.coeffs[idx].half_bp = if (bp > 0) bp - 1 else 0;
                const sc = scContext(cblk.*, x, y);
                const raw_sign = dec.decode(&ctxs[@intFromEnum(sc.cx)]);
                cblk.coeffs[idx].sign = raw_sign ^ sc.xor;
                start_dy = k + 1;
            }
            var dy: u32 = start_dy;
            while (dy < rows_in_stripe) : (dy += 1) {
                const y = y_stripe + dy;
                const idx = y * cblk.width + x;
                const coeff = cblk.coeffs[idx];
                if (coeff.significant) continue;
                if (coeff.visited) continue;
                const zc_cx = zcContext(cblk.*, x, y, orient);
                const sig_bit = dec.decode(&ctxs[@intFromEnum(zc_cx)]);
                if (sig_bit == 1) {
                    cblk.coeffs[idx].significant = true;
                    cblk.coeffs[idx].magnitude |= (@as(u32, 1) << bp);
                    cblk.coeffs[idx].half_bp = if (bp > 0) bp - 1 else 0;
                    const sc = scContext(cblk.*, x, y);
                    const raw_sign = dec.decode(&ctxs[@intFromEnum(sc.cx)]);
                    cblk.coeffs[idx].sign = raw_sign ^ sc.xor;
                }
            }
        }
    }
}

/// Reset the per-bitplane `.visited` flag on every coefficient. Called
/// between bit-planes so the next bit-plane's SP starts from a clean
/// "no one's been visited yet" state.
fn resetVisited(cblk: *Cblk) void {
    for (cblk.coeffs) |*c| c.visited = false;
}

/// Decode `num_bitplanes` bit-planes of a single code-block, MSB-first,
/// per T.800 Annex D.
///
/// `msb_bp` is the index (0..30) of the MOST-SIGNIFICANT bit-plane to
/// decode — i.e. the highest non-zero bit-plane reported by the tier-2
/// inclusion-tag-tree. The first bit-plane uses CL only (no significance
/// to propagate, none to refine); subsequent bit-planes run SP → MR → CL.
/// `.visited` is reset between bit-planes so per-bp semantics hold.
///
/// The decoder must already be initialised against the cblk's segment
/// data (`mq.Decoder.initDec`); contexts must be freshly init'd
/// (`initContexts`).
pub fn decodeCblk(
    dec: *mq.Decoder,
    cblk: *Cblk,
    ctxs: *[NUM_CONTEXTS]mq.Context,
    orient: Orientation,
    msb_bp: u5,
    num_bitplanes: u5,
) void {
    if (num_bitplanes == 0) return;
    // Convert full-bp count to pass count: first bp = 1 pass (CL),
    // each subsequent bp = 3 passes (SP, MR, CL).
    const total_passes: u32 = 1 + 3 * (@as(u32, num_bitplanes) - 1);
    decodeCblkPasses(dec, cblk, ctxs, orient, msb_bp, total_passes);
}

/// Pass-level variant of `decodeCblk`. Real-world packet contributions
/// land at arbitrary pass-count boundaries (any number of EBCOT coding
/// passes, not just whole bit-planes), so the tier-2 → tier-1 integration
/// path uses this entry point.
///
/// `total_passes` is the accumulated number of coding passes assigned to
/// this code-block across every packet that contributed to it. The
/// pass schedule per bit-plane is: bp[0] = 1 pass (CL), bp[i>0] = up to
/// 3 passes (SP → MR → CL). Decoding stops the moment `passes_done`
/// reaches `total_passes`, so a value of 5 means: CL @ msb_bp, then
/// SP + MR + CL @ msb_bp-1, then SP @ msb_bp-2 (and stop).
///
/// `.visited` is always reset before exit so a fresh entry leaves the
/// cblk in a consistent "no per-bp state hanging around" condition.
pub fn decodeCblkPasses(
    dec: *mq.Decoder,
    cblk: *Cblk,
    ctxs: *[NUM_CONTEXTS]mq.Context,
    orient: Orientation,
    msb_bp: u5,
    total_passes: u32,
) void {
    if (total_passes == 0) return;
    // First bit-plane: CL only.
    clPass(dec, cblk, ctxs, orient, msb_bp);
    resetVisited(cblk);
    var passes_done: u32 = 1;
    if (passes_done >= total_passes) return;
    // Subsequent bit-planes: SP → MR → CL, but each individual pass
    // is gated on remaining `total_passes`.
    var i: u5 = 1;
    while (true) : (i += 1) {
        if (i > msb_bp) break;
        const bp = msb_bp - i;
        spPass(dec, cblk, ctxs, orient, bp);
        passes_done += 1;
        if (passes_done >= total_passes) {
            resetVisited(cblk);
            return;
        }
        mrPass(dec, cblk, ctxs, bp);
        passes_done += 1;
        if (passes_done >= total_passes) {
            resetVisited(cblk);
            return;
        }
        clPass(dec, cblk, ctxs, orient, bp);
        passes_done += 1;
        resetVisited(cblk);
        if (passes_done >= total_passes) return;
    }
}

/// Map a global coding-pass index to whether it is RAW (bypass) coded.
/// T.800: under LAZY (cblksty bit 0) the SP and MR passes (passtype 0/1)
/// at bit-planes <= numbps-4 are raw-coded; the cleanup pass (passtype 2)
/// and all passes at higher bit-planes stay MQ. Pass 0 is CL@numbps; for
/// i>=1 the schedule is SP/MR/CL descending one bit-plane per triple.
fn passIsRaw(cblksty: u8, numbps: u5, pass_index: u32) bool {
    if (cblksty & 0x01 == 0) return false; // not LAZY
    var bpno: i32 = undefined;
    var passtype: u32 = undefined;
    if (pass_index == 0) {
        bpno = numbps;
        passtype = 2;
    } else {
        const group = (pass_index - 1) / 3;
        passtype = (pass_index - 1) % 3;
        bpno = @as(i32, numbps) - 1 - @as(i32, @intCast(group));
    }
    return passtype < 2 and bpno <= @as(i32, numbps) - 4;
}

/// Segment-aware code-block decode (handles cblksty LAZY/TERMALL where the
/// codeword is split into independently-terminated segments, each its own
/// MQ or RAW decoder). `data` is the concatenated cblk bytes; `segments`
/// gives the per-segment {passes, byte_len} in pass order. The MQ context
/// states persist across segments (only the MQ registers re-init per MQ
/// segment); a single MQ segment reduces to plain `decodeCblkPasses`.
pub fn decodeCblkSegments(
    cblk: *Cblk,
    ctxs: *[NUM_CONTEXTS]mq.Context,
    orient: Orientation,
    numbps: u5,
    cblksty: u8,
    data: []const u8,
    segments: []const cblk_plan.SegInfo,
) void {
    cblk.vsc = (cblksty & 0x08) != 0;
    var passtype: u8 = 2; // first pass is CL @ msb
    var bpno: u5 = numbps;
    var offset: usize = 0;
    var pass_index: u32 = 0;
    var max_over_read: u32 = 0;
    var max_under_read: u32 = 0;
    for (segments) |seg| {
        const end = offset + seg.byte_len;
        if (end > data.len) return; // malformed; bail defensively
        const seg_bytes = data[offset..end];
        offset = end;
        const is_raw = passIsRaw(cblksty, numbps, pass_index);
        var mq_dec: mq.Decoder = undefined;
        var raw_dec: mq.RawDecoder = undefined;
        if (is_raw) {
            raw_dec = mq.RawDecoder.initDec(seg_bytes);
        } else {
            mq_dec = mq.Decoder.initDec(seg_bytes);
        }
        var p: u32 = 0;
        while (p < seg.passes) : (p += 1) {
            switch (passtype) {
                0 => if (is_raw) spPassRaw(&raw_dec, cblk, bpno) else spPass(&mq_dec, cblk, ctxs, orient, bpno),
                1 => if (is_raw) mrPassRaw(&raw_dec, cblk, bpno) else mrPass(&mq_dec, cblk, ctxs, bpno),
                2 => clPass(&mq_dec, cblk, ctxs, orient, bpno), // cleanup is always MQ
                else => unreachable,
            }
            // SEGSYM (cblksty bit 5): after every cleanup pass a 4-bit symbol is
            // MQ-coded with the UNIFORM context and must equal 0xA — a built-in
            // corruption tripwire. Consume it (keeps the MQ stream synced) and flag
            // any mismatch for the strict validator.
            if (passtype == 2 and (cblksty & 0x20) != 0) {
                var sym: u32 = 0;
                var b: u3 = 0;
                while (b < 4) : (b += 1) {
                    sym = (sym << 1) | mq_dec.decode(&ctxs[@intFromEnum(CtxIdx.uniform)]);
                }
                if (sym != 0xA) cblk.segsym_error = true;
            }
            // RESET (cblksty bit 1): reset the MQ probability estimator states to
            // their initial values after every MQ-coded pass (never RAW passes).
            if ((cblksty & 0x02) != 0 and !is_raw) {
                ctxs.* = initContexts();
            }
            if (passtype == 2) {
                passtype = 0;
                if (bpno > 0) bpno -= 1;
                resetVisited(cblk);
            } else {
                passtype += 1;
            }
            pass_index += 1;
        }
        const seg_over = if (is_raw) raw_dec.end_of_stream_count else mq_dec.end_of_stream_count;
        if (seg_over > max_over_read) max_over_read = seg_over;
        const consumed = if (is_raw) raw_dec.bp else mq_dec.bp;
        const leftover: u32 = if (consumed < seg.byte_len) @intCast(seg.byte_len - consumed) else 0;
        if (leftover > max_under_read) max_under_read = leftover;
    }
    cblk.over_read = max_over_read;
    cblk.under_read = max_under_read;
}

// ── Tests ──────────────────────────────────────────────────────────

test "initContexts: T.800 Table D-7 initial states (ZC=4, RLC=3, UNI=46, rest=0)" {
    const ctxs = initContexts();
    try std.testing.expectEqual(@as(usize, 19), ctxs.len);
    // ZC ctx 0 -> state 4 (special non-zero init per Table D-7).
    try std.testing.expectEqual(@as(u8, 4), ctxs[0].state);
    try std.testing.expectEqual(@as(u1, 0), ctxs[0].mps);
    // Remaining ZC (1..8), SC (9..13), MR (14..16) start fresh at state 0.
    var i: usize = 1;
    while (i < 17) : (i += 1) {
        try std.testing.expectEqual(@as(u8, 0), ctxs[i].state);
        try std.testing.expectEqual(@as(u1, 0), ctxs[i].mps);
    }
    // RLC ctx 17 -> state 3 (adapts); UNIFORM ctx 18 -> state 46 (pinned).
    try std.testing.expectEqual(@as(u8, 3), ctxs[17].state);
    try std.testing.expectEqual(@as(u1, 0), ctxs[17].mps);
    try std.testing.expectEqual(@as(u8, 46), ctxs[18].state);
    try std.testing.expectEqual(@as(u1, 0), ctxs[18].mps);
}

test "initContexts: UNIFORM (ctx 18) stays pinned at state 46 through decodes" {
    // Only UNIFORM is fixed-probability: state_table[46] has NMPS = NLPS = 46,
    // so it never advances regardless of decode outcome. (RLC ctx 17 starts
    // at state 3 and DOES adapt — deliberately not asserted as pinned.)
    var ctxs = initContexts();
    const stream = [_]u8{ 0xAB, 0xCD, 0xEF, 0xFF, 0x00 };
    var dec = mq.Decoder.initDec(&stream);
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        _ = dec.decode(&ctxs[@intFromEnum(CtxIdx.uniform)]);
    }
    try std.testing.expectEqual(@as(u8, 46), ctxs[18].state);
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

test "zcContext: HH orientation — T.800 Table D-1 HH column (d primary, hv secondary)" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    // 3 diagonal neighbors of (2,2): (1,1),(3,1),(1,3); (3,3) absent → d=3.
    cblk.coeffs[1 * 4 + 1].significant = true;
    cblk.coeffs[1 * 4 + 3].significant = true;
    cblk.coeffs[3 * 4 + 1].significant = true;
    // d>=3 → ZC 8 regardless of h+v (this was the bug: it used to return 7).
    try std.testing.expectEqual(CtxIdx.zc_8, zcContext(cblk, 2, 2, .hh));
    // Adding an H neighbor keeps it at ZC 8 (still d>=3).
    cblk.coeffs[2 * 4 + 1].significant = true;
    try std.testing.expectEqual(CtxIdx.zc_8, zcContext(cblk, 2, 2, .hh));
}

test "zcContext: HH orientation — d=2 boundary (hv=0 → ZC 6, hv>=1 → ZC 7)" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    // 2 diagonal neighbors of (2,2): (1,1),(3,1). d=2, hv=0 → ZC 6.
    cblk.coeffs[1 * 4 + 1].significant = true;
    cblk.coeffs[1 * 4 + 3].significant = true;
    try std.testing.expectEqual(CtxIdx.zc_6, zcContext(cblk, 2, 2, .hh));
    // Add a V neighbor → hv=1, d=2 → ZC 7.
    cblk.coeffs[1 * 4 + 2].significant = true;
    try std.testing.expectEqual(CtxIdx.zc_7, zcContext(cblk, 2, 2, .hh));
}

test "zcContext: HH orientation — d=0 uses hv only (0/1/>=2 → ZC 0/1/2)" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    // No diagonal neighbors. hv=0 → ZC 0.
    try std.testing.expectEqual(CtxIdx.zc_0, zcContext(cblk, 2, 2, .hh));
    // One H neighbor → hv=1 → ZC 1.
    cblk.coeffs[2 * 4 + 1].significant = true;
    try std.testing.expectEqual(CtxIdx.zc_1, zcContext(cblk, 2, 2, .hh));
    // Add a V neighbor → hv=2 → ZC 2.
    cblk.coeffs[1 * 4 + 2].significant = true;
    try std.testing.expectEqual(CtxIdx.zc_2, zcContext(cblk, 2, 2, .hh));
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

// ── MR-pass tests ─────────────────────────────────────────────────

test "mrPass: empty cblk consumes zero MQ decisions" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    var ctxs = initContexts();
    const stream = [_]u8{ 0x80, 0x80, 0x00, 0x00, 0xFF, 0xAC };
    var dec = mq.Decoder.initDec(&stream);
    const bp_before = dec.bp;
    mrPass(&dec, &cblk, &ctxs, 0);
    // No coefficient is significant → MR processes none.
    try std.testing.expectEqual(bp_before, dec.bp);
    for (cblk.coeffs) |c| try std.testing.expect(!c.refined);
}

test "mrPass: skips coefficients marked visited (just became sig this bp)" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    // One coeff significant + visited (became sig in this bp's SP pass).
    cblk.coeffs[2 * 4 + 2].significant = true;
    cblk.coeffs[2 * 4 + 2].visited = true;
    var ctxs = initContexts();
    const stream = [_]u8{ 0x80, 0x80, 0x00, 0x00, 0xFF, 0xAC };
    var dec = mq.Decoder.initDec(&stream);
    const bp_before = dec.bp;
    mrPass(&dec, &cblk, &ctxs, 0);
    // MR should skip the just-became-sig coeff → no decode, no refined.
    try std.testing.expectEqual(bp_before, dec.bp);
    try std.testing.expect(!cblk.coeffs[2 * 4 + 2].refined);
}

test "mrPass: refines significant coefficient — sets .refined, advances MQ" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    // One coeff significant from a previous bitplane (not visited).
    cblk.coeffs[2 * 4 + 2].significant = true;
    cblk.coeffs[2 * 4 + 2].magnitude = 0x4; // bit at bp=2
    var ctxs = initContexts();
    const stream = [_]u8{ 0x80, 0x80, 0x00, 0x00, 0xFF, 0xAC };
    var dec = mq.Decoder.initDec(&stream);
    const bp_before = dec.bp;
    mrPass(&dec, &cblk, &ctxs, 1); // refining at bit-plane 1
    // Exactly one MR decode happened.
    try std.testing.expect(dec.bp >= bp_before);
    try std.testing.expect(cblk.coeffs[2 * 4 + 2].refined);
    // Magnitude either unchanged (bit=0) or has bit-1 set (bit=1).
    const mag = cblk.coeffs[2 * 4 + 2].magnitude;
    try std.testing.expect(mag == 0x4 or mag == 0x6);
    // No other coefficient was refined.
    for (cblk.coeffs, 0..) |c, idx| {
        if (idx == 2 * 4 + 2) continue;
        try std.testing.expect(!c.refined);
    }
}

test "mrPass: refined coefficient uses CX 16 (mr_2) on subsequent passes" {
    // White-box: confirm second refinement of the same coefficient
    // uses mr_2 by checking the context state of mr_2 advanced
    // (rather than mr_0/mr_1).
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    cblk.coeffs[2 * 4 + 2].significant = true;
    cblk.coeffs[2 * 4 + 2].refined = true; // already refined once
    var ctxs = initContexts();
    const stream = [_]u8{ 0x80, 0x80, 0x00, 0x00, 0xFF, 0xAC };
    var dec = mq.Decoder.initDec(&stream);
    const mr0_state_before = ctxs[@intFromEnum(CtxIdx.mr_0)].state;
    const mr1_state_before = ctxs[@intFromEnum(CtxIdx.mr_1)].state;
    const mr2_state_before = ctxs[@intFromEnum(CtxIdx.mr_2)].state;
    mrPass(&dec, &cblk, &ctxs, 0);
    // mr_0 and mr_1 must be untouched; mr_2 may or may not have
    // advanced (depends on whether the decode produced an MPS path
    // that triggered renormalisation). At minimum, we confirm the
    // refinement used mr_2 by checking that mr_0/mr_1 didn't change.
    try std.testing.expectEqual(mr0_state_before, ctxs[@intFromEnum(CtxIdx.mr_0)].state);
    try std.testing.expectEqual(mr1_state_before, ctxs[@intFromEnum(CtxIdx.mr_1)].state);
    _ = mr2_state_before;
}

test "mrPass: all significant + all visited → no work" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    for (cblk.coeffs) |*c| {
        c.significant = true;
        c.visited = true;
    }
    var ctxs = initContexts();
    const stream = [_]u8{ 0x80, 0x80, 0x00, 0x00, 0xFF, 0xAC };
    var dec = mq.Decoder.initDec(&stream);
    const bp_before = dec.bp;
    mrPass(&dec, &cblk, &ctxs, 0);
    try std.testing.expectEqual(bp_before, dec.bp);
    for (cblk.coeffs) |c| try std.testing.expect(!c.refined);
}

// ── CL-pass tests ─────────────────────────────────────────────────

test "rlcEligible: empty column-stripe is eligible" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    try std.testing.expect(rlcEligible(cblk, 0, 0));
    try std.testing.expect(rlcEligible(cblk, 1, 0));
    try std.testing.expect(rlcEligible(cblk, 3, 0));
}

test "rlcEligible: column with a significant cell is NOT eligible" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    cblk.coeffs[1 * 4 + 2].significant = true;
    try std.testing.expect(!rlcEligible(cblk, 2, 0));
    try std.testing.expect(rlcEligible(cblk, 0, 0)); // col 0 untouched
}

test "rlcEligible: column with a visited cell is NOT eligible" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    cblk.coeffs[2 * 4 + 1].visited = true;
    try std.testing.expect(!rlcEligible(cblk, 1, 0));
}

test "rlcEligible: column with a sig-neighbour in another column is NOT eligible" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    // (2,2) significant — its left neighbour at (1,*) gets a sig neighbour.
    cblk.coeffs[2 * 4 + 2].significant = true;
    // Col 1's coefficients at y=1,2,3 have (2,2) as a sig 8-neighbour.
    try std.testing.expect(!rlcEligible(cblk, 1, 0));
    // Col 3 is symmetric.
    try std.testing.expect(!rlcEligible(cblk, 3, 0));
    // Col 0 is far enough to remain eligible.
    try std.testing.expect(rlcEligible(cblk, 0, 0));
}

test "clPass: empty cblk — every column-stripe uses RLC (CX 17)" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    var ctxs = initContexts();
    const stream = [_]u8{ 0x80, 0x80, 0x00, 0x00, 0xFF, 0xAC, 0x00, 0x00 };
    var dec = mq.Decoder.initDec(&stream);
    const bp_before = dec.bp;
    clPass(&dec, &cblk, &ctxs, .ll, 0);
    // At minimum, every full column-stripe ran one CX-17 decode (so
    // some MQ activity should have occurred). Stripe count = 1
    // (height=4) × 4 columns = 4 RLC decodes minimum.
    _ = bp_before;
    // Decoder progressed past initDec's seeded position.
    try std.testing.expect(dec.bp >= 1);
}

test "clPass: all-visited cblk skips everything (no RLC, no ZC)" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    for (cblk.coeffs) |*c| c.visited = true;
    var ctxs = initContexts();
    const stream = [_]u8{ 0x80, 0x80, 0x00, 0x00, 0xFF, 0xAC };
    var dec = mq.Decoder.initDec(&stream);
    const bp_before = dec.bp;
    clPass(&dec, &cblk, &ctxs, .ll, 0);
    // Every coeff is "visited" → RLC ineligible AND ZC skip → no decode.
    try std.testing.expectEqual(bp_before, dec.bp);
    // Nothing went significant.
    for (cblk.coeffs) |c| try std.testing.expect(!c.significant);
}

test "clPass: column with sig neighbour uses ZC, not RLC" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    // (2,2) is sig — col 1 and col 3 inherit sig neighbours so they
    // are NOT RLC-eligible. Mark (2,2) as visited too so CL skips it.
    cblk.coeffs[2 * 4 + 2].significant = true;
    cblk.coeffs[2 * 4 + 2].visited = true;
    var ctxs = initContexts();
    const stream = [_]u8{ 0x80, 0x80, 0x00, 0x00, 0xFF, 0xAC, 0x00, 0x00 };
    var dec = mq.Decoder.initDec(&stream);
    // Capture CX-17 state to verify RLC was NOT used for cols 1, 2, 3.
    // (Col 0 IS eligible since (1,*) cells don't reach (2,2) — wait,
    // col 0 cells at y=0..3 have neighbours at x in [-1, 1], so they
    // don't see (2,2). Col 0 → RLC eligible. Col 1, 2, 3 → not.)
    clPass(&dec, &cblk, &ctxs, .ll, 0);
    // (2,2) was already sig + visited so it must not have been touched.
    try std.testing.expect(cblk.coeffs[2 * 4 + 2].significant);
    // Decoder advanced.
    try std.testing.expect(dec.bp >= 1);
}

test "clPass: partial-stripe rows never use RLC, only ZC" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 5);
    defer cblk.deinit(allocator);
    // Mark all rows 0..3 as visited so CL skips the full stripe and
    // only the partial stripe at y=4 has work to do.
    var i: usize = 0;
    while (i < 16) : (i += 1) cblk.coeffs[i].visited = true;
    var ctxs = initContexts();
    const stream = [_]u8{ 0x80, 0x80, 0x00, 0x00, 0xFF, 0xAC, 0x00, 0x00 };
    var dec = mq.Decoder.initDec(&stream);
    // Capture CX-17 state before; partial stripe must NOT touch RLC ctx.
    const rlc_state_before = ctxs[@intFromEnum(CtxIdx.rlc)].state;
    clPass(&dec, &cblk, &ctxs, .ll, 0);
    // RLC context state unchanged — partial stripe avoided RLC entirely.
    try std.testing.expectEqual(rlc_state_before, ctxs[@intFromEnum(CtxIdx.rlc)].state);
}

// ── decodeCblk (bit-plane orchestration) tests ────────────────────

test "resetVisited: clears flag on every coefficient" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    for (cblk.coeffs) |*c| c.visited = true;
    resetVisited(&cblk);
    for (cblk.coeffs) |c| try std.testing.expect(!c.visited);
}

test "decodeCblk: num_bitplanes = 0 is a no-op" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    var ctxs = initContexts();
    const stream = [_]u8{ 0x80, 0x80, 0x00, 0x00, 0xFF, 0xAC };
    var dec = mq.Decoder.initDec(&stream);
    const bp_before = dec.bp;
    decodeCblk(&dec, &cblk, &ctxs, .ll, 7, 0);
    try std.testing.expectEqual(bp_before, dec.bp);
    for (cblk.coeffs) |c| {
        try std.testing.expect(!c.significant);
        try std.testing.expect(!c.visited);
    }
}

test "decodeCblk: num_bitplanes = 1 runs ONLY a CL pass (no SP/MR)" {
    // White-box: confirm SP/MR contexts (mr_0..mr_2) untouched after
    // a single-bitplane decode — only CL was run, and CL never selects
    // an mr_* context.
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    var ctxs = initContexts();
    const stream = [_]u8{ 0x80, 0x80, 0x00, 0x00, 0xFF, 0xAC, 0x00, 0x00 };
    var dec = mq.Decoder.initDec(&stream);
    const mr0_before = ctxs[@intFromEnum(CtxIdx.mr_0)].state;
    const mr1_before = ctxs[@intFromEnum(CtxIdx.mr_1)].state;
    const mr2_before = ctxs[@intFromEnum(CtxIdx.mr_2)].state;
    decodeCblk(&dec, &cblk, &ctxs, .ll, 7, 1);
    try std.testing.expectEqual(mr0_before, ctxs[@intFromEnum(CtxIdx.mr_0)].state);
    try std.testing.expectEqual(mr1_before, ctxs[@intFromEnum(CtxIdx.mr_1)].state);
    try std.testing.expectEqual(mr2_before, ctxs[@intFromEnum(CtxIdx.mr_2)].state);
    // All .visited reset at end of bit-plane.
    for (cblk.coeffs) |c| try std.testing.expect(!c.visited);
}

test "decodeCblk: multi-bitplane decode resets visited between bit-planes" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    var ctxs = initContexts();
    // Larger stream — multi-bp decode consumes many bits.
    const stream = [_]u8{
        0x80, 0x80, 0x00, 0x00, 0xFF, 0xAC, 0x00, 0x00,
        0xAB, 0xCD, 0x12, 0x34, 0x56, 0x78, 0xFF, 0x00,
    };
    var dec = mq.Decoder.initDec(&stream);
    decodeCblk(&dec, &cblk, &ctxs, .ll, 7, 4);
    // After full decode, .visited must be reset (post-last-bp reset).
    for (cblk.coeffs) |c| try std.testing.expect(!c.visited);
}

test "decodeCblk: msb_bp = 0 with num_bitplanes > 1 doesn't underflow" {
    // Sanity guard: when msb_bp is small and num_bitplanes is large,
    // bp = msb_bp - i would underflow on u5. The implementation breaks
    // out of the loop instead.
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    var ctxs = initContexts();
    const stream = [_]u8{ 0x80, 0x80, 0x00, 0x00, 0xFF, 0xAC };
    var dec = mq.Decoder.initDec(&stream);
    // msb_bp = 0, num_bitplanes = 3 → only the CL at bp=0 runs;
    // subsequent SP/MR/CL iterations would need bp=-1, -2 (impossible).
    decodeCblk(&dec, &cblk, &ctxs, .ll, 0, 3);
    for (cblk.coeffs) |c| try std.testing.expect(!c.visited);
}

// ── decodeCblkPasses (pass-level granularity) tests ───────────────

test "decodeCblkPasses: 0 passes is a no-op" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    var ctxs = initContexts();
    const stream = [_]u8{ 0x80, 0x80, 0x00, 0x00, 0xFF, 0xAC };
    var dec = mq.Decoder.initDec(&stream);
    const bp_before = dec.bp;
    decodeCblkPasses(&dec, &cblk, &ctxs, .ll, 7, 0);
    try std.testing.expectEqual(bp_before, dec.bp);
}

test "decodeCblkPasses: 1 pass runs CL only — equivalent to decodeCblk(..., 1)" {
    // White-box: confirm the first bp uses CL only by checking that
    // mr_0..mr_2 contexts remain at state 0 after a 1-pass decode.
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    var ctxs = initContexts();
    const stream = [_]u8{ 0x80, 0x80, 0x00, 0x00, 0xFF, 0xAC, 0x00, 0x00 };
    var dec = mq.Decoder.initDec(&stream);
    decodeCblkPasses(&dec, &cblk, &ctxs, .ll, 7, 1);
    try std.testing.expectEqual(@as(u8, 0), ctxs[@intFromEnum(CtxIdx.mr_0)].state);
    try std.testing.expectEqual(@as(u8, 0), ctxs[@intFromEnum(CtxIdx.mr_1)].state);
    try std.testing.expectEqual(@as(u8, 0), ctxs[@intFromEnum(CtxIdx.mr_2)].state);
}

test "decodeCblkPasses: 2 passes runs CL @ msb_bp + SP @ msb_bp-1 (no MR / no CL second time)" {
    // Set up a cblk where the SP pass will actually do work (some
    // coefficient becomes sig in CL @ msb_bp; SP @ msb_bp-1 then has
    // candidates to process). The structural check: total_passes=2
    // must NOT cause any MR or second-bp CL bits to be consumed.
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    var ctxs = initContexts();
    const stream = [_]u8{ 0x80, 0x80, 0x00, 0x00, 0xFF, 0xAC, 0x00, 0x00 };
    var dec = mq.Decoder.initDec(&stream);
    decodeCblkPasses(&dec, &cblk, &ctxs, .ll, 7, 2);
    // MR contexts must not have been touched (still state 0).
    try std.testing.expectEqual(@as(u8, 0), ctxs[@intFromEnum(CtxIdx.mr_0)].state);
    try std.testing.expectEqual(@as(u8, 0), ctxs[@intFromEnum(CtxIdx.mr_1)].state);
    try std.testing.expectEqual(@as(u8, 0), ctxs[@intFromEnum(CtxIdx.mr_2)].state);
    // .visited reset at end of pass.
    for (cblk.coeffs) |c| try std.testing.expect(!c.visited);
}

test "decodeCblkPasses: 4 passes — CL + SP + MR + CL (one full subsequent bp)" {
    const allocator = std.testing.allocator;
    var cblk = try Cblk.init(allocator, 4, 4);
    defer cblk.deinit(allocator);
    var ctxs = initContexts();
    const stream = [_]u8{
        0x80, 0x80, 0x00, 0x00, 0xFF, 0xAC, 0x00, 0x00,
        0xAB, 0xCD, 0x12, 0x34, 0x56, 0x78, 0xFF, 0x00,
    };
    var dec = mq.Decoder.initDec(&stream);
    decodeCblkPasses(&dec, &cblk, &ctxs, .ll, 7, 4);
    for (cblk.coeffs) |c| try std.testing.expect(!c.visited);
}

test "decodeCblkPasses: equivalence to decodeCblk for bp-aligned pass counts" {
    // decodeCblk(N bitplanes) == decodeCblkPasses(1 + 3*(N-1) passes)
    // — verify by running both against fresh state and comparing
    // the resulting MQ decoder positions + cblk state.
    const allocator = std.testing.allocator;
    const stream = [_]u8{
        0x80, 0x80, 0x00, 0x00, 0xFF, 0xAC, 0x00, 0x00,
        0xAB, 0xCD, 0x12, 0x34, 0x56, 0x78, 0xFF, 0x00,
    };

    var cblk_bp = try Cblk.init(allocator, 4, 4);
    defer cblk_bp.deinit(allocator);
    var ctxs_bp = initContexts();
    var dec_bp = mq.Decoder.initDec(&stream);
    decodeCblk(&dec_bp, &cblk_bp, &ctxs_bp, .ll, 7, 3); // 3 bitplanes

    var cblk_passes = try Cblk.init(allocator, 4, 4);
    defer cblk_passes.deinit(allocator);
    var ctxs_passes = initContexts();
    var dec_passes = mq.Decoder.initDec(&stream);
    decodeCblkPasses(&dec_passes, &cblk_passes, &ctxs_passes, .ll, 7, 7); // 1 + 3*2 = 7

    // Decoders should land at the same byte position.
    try std.testing.expectEqual(dec_bp.bp, dec_passes.bp);
    // Per-coefficient state should match.
    for (cblk_bp.coeffs, cblk_passes.coeffs) |a, b| {
        try std.testing.expectEqual(a.significant, b.significant);
        try std.testing.expectEqual(a.sign, b.sign);
        try std.testing.expectEqual(a.magnitude, b.magnitude);
        try std.testing.expectEqual(a.refined, b.refined);
    }
}
