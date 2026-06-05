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

test "CtxIdx values match OpenJPEG t1.h offsets" {
    // Compile-time sanity that group boundaries align with
    // OpenJPEG's macros — cross-reference will stay sane.
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(CtxIdx.zc_0));
    try std.testing.expectEqual(@as(u8, 9), @intFromEnum(CtxIdx.sc_0));
    try std.testing.expectEqual(@as(u8, 14), @intFromEnum(CtxIdx.mr_0));
    try std.testing.expectEqual(@as(u8, 17), @intFromEnum(CtxIdx.rlc));
    try std.testing.expectEqual(@as(u8, 18), @intFromEnum(CtxIdx.uniform));
}
