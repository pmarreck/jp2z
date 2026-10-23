//! Tier-1 EBCOT encoding (T.800 Annex D): the significance-propagation,
//! magnitude-refinement and cleanup passes over one code-block, coded with
//! the MQ encoder into a single segment terminated by FLUSH (code-block
//! style 0). Every decision mirrors the decoder in decode/ebcot.zig, and the
//! context formation is the decoder's own (zcContext, scContext, mrContext,
//! run-length eligibility) applied to the same code-block state, so the two
//! sides cannot drift apart silently: the tests decode each encoded block
//! with the decoder and require every coefficient back exactly.

const std = @import("std");
const ebcot = @import("../decode/ebcot.zig");
const mqe = @import("mq_encoder.zig");

pub const Encoded = struct {
    /// MQ-coded bytes for all passes (one FLUSH-terminated segment). Owned.
    data: []u8,
    /// Magnitude bit-planes coded: bit length of the largest magnitude.
    numbps: u8,
    /// Coding passes in `data`: 3 * numbps - 2, or 0 for an all-zero block.
    passes: u32,

    pub fn deinit(self: *Encoded, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }
};

/// Encode a `width × height` code-block of quantized coefficients given as
/// magnitudes and signs (row-major, sign 1 = negative), for a subband of
/// orientation `orient`, coding every pass of every bit-plane.
pub fn encodeCblk(
    allocator: std.mem.Allocator,
    mags: []const u32,
    signs: []const u1,
    width: u32,
    height: u32,
    orient: ebcot.Orientation,
) !Encoded {
    std.debug.assert(mags.len == @as(usize, width) * height and signs.len == mags.len);
    var max: u32 = 0;
    for (mags) |m| max = @max(max, m);
    if (max == 0) return .{ .data = try allocator.alloc(u8, 0), .numbps = 0, .passes = 0 };
    const numbps: u8 = @intCast(32 - @clz(max));

    // The decoder's code-block state; `significant`, `sign`, `visited` and
    // `refined` evolve exactly as they do while decoding, so the decoder's
    // context functions give the same contexts here.
    var cblk = try ebcot.Cblk.init(allocator, width, height);
    defer cblk.deinit(allocator);
    var st: State = .{ .enc = mqe.Encoder.init(allocator), .ctxs = mqe.initEbcotContexts(), .cblk = &cblk, .mags = mags, .signs = signs, .orient = orient };
    errdefer st.enc.deinit();

    // Plane numbering follows the decoder: bp = numbps is the most
    // significant plane and carries magnitude bit numbps - 1.
    try st.cleanup(numbps);
    resetVisited(&cblk);
    var bp: u8 = numbps - 1;
    while (bp >= 1) : (bp -= 1) {
        try st.significance(bp);
        try st.refinement(bp);
        try st.cleanup(bp);
        resetVisited(&cblk);
    }
    const data = try st.enc.flush();
    st.enc.deinit();
    return .{ .data = data, .numbps = numbps, .passes = 3 * @as(u32, numbps) - 2 };
}

fn resetVisited(cblk: *ebcot.Cblk) void {
    for (cblk.coeffs) |*c| c.visited = false;
}

const State = struct {
    enc: mqe.Encoder,
    ctxs: [19]mqe.Context,
    cblk: *ebcot.Cblk,
    mags: []const u32,
    signs: []const u1,
    orient: ebcot.Orientation,

    /// Magnitude bit coded at plane `bp` (bp 1 carries bit 0).
    fn bit(self: *const State, idx: usize, bp: u8) u1 {
        return @intCast((self.mags[idx] >> @intCast(bp - 1)) & 1);
    }

    fn code(self: *State, cx: ebcot.CtxIdx, d: u1) !void {
        try self.enc.encode(&self.ctxs[@intFromEnum(cx)], d);
    }

    /// Mark (x, y) significant and code its sign with the decoder's sign
    /// context and prediction XOR.
    fn becomeSignificant(self: *State, x: u32, y: u32) !void {
        const idx = y * self.cblk.width + x;
        self.cblk.coeffs[idx].significant = true;
        const sc = ebcot.scContext(self.cblk.*, x, y);
        try self.code(sc.cx, self.signs[idx] ^ sc.xor);
        self.cblk.coeffs[idx].sign = self.signs[idx];
    }

    /// Significance propagation (D.3.1): insignificant coefficients with a
    /// significant neighbour, in stripe order, neighbourhood read live.
    fn significance(self: *State, bp: u8) !void {
        const c = self.cblk;
        var y_stripe: u32 = 0;
        while (y_stripe < c.height) : (y_stripe += 4) {
            const rows = @min(@as(u32, 4), c.height - y_stripe);
            var x: u32 = 0;
            while (x < c.width) : (x += 1) {
                var dy: u32 = 0;
                while (dy < rows) : (dy += 1) {
                    const y = y_stripe + dy;
                    const idx = y * c.width + x;
                    if (c.coeffs[idx].significant) continue;
                    if (!ebcot.hasSigNeighbor(c.*, x, y)) continue;
                    const b = self.bit(idx, bp);
                    try self.code(ebcot.zcContext(c.*, x, y, self.orient), b);
                    c.coeffs[idx].visited = true;
                    if (b == 1) try self.becomeSignificant(x, y);
                }
            }
        }
    }

    /// Magnitude refinement (D.3.2): coefficients significant before this
    /// plane's significance pass.
    fn refinement(self: *State, bp: u8) !void {
        const c = self.cblk;
        var y_stripe: u32 = 0;
        while (y_stripe < c.height) : (y_stripe += 4) {
            const rows = @min(@as(u32, 4), c.height - y_stripe);
            var x: u32 = 0;
            while (x < c.width) : (x += 1) {
                var dy: u32 = 0;
                while (dy < rows) : (dy += 1) {
                    const y = y_stripe + dy;
                    const idx = y * c.width + x;
                    if (!c.coeffs[idx].significant or c.coeffs[idx].visited) continue;
                    try self.code(ebcot.mrContext(c.*, x, y), self.bit(idx, bp));
                    c.coeffs[idx].refined = true;
                }
            }
        }
    }

    /// Cleanup (D.3.3) with run-length coding (D.3.4) on full stripes whose
    /// column is entirely insignificant, unvisited and neighbour-free.
    fn cleanup(self: *State, bp: u8) !void {
        const c = self.cblk;
        var y_stripe: u32 = 0;
        while (y_stripe < c.height) : (y_stripe += 4) {
            const rows = @min(@as(u32, 4), c.height - y_stripe);
            var x: u32 = 0;
            while (x < c.width) : (x += 1) {
                var start: u32 = 0;
                if (rows == 4 and ebcot.rlcEligible(c.*, x, y_stripe)) {
                    var first: ?u32 = null;
                    var k: u32 = 0;
                    while (k < 4) : (k += 1) {
                        if (self.bit((y_stripe + k) * c.width + x, bp) == 1) {
                            first = k;
                            break;
                        }
                    }
                    const f = first orelse {
                        try self.code(.rlc, 0);
                        continue;
                    };
                    try self.code(.rlc, 1);
                    try self.code(.uniform, @intCast(f >> 1));
                    try self.code(.uniform, @intCast(f & 1));
                    try self.becomeSignificant(x, y_stripe + f);
                    start = f + 1;
                }
                var dy: u32 = start;
                while (dy < rows) : (dy += 1) {
                    const y = y_stripe + dy;
                    const idx = y * c.width + x;
                    if (c.coeffs[idx].significant or c.coeffs[idx].visited) continue;
                    const b = self.bit(idx, bp);
                    try self.code(ebcot.zcContext(c.*, x, y, self.orient), b);
                    if (b == 1) try self.becomeSignificant(x, y);
                }
            }
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const mq = @import("../decode/mq_coder.zig");

/// Decode `enc` with the decoder's EBCOT and compare every coefficient.
fn expectRoundTrip(a: std.mem.Allocator, mags: []const u32, signs: []const u1, w: u32, h: u32, orient: ebcot.Orientation) !void {
    var enc = try encodeCblk(a, mags, signs, w, h, orient);
    defer enc.deinit(a);
    var max: u32 = 0;
    for (mags) |m| max = @max(max, m);
    const want_bps: u8 = if (max == 0) 0 else @intCast(32 - @clz(max));
    try std.testing.expectEqual(want_bps, enc.numbps);
    try std.testing.expectEqual(if (want_bps == 0) @as(u32, 0) else 3 * @as(u32, want_bps) - 2, enc.passes);
    if (enc.passes == 0) return;
    var cblk = try ebcot.Cblk.init(a, w, h);
    defer cblk.deinit(a);
    var dec = mq.Decoder.initDec(enc.data);
    var ctxs = ebcot.initContexts();
    ebcot.decodeCblkPasses(&dec, &cblk, &ctxs, orient, @intCast(enc.numbps), enc.passes);
    for (cblk.coeffs, 0..) |c, i| {
        const ok = if (mags[i] == 0) !c.significant else (c.significant and c.sign == signs[i] and c.magnitude == mags[i] << 1);
        if (!ok) {
            std.debug.print("\n[tier1] {d}x{d} {s} coeff {d}: want m={d} s={d}, got sig={} m={d} s={d}\n", .{ w, h, @tagName(orient), i, mags[i], signs[i], c.significant, c.magnitude >> 1, c.sign });
            return error.TestUnexpectedResult;
        }
    }
}

test "encodeCblk: an all-zero block codes nothing (0 bit-planes, 0 passes, no bytes)" {
    const a = std.testing.allocator;
    const mags = [_]u32{0} ** 16;
    const signs = [_]u1{0} ** 16;
    var enc = try encodeCblk(a, &mags, &signs, 4, 4, .ll);
    defer enc.deinit(a);
    try std.testing.expectEqual(@as(u8, 0), enc.numbps);
    try std.testing.expectEqual(@as(u32, 0), enc.passes);
    try std.testing.expectEqual(@as(usize, 0), enc.data.len);
}

test "encodeCblk: a single coefficient at every position of a 4x4 block decodes back, both signs, every orientation" {
    const a = std.testing.allocator;
    for ([_]ebcot.Orientation{ .ll, .hl, .lh, .hh }) |orient| {
        var pos: usize = 0;
        while (pos < 16) : (pos += 1) {
            for ([_]u1{ 0, 1 }) |s| {
                var mags = [_]u32{0} ** 16;
                var signs = [_]u1{0} ** 16;
                mags[pos] = 5;
                signs[pos] = s;
                try expectRoundTrip(a, &mags, &signs, 4, 4, orient);
            }
        }
    }
}

test "encodeCblk: seeded blocks of awkward sizes, sparse to dense, magnitudes up to 2^16, all four orientations decode back exactly" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xEB0C07);
    const rnd = prng.random();
    const sizes = [_][2]u32{ .{ 1, 1 }, .{ 1, 7 }, .{ 7, 1 }, .{ 2, 3 }, .{ 4, 4 }, .{ 5, 9 }, .{ 8, 8 }, .{ 13, 6 }, .{ 16, 16 }, .{ 31, 33 }, .{ 64, 64 } };
    const densities = [_]u32{ 2, 10, 50, 100 }; // percent of nonzero coefficients
    const max_bits = [_]u5{ 1, 2, 5, 9, 16 };
    for (sizes) |sz| for (densities) |pct| for (max_bits) |bits| for ([_]ebcot.Orientation{ .ll, .hl, .lh, .hh }) |orient| {
        const n = sz[0] * sz[1];
        const mags = try a.alloc(u32, n);
        defer a.free(mags);
        const signs = try a.alloc(u1, n);
        defer a.free(signs);
        for (mags, signs) |*m, *s| {
            m.* = if (rnd.uintLessThan(u32, 100) < pct) rnd.intRangeAtMost(u32, 1, (@as(u32, 1) << bits) - 1) else 0;
            s.* = rnd.int(u1);
        }
        try expectRoundTrip(a, mags, signs, sz[0], sz[1], orient);
    };
}

test "encodeCblk: run-length paths: a column-stripe whose first significant row is 0, 1, 2 or 3, then more rows below it" {
    const a = std.testing.allocator;
    var first: usize = 0;
    while (first < 4) : (first += 1) {
        var mags = [_]u32{0} ** 32; // 4 wide, 8 high: two full stripes
        var signs = [_]u1{0} ** 32;
        mags[first * 4 + 1] = 3; // column 1, row `first`
        mags[3 * 4 + 1] = 1; // and row 3 of the same column
        signs[first * 4 + 1] = 1;
        mags[6 * 4 + 2] = 2; // second stripe, column 2
        try expectRoundTrip(a, &mags, &signs, 4, 8, .hh);
    }
}
