//! MQ arithmetic ENCODER (the production coder since 2026-10-23), written
//! from the T.800 Annex C flowcharts (CODELPS, CODEMPS, RENORME, BYTEOUT,
//! FLUSH with SETBITS; the same coder as T.88). It shares nothing with the
//! decoder in decode/mq_coder.zig: the Qe table is typed here from Table
//! C-2, so a round-trip failure points at whichever side disagrees with the
//! standard. It began as a test-only encoder for the termination tests
//! (tests/unit/validate.zig, through jp2z.internal.mq_encoder), which
//! still use it.
//!
//! Byte output follows the flowcharts literally: `B` is the pending byte at
//! `BP`, "BP = BP + 1; B = x" appends, and the byte before the first output
//! byte is a sentinel that is never emitted. A carry into the sentinel is
//! impossible for a fresh encoder (CT = 12 with C = 0) and is reported as an
//! error rather than hidden.
const std = @import("std");

pub const Qe = struct { qe: u16, nmps: u8, nlps: u8, switch_mps: u1 };

/// T.800 Table C-2 (identical to T.88 Table E.1): 47 probability states.
pub const qe_table = [47]Qe{
    .{ .qe = 0x5601, .nmps = 1, .nlps = 1, .switch_mps = 1 },
    .{ .qe = 0x3401, .nmps = 2, .nlps = 6, .switch_mps = 0 },
    .{ .qe = 0x1801, .nmps = 3, .nlps = 9, .switch_mps = 0 },
    .{ .qe = 0x0AC1, .nmps = 4, .nlps = 12, .switch_mps = 0 },
    .{ .qe = 0x0521, .nmps = 5, .nlps = 29, .switch_mps = 0 },
    .{ .qe = 0x0221, .nmps = 38, .nlps = 33, .switch_mps = 0 },
    .{ .qe = 0x5601, .nmps = 7, .nlps = 6, .switch_mps = 1 },
    .{ .qe = 0x5401, .nmps = 8, .nlps = 14, .switch_mps = 0 },
    .{ .qe = 0x4801, .nmps = 9, .nlps = 14, .switch_mps = 0 },
    .{ .qe = 0x3801, .nmps = 10, .nlps = 14, .switch_mps = 0 },
    .{ .qe = 0x3001, .nmps = 11, .nlps = 17, .switch_mps = 0 },
    .{ .qe = 0x2401, .nmps = 12, .nlps = 18, .switch_mps = 0 },
    .{ .qe = 0x1C01, .nmps = 13, .nlps = 20, .switch_mps = 0 },
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
    .{ .qe = 0x1C01, .nmps = 25, .nlps = 22, .switch_mps = 0 },
    .{ .qe = 0x1801, .nmps = 26, .nlps = 23, .switch_mps = 0 },
    .{ .qe = 0x1601, .nmps = 27, .nlps = 24, .switch_mps = 0 },
    .{ .qe = 0x1401, .nmps = 28, .nlps = 25, .switch_mps = 0 },
    .{ .qe = 0x1201, .nmps = 29, .nlps = 26, .switch_mps = 0 },
    .{ .qe = 0x1101, .nmps = 30, .nlps = 27, .switch_mps = 0 },
    .{ .qe = 0x0AC1, .nmps = 31, .nlps = 28, .switch_mps = 0 },
    .{ .qe = 0x09C1, .nmps = 32, .nlps = 29, .switch_mps = 0 },
    .{ .qe = 0x08A1, .nmps = 33, .nlps = 30, .switch_mps = 0 },
    .{ .qe = 0x0521, .nmps = 34, .nlps = 31, .switch_mps = 0 },
    .{ .qe = 0x0441, .nmps = 35, .nlps = 32, .switch_mps = 0 },
    .{ .qe = 0x02A1, .nmps = 36, .nlps = 33, .switch_mps = 0 },
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

pub const Context = struct { state: u8 = 0, mps: u1 = 0 };

/// T.800 Table D-7 initial states for the 19 EBCOT contexts in jp2z's
/// index order (ZC 0..8, SC 9..13, MR 14..16, RL 17, UNIFORM 18): every
/// context starts at state 0 except ZC context 0 (state 4), RL (state 3)
/// and UNIFORM (state 46).
pub fn initEbcotContexts() [19]Context {
    var ctxs = [_]Context{.{}} ** 19;
    ctxs[0] = .{ .state = 4, .mps = 0 };
    ctxs[17] = .{ .state = 3, .mps = 0 };
    ctxs[18] = .{ .state = 46, .mps = 0 };
    return ctxs;
}

pub const Encoder = struct {
    a: u32,
    c: u32,
    ct: u8,
    /// Pending output byte `B` (valid when `has_b`).
    b: u8,
    has_b: bool,
    out: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    /// INITENC (T.800 Figure C-10 / T.88 INITENC): A = 0x8000, C = 0,
    /// CT = 12, BP one before the first output byte.
    pub fn init(allocator: std.mem.Allocator) Encoder {
        return .{ .a = 0x8000, .c = 0, .ct = 12, .b = 0, .has_b = false, .out = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *Encoder) void {
        self.out.deinit(self.allocator);
    }

    /// CODE one decision `d` in context `cx` (CODEMPS / CODELPS).
    pub fn encode(self: *Encoder, cx: *Context, d: u1) !void {
        const s = qe_table[cx.state];
        const qe: u32 = s.qe;
        if (d == cx.mps) {
            // CODEMPS
            self.a -= qe;
            if ((self.a & 0x8000) == 0) {
                if (self.a < qe) self.a = qe else self.c += qe;
                cx.state = s.nmps;
                try self.renorm();
            } else {
                self.c += qe;
            }
        } else {
            // CODELPS
            self.a -= qe;
            if (self.a < qe) self.c += qe else self.a = qe;
            if (s.switch_mps == 1) cx.mps = ~cx.mps;
            cx.state = s.nlps;
            try self.renorm();
        }
    }

    /// RENORME.
    fn renorm(self: *Encoder) !void {
        while (true) {
            if (self.ct == 0) try self.byteOut();
            self.a <<= 1;
            self.c <<= 1;
            self.ct -= 1;
            if ((self.a & 0x8000) != 0) break;
        }
    }

    /// "BP = BP + 1; B = x": the previous pending byte becomes output.
    fn emitNew(self: *Encoder, x: u8) !void {
        if (self.has_b) try self.out.append(self.allocator, self.b);
        self.b = x;
        self.has_b = true;
    }

    /// The bit-stuffing branch shared by BYTEOUT's two 0xFF cases.
    fn stuff(self: *Encoder) !void {
        try self.emitNew(@intCast((self.c >> 20) & 0xFF));
        self.c &= 0xFFFFF;
        self.ct = 7;
    }

    /// BYTEOUT (T.800 Figure C-8 / T.88 BYTEOUT) with carry propagation.
    fn byteOut(self: *Encoder) !void {
        if (self.has_b and self.b == 0xFF) return self.stuff();
        if (self.c < 0x8000000) {
            try self.emitNew(@intCast((self.c >> 19) & 0xFF));
            self.c &= 0x7FFFF;
            self.ct = 8;
            return;
        }
        // Carry into B.
        if (!self.has_b) return error.CarryIntoSentinel;
        self.b += 1;
        if (self.b == 0xFF) {
            self.c &= 0x7FFFFFF;
            return self.stuff();
        }
        try self.emitNew(@intCast((self.c >> 19) & 0xFF));
        self.c &= 0x7FFFF;
        self.ct = 8;
    }

    /// SETBITS (T.800 Figure C-12 / T.88 SETBITS).
    fn setBits(self: *Encoder) void {
        const tempc: u32 = self.c + self.a;
        self.c |= 0xFFFF;
        if (self.c >= tempc) self.c -= 0x8000;
    }

    /// FLUSH (T.800 Figure C-11): SETBITS, two BYTEOUTs, then the final
    /// pending byte is kept unless it is 0xFF, which is discarded. Returns
    /// the complete coder output; the caller owns the slice.
    pub fn flush(self: *Encoder) ![]u8 {
        self.setBits();
        self.c <<= @intCast(self.ct);
        try self.byteOut();
        self.c <<= @intCast(self.ct);
        try self.byteOut();
        if (self.has_b and self.b != 0xFF) try self.out.append(self.allocator, self.b);
        self.has_b = false;
        return self.out.toOwnedSlice(self.allocator);
    }

    /// Predictable termination (T.800 D.4.2, cblksty PTERM; the procedure
    /// OpenJPEG implements as opj_mqc_erterm_enc): shift out 12 - CT bits through
    /// BYTEOUT, then move the pending byte into the output unless it is 0xFF.
    /// No SETBITS, so the output is shorter than FLUSH's and the decoder leans
    /// on synthesized 0xFF to finish. Returns the complete coder output.
    pub fn flushPredictable(self: *Encoder) ![]u8 {
        var k: i32 = 11 - @as(i32, self.ct) + 1;
        while (k > 0) {
            self.c <<= @intCast(self.ct);
            self.ct = 0;
            try self.byteOut();
            k -= @as(i32, self.ct);
        }
        if (self.has_b and self.b != 0xFF) try self.out.append(self.allocator, self.b);
        self.has_b = false;
        return self.out.toOwnedSlice(self.allocator);
    }
};
