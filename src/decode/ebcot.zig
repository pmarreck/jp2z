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

test "CtxIdx values match OpenJPEG t1.h offsets" {
    // Compile-time sanity that group boundaries align with
    // OpenJPEG's macros — cross-reference will stay sane.
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(CtxIdx.zc_0));
    try std.testing.expectEqual(@as(u8, 9), @intFromEnum(CtxIdx.sc_0));
    try std.testing.expectEqual(@as(u8, 14), @intFromEnum(CtxIdx.mr_0));
    try std.testing.expectEqual(@as(u8, 17), @intFromEnum(CtxIdx.rlc));
    try std.testing.expectEqual(@as(u8, 18), @intFromEnum(CtxIdx.uniform));
}
