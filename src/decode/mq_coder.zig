//! MQ arithmetic coder — DECODE side. T.800 Annex C.
//!
//! The MQ coder is the binary entropy coder underneath EBCOT
//! (T.800 Annex D). Each code-block's compressed bits are
//! decoded one decision at a time against one of 19 contexts;
//! the contexts maintain adaptive probability state via the
//! Qe / NMPS / NLPS / SWITCH state table (T.800 Table C-2).
//!
//! This module implements the bare coder — INITDEC, DECODE,
//! BYTEIN, RENORMD, MPS_EXCHANGE, LPS_EXCHANGE. The 19 EBCOT
//! contexts and bit-plane state machine live in tier-1 code
//! (`src/decode/tier1.zig`, landing as M3 progresses).
//!
//! Reference: ITU-T Rec. T.800 Annex C. Cross-checked against
//! OpenJPEG's mqc.c — the byte-perfect oracle. No openjpeg code
//! is copied or translated; this is a fresh implementation
//! against the spec.

const std = @import("std");

/// One row of T.800 Table C-2: probability + transitions.
pub const StateEntry = struct {
    /// Probability estimate (16-bit fractional, scaled so 0x8000 = 0.5).
    qe: u16,
    /// State index after MPS decoded ("more probable symbol").
    nmps: u8,
    /// State index after LPS decoded ("less probable symbol").
    nlps: u8,
    /// Switch flag: when LPS is decoded and SWITCH = 1, MPS flips.
    switch_mps: u1,
};

/// T.800 Table C-2 — the 47-entry probability state machine.
/// Index 0 is the initial state for every context (Qe = 0x5601 ≈ 0.5);
/// indices 1..45 climb the probability ladder; index 46 is the
/// reserved "all MPS, no further refinement" anchor for the
/// fixed-probability contexts (CX = 9 = "uniform" and 10 = "run-length").
pub const state_table = [_]StateEntry{
    .{ .qe = 0x5601, .nmps = 1, .nlps = 1, .switch_mps = 1 },
    .{ .qe = 0x3401, .nmps = 2, .nlps = 6, .switch_mps = 0 },
    .{ .qe = 0x1801, .nmps = 3, .nlps = 9, .switch_mps = 0 },
    .{ .qe = 0x0ac1, .nmps = 4, .nlps = 12, .switch_mps = 0 },
    .{ .qe = 0x0521, .nmps = 5, .nlps = 29, .switch_mps = 0 },
    .{ .qe = 0x0221, .nmps = 38, .nlps = 33, .switch_mps = 0 },
    .{ .qe = 0x5601, .nmps = 7, .nlps = 6, .switch_mps = 1 },
    .{ .qe = 0x5401, .nmps = 8, .nlps = 14, .switch_mps = 0 },
    .{ .qe = 0x4801, .nmps = 9, .nlps = 14, .switch_mps = 0 },
    .{ .qe = 0x3801, .nmps = 10, .nlps = 14, .switch_mps = 0 },
    .{ .qe = 0x3001, .nmps = 11, .nlps = 17, .switch_mps = 0 },
    .{ .qe = 0x2401, .nmps = 12, .nlps = 18, .switch_mps = 0 },
    .{ .qe = 0x1c01, .nmps = 13, .nlps = 20, .switch_mps = 0 },
    .{ .qe = 0x1601, .nmps = 29, .nlps = 21, .switch_mps = 0 },
    .{ .qe = 0x5601, .nmps = 15, .nlps = 14, .switch_mps = 1 },
    .{ .qe = 0x5401, .nmps = 16, .nlps = 14, .switch_mps = 0 },
    .{ .qe = 0x5101, .nmps = 17, .nlps = 15, .switch_mps = 0 },
    .{ .qe = 0x4801, .nmps = 18, .nlps = 16, .switch_mps = 0 },
    .{ .qe = 0x3801, .nmps = 19, .nlps = 17, .switch_mps = 0 },
    .{ .qe = 0x3401, .nmps = 20, .nlps = 18, .switch_mps = 0 },
    .{ .qe = 0x3001, .nmps = 21, .nlps = 19, .switch_mps = 0 },
    .{ .qe = 0x2801, .nmps = 22, .nlps = 19, .switch_mps = 0 },
    .{ .qe = 0x2401, .nmps = 23, .nlps = 20, .switch_mps = 0 },
    .{ .qe = 0x2201, .nmps = 24, .nlps = 21, .switch_mps = 0 },
    .{ .qe = 0x1c01, .nmps = 25, .nlps = 22, .switch_mps = 0 },
    .{ .qe = 0x1801, .nmps = 26, .nlps = 23, .switch_mps = 0 },
    .{ .qe = 0x1601, .nmps = 27, .nlps = 24, .switch_mps = 0 },
    .{ .qe = 0x1401, .nmps = 28, .nlps = 25, .switch_mps = 0 },
    .{ .qe = 0x1201, .nmps = 29, .nlps = 26, .switch_mps = 0 },
    .{ .qe = 0x1101, .nmps = 30, .nlps = 27, .switch_mps = 0 },
    .{ .qe = 0x0ac1, .nmps = 31, .nlps = 28, .switch_mps = 0 },
    .{ .qe = 0x09c1, .nmps = 32, .nlps = 29, .switch_mps = 0 },
    .{ .qe = 0x08a1, .nmps = 33, .nlps = 30, .switch_mps = 0 },
    .{ .qe = 0x0521, .nmps = 34, .nlps = 31, .switch_mps = 0 },
    .{ .qe = 0x0441, .nmps = 35, .nlps = 32, .switch_mps = 0 },
    .{ .qe = 0x02a1, .nmps = 36, .nlps = 33, .switch_mps = 0 },
    .{ .qe = 0x0221, .nmps = 37, .nlps = 34, .switch_mps = 0 },
    .{ .qe = 0x0141, .nmps = 38, .nlps = 35, .switch_mps = 0 },
    .{ .qe = 0x0111, .nmps = 39, .nlps = 36, .switch_mps = 0 },
    .{ .qe = 0x0085, .nmps = 40, .nlps = 37, .switch_mps = 0 },
    .{ .qe = 0x0049, .nmps = 41, .nlps = 38, .switch_mps = 0 },
    .{ .qe = 0x0025, .nmps = 42, .nlps = 39, .switch_mps = 0 },
    .{ .qe = 0x0015, .nmps = 43, .nlps = 40, .switch_mps = 0 },
    .{ .qe = 0x0009, .nmps = 44, .nlps = 41, .switch_mps = 0 },
    .{ .qe = 0x0005, .nmps = 45, .nlps = 42, .switch_mps = 0 },
    .{ .qe = 0x0001, .nmps = 45, .nlps = 43, .switch_mps = 0 },
    .{ .qe = 0x5601, .nmps = 46, .nlps = 46, .switch_mps = 0 },
};

comptime {
    std.debug.assert(state_table.len == 47);
}

/// Per-context probability state. A context's `state` indexes into
/// `state_table` and `mps` is the bit-value currently considered
/// "more probable." EBCOT uses 19 contexts (CX = 0..18); each
/// code-block resets them to fresh state at decode start.
pub const Context = struct {
    state: u8 = 0,
    mps: u1 = 0,
};

/// MQ arithmetic decoder state. One instance per code-block decode.
/// Initialise with `initDec(data)`; pull bits with `decode(&context)`.
///
/// Internal registers per T.800 Annex C:
///   C (32-bit)  — interval-position register; high 16 bits are
///                 the "chigh" the spec compares against Qe.
///   A (16-bit)  — interval-width register; renormalised whenever
///                 the high bit clears.
///   CT (u8)     — count of unconsumed bits in C from the byte
///                 stream.
///   bp / end    — byte pointer + one-past-end into the input slice.
pub const Decoder = struct {
    data: []const u8,
    bp: usize,
    end: usize,
    c: u32,
    a: u16,
    ct: u8,
    /// Count of BYTEIN calls that ran past the end of the segment data
    /// (synthesised 0xFF). Normal MQ termination (T.800 C.3.4) synthesises a
    /// bounded tail as the coder drains: <=4 (2 INITDEC pre-load + <=2 final-
    /// renorm byteins; observed valid max 3 — b1_mono/p0_04). deepValidate flags
    /// >4 as truncated/over-read (T.800 / openjpeg end_of_byte_stream_counter —
    /// openjpeg only checks this under PTERM; jp2z exposes it for strict
    /// validation always).
    end_of_stream_count: u32 = 0,

    /// T.800 C.3.5 INITDEC: prime the registers from the first two
    /// bytes (with BYTEIN handling the 0xFF stuffing on the second).
    pub fn initDec(data: []const u8) Decoder {
        var dec: Decoder = .{
            .data = data,
            .bp = 0,
            .end = data.len,
            .c = if (data.len > 0) @as(u32, data[0]) << 16 else @as(u32, 0xFF) << 16,
            .a = 0,
            .ct = 0,
        };
        dec.byteIn();
        dec.c <<= 7;
        // ct >= 7 always after BYTEIN, so the subtract never underflows.
        dec.ct -= 7;
        dec.a = 0x8000;
        return dec;
    }

    /// T.800 C.3.4 BYTEIN. Pulls the next byte (or 0xFF stuffing-marker
    /// fallback) into C; sets CT to 8 (or 7 when the current byte is
    /// 0xFF and the next is "real" data, i.e. high bit clear).
    fn byteIn(self: *Decoder) void {
        if (self.bp >= self.end) self.end_of_stream_count +%= 1;
        const cur_byte: u8 = if (self.bp < self.end) self.data[self.bp] else 0xFF;
        const next_byte: u8 = if (self.bp + 1 < self.end) self.data[self.bp + 1] else 0xFF;
        if (cur_byte == 0xFF) {
            if (next_byte > 0x8F) {
                // Marker code follows — synthesise the "all-ones" tail
                // that lets DECODE finish cleanly without consuming it.
                self.c +%= 0xFF00;
                self.ct = 8;
            } else {
                self.bp += 1;
                self.c +%= @as(u32, next_byte) << 9;
                self.ct = 7;
            }
        } else {
            self.bp += 1;
            self.c +%= @as(u32, next_byte) << 8;
            self.ct = 8;
        }
    }

    /// T.800 C.3.2 RENORMD. After every decoded decision whose
    /// interval-width drops below 0x8000, double A and C until the
    /// high bit of A is set again; pull bytes via BYTEIN when CT
    /// runs out.
    fn renormD(self: *Decoder) void {
        while (true) {
            if (self.ct == 0) self.byteIn();
            self.a <<= 1;
            self.c <<= 1;
            self.ct -= 1;
            if ((self.a & 0x8000) != 0) break;
        }
    }

    /// T.800 C.3.2 DECODE — one binary decision against the given
    /// context. Updates both decoder state and the context's
    /// probability index / MPS direction.
    pub fn decode(self: *Decoder, cx: *Context) u1 {
        const s = &state_table[cx.state];
        const qe: u32 = s.qe;
        self.a -%= @intCast(qe);
        const chigh = self.c >> 16;
        var d: u1 = undefined;
        if (chigh < qe) {
            d = self.lpsExchange(cx, s);
            self.renormD();
        } else {
            self.c -%= qe << 16;
            if ((self.a & 0x8000) == 0) {
                d = self.mpsExchange(cx, s);
                self.renormD();
            } else {
                d = cx.mps;
            }
        }
        return d;
    }

    fn lpsExchange(self: *Decoder, cx: *Context, s: *const StateEntry) u1 {
        const qe_u16: u16 = @intCast(s.qe);
        var d: u1 = undefined;
        if (self.a < qe_u16) {
            // A is smaller than Qe — decoded symbol is MPS (the "exchange").
            self.a = qe_u16;
            d = cx.mps;
            cx.state = s.nmps;
        } else {
            self.a = qe_u16;
            d = ~cx.mps;
            if (s.switch_mps == 1) cx.mps = ~cx.mps;
            cx.state = s.nlps;
        }
        return d;
    }

    fn mpsExchange(self: *Decoder, cx: *Context, s: *const StateEntry) u1 {
        var d: u1 = undefined;
        const qe_u16: u16 = @intCast(s.qe);
        if (self.a < qe_u16) {
            // A < Qe: conditional exchange — the LESS probable symbol is
            // actually decoded (T.800 Figure C-17, "A < Qe" branch).
            d = ~cx.mps;
            if (s.switch_mps == 1) cx.mps = ~cx.mps;
            cx.state = s.nlps;
        } else {
            d = cx.mps;
            cx.state = s.nmps;
        }
        return d;
    }
};

/// RAW / "bypass" bit decoder for selective arithmetic-coding bypass
/// (cblksty bit 0, T.800 Annex D / "LAZY" mode). In bypass, the
/// significance-propagation and magnitude-refinement passes below
/// bit-plane (numbps-4) are coded as plain bits instead of MQ. Bits are
/// read MSB-first; after a 0xFF byte the next byte carries only 7 bits
/// (the top bit is a stuffed 0), and a 0xFF followed by >0x8F is a
/// terminating marker that synthesises all-ones. Mirrors OpenJPEG's
/// opj_mqc_raw_init_dec / opj_mqc_raw_decode (cross-reference only).
pub const RawDecoder = struct {
    data: []const u8,
    bp: usize,
    end: usize,
    c: u8,
    ct: u8,
    /// Past-end byte fetches (truncated/over-read raw segment). See
    /// Decoder.end_of_stream_count.
    end_of_stream_count: u32 = 0,

    pub fn initDec(data: []const u8) RawDecoder {
        return .{ .data = data, .bp = 0, .end = data.len, .c = 0, .ct = 0 };
    }

    /// Read the next raw bit (MSB-first, with 0xFF bit-stuffing).
    pub fn decode(self: *RawDecoder) u1 {
        if (self.ct == 0) {
            if (self.bp >= self.end) self.end_of_stream_count +%= 1;
            if (self.c == 0xFF) {
                // Byte following a 0xFF: >0x8F is a marker (synthesise
                // 0xFF, no advance); otherwise it carries only 7 bits.
                const nb: u8 = if (self.bp < self.end) self.data[self.bp] else 0xFF;
                if (nb > 0x8F) {
                    self.c = 0xFF;
                    self.ct = 8;
                } else {
                    self.c = nb;
                    self.bp += 1;
                    self.ct = 7;
                }
            } else {
                self.c = if (self.bp < self.end) self.data[self.bp] else 0xFF;
                self.bp += 1;
                self.ct = 8;
            }
        }
        self.ct -= 1;
        return @intCast((self.c >> @intCast(self.ct)) & 1);
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "Decoder.initDec: registers seeded per T.800 C.3.5" {
    // Smoke test against a tiny synthetic byte stream. The spec
    // says A = 0x8000 unconditionally; CT lands at 1 (= 8 - 7)
    // for non-0xFF first bytes; C-high carries the first byte
    // shifted, plus contributions from the second byte after
    // BYTEIN + the 7-bit left shift.
    const stream = [_]u8{ 0xAB, 0xCD, 0xEF };
    const dec = Decoder.initDec(&stream);
    try std.testing.expectEqual(@as(u16, 0x8000), dec.a);
    try std.testing.expectEqual(@as(u8, 1), dec.ct);
    try std.testing.expect(dec.bp == 1); // BYTEIN advanced past 0xCD
}

test "Decoder.initDec: empty input synthesises 0xFF byte, doesn't crash" {
    // Defensive: spec doesn't define behaviour for length-0 input
    // (real cblks always have at least 1 byte) but we should not
    // out-of-bounds-read or panic.
    const dec = Decoder.initDec(&[_]u8{});
    try std.testing.expectEqual(@as(u16, 0x8000), dec.a);
}

test "Decoder.decode: deterministic known-answer on an all-0xFF stream" {
    // An all-0xFF input is the degenerate "all stuffing markers" case. A
    // correct decoder still runs without arithmetic/bounds panics and is
    // deterministic; on this particular input it decodes 64 consecutive
    // 1-bits against a fresh context (sum == 64). This is a regression
    // lock, NOT the primary correctness check — that is the byte-perfect
    // differential test against OpenJPEG on a1_mono.j2c (tests/unit/validate.zig).
    const stream = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    var dec = Decoder.initDec(&stream);
    var cx: Context = .{};
    var sum: u32 = 0;
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        sum += dec.decode(&cx);
    }
    try std.testing.expectEqual(@as(u32, 64), sum);
}


// ── Tests ──────────────────────────────────────────────────────────

test "state_table: 47 entries (T.800 Table C-2 row count)" {
    try std.testing.expectEqual(@as(usize, 47), state_table.len);
}

test "state_table: row 0 is the initial-state for every fresh context" {
    // T.800 C.2.4: every context initialises to state 0, MPS = 0,
    // Qe ≈ 0.5 (so the first decision is unbiased). NMPS = NLPS = 1
    // because the first decode immediately moves off the "fresh"
    // state regardless of outcome; SWITCH = 1 means the LPS path
    // flips the context's MPS bit (since fresh contexts have no
    // committed direction).
    const s = state_table[0];
    try std.testing.expectEqual(@as(u16, 0x5601), s.qe);
    try std.testing.expectEqual(@as(u8, 1), s.nmps);
    try std.testing.expectEqual(@as(u8, 1), s.nlps);
    try std.testing.expectEqual(@as(u1, 1), s.switch_mps);
}

test "state_table: row 46 is the fixed-probability anchor (UNIFORM / RLC contexts)" {
    // EBCOT context 9 (UNIFORM, used for sign coding) and 10 (RLC,
    // used for cleanup-pass run-length signalling) bypass adaptation
    // and pin state index 46. NMPS = NLPS = 46 means "stay here."
    const s = state_table[46];
    try std.testing.expectEqual(@as(u16, 0x5601), s.qe);
    try std.testing.expectEqual(@as(u8, 46), s.nmps);
    try std.testing.expectEqual(@as(u8, 46), s.nlps);
    try std.testing.expectEqual(@as(u1, 0), s.switch_mps);
}

test "state_table: probabilities decrease monotonically along the MPS ladder (rows 1..13)" {
    // Following the MPS-only path from row 1 should yield strictly
    // decreasing Qe — the encoder's confidence in MPS grows.
    var i: usize = 1;
    while (i < 13) : (i += 1) {
        const cur = state_table[i].qe;
        const next = state_table[state_table[i].nmps].qe;
        try std.testing.expect(next < cur or i == state_table[i].nmps);
    }
}

test "state_table: row 5 LPS transition jumps to 33 (the fast-adapt path)" {
    // Spot-check a non-obvious transition. Row 5 has NLPS = 33, the
    // jump that lets the coder rapidly re-estimate after an
    // unexpected LPS bit early in adaptation.
    try std.testing.expectEqual(@as(u8, 33), state_table[5].nlps);
}

test "RawDecoder: MSB-first bits, no stuffing" {
    // 0xB4 = 1011_0100 → bits MSB-first.
    var dec = RawDecoder.initDec(&[_]u8{0xB4});
    const expect = [_]u1{ 1, 0, 1, 1, 0, 1, 0, 0 };
    for (expect) |e| try std.testing.expectEqual(e, dec.decode());
}

test "RawDecoder: 0xFF stuffing — next byte carries only 7 bits" {
    // 0xFF → eight 1-bits. Then (after 0xFF) 0x40=0100_0000, not >0x8F,
    // so it carries 7 bits (positions 6..0): 1,0,0,0,0,0,0.
    var dec = RawDecoder.initDec(&[_]u8{ 0xFF, 0x40 });
    const expect = [_]u1{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0 };
    for (expect) |e| try std.testing.expectEqual(e, dec.decode());
}

test "RawDecoder: past-end synthesises 0xFF (all ones)" {
    var dec = RawDecoder.initDec(&[_]u8{0x00});
    // First 8 bits are 0 (0x00), then past-end → 0xFF → ones.
    var i: u32 = 0;
    while (i < 8) : (i += 1) try std.testing.expectEqual(@as(u1, 0), dec.decode());
    try std.testing.expectEqual(@as(u1, 1), dec.decode());
}

test "Decoder.end_of_stream_count: truncated data forces many synthesized 0xFF" {
    // A 1-byte stream decoded far past its content must synthesize many
    // past-end 0xFF markers — the over-read / truncation signal.
    var dec = Decoder.initDec(&[_]u8{0x00});
    var cx: Context = .{};
    var i: u32 = 0;
    while (i < 64) : (i += 1) _ = dec.decode(&cx);
    try std.testing.expect(dec.end_of_stream_count > 2);
}

test "Decoder.end_of_stream_count: ample data needs no past-end synthesis" {
    // Plenty of bytes for a handful of decodes → no past-end reads.
    var dec = Decoder.initDec(&[_]u8{ 0x80, 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01, 0x00 });
    var cx: Context = .{};
    var i: u32 = 0;
    while (i < 4) : (i += 1) _ = dec.decode(&cx);
    try std.testing.expectEqual(@as(u32, 0), dec.end_of_stream_count);
}
