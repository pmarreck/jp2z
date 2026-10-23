//! Codestream writer: turns component planes into a T.800 Part 1 J2K
//! codestream (SOC, SIZ, COD, QCD, one tile-part, EOC) or a JP2 file.
//! First cut (docs/plan_context/encoder_and_cli.md): reversible 5/3 path,
//! no quantization, RCT when three or more components are coded, one tile
//! covering the image, one quality layer, LRCP, 64x64 code-blocks, default
//! precincts, code-block style 0. Lossless by construction; the tests in
//! tests/unit/encode.zig prove it through jp2z's decoder and OpenJPEG's.
//!
//! The band and code-block geometry comes from the decoder's own helpers
//! (decode/subbands.zig), and the transforms and coders are tested against
//! the decoder's inverses, so a disagreement surfaces as a failed round trip
//! rather than as a silently different file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const subbands = @import("../decode/subbands.zig");
const ebcot = @import("../decode/ebcot.zig");
const transform = @import("transform.zig");
const tier1 = @import("tier1.zig");
const tier2 = @import("tier2.zig");

pub const Params = struct {
    width: u32,
    height: u32,
    /// Component count; every plane in `planes` has width * height samples.
    components: u16,
    /// Bits per sample, 1..16.
    precision: u8,
    /// Samples are two's-complement signed when true, else unsigned.
    signed: bool = false,
    /// Wavelet decomposition levels; default min(5, floor(log2(max(w, h)))).
    levels: ?u8 = null,
};

/// CarryIntoSentinel is the MQ coder reporting a carry into the byte before
/// its first output; the initial CT = 12 delay rules it out (T.800 C.2.6),
/// so it signals an encoder defect and is surfaced rather than masked.
pub const EncodeError = error{ InvalidDimensions, InvalidComponents, UnsupportedPrecision, PlaneSizeMismatch, InvalidLevels, SampleOutOfRange, CoefficientOverflow, CarryIntoSentinel } || Allocator.Error;

/// Guard bits in QCD (T.800 A.6.4); OpenJPEG's default. With exponent
/// precision + gain, Mb = guard + exponent - 1 leaves one bit of headroom
/// for the RCT's chroma growth, and CoefficientOverflow reports anything
/// that would not fit rather than writing a wrong zero-bit-plane count.
const guard_bits: u8 = 2;
/// T.800 A.5.1: Csiz ranges over 1..16384.
pub const max_components: u16 = 16384;
/// T.800 A.6.1: SPcod decomposition levels range over 0..32.
const max_levels: u8 = 32;
/// COD code-block exponents: 2^(4 + 2) = 64.
const cblk_exp: u8 = 4;
/// Default precincts (Scod bit 0 clear): PPx = PPy = 15.
const pp_default: u4 = 15;

fn defaultLevels(w: u32, h: u32) u8 {
    const m = @max(w, h);
    const log2: u8 = @intCast(31 - @clz(m));
    return @min(5, log2);
}

/// Subband gain log2 (T.800 Table E.1 / E-10): LL 0, HL and LH 1, HH 2.
fn gain(r: u8, sb: u8) u8 {
    if (r == 0) return 0;
    return if (sb == 2) 2 else 1;
}

fn orientation(r: u8, sb: u8) ebcot.Orientation {
    if (r == 0) return .ll;
    return switch (sb) {
        0 => .hl,
        1 => .lh,
        else => .hh,
    };
}

const CodedBlock = struct { enc: tier1.Encoded, zbp: u32 };
const Band = struct { gw: u32, gh: u32, blocks: []CodedBlock };

/// Encode `planes` (one slice of row-major samples per component) as a J2K
/// codestream. The caller owns the returned bytes.
pub fn encodeJ2k(a: Allocator, planes: []const []const i32, p: Params) EncodeError![]u8 {
    if (p.width == 0 or p.height == 0) return error.InvalidDimensions;
    if (p.components == 0 or p.components > max_components or planes.len != p.components) return error.InvalidComponents;
    if (p.precision == 0 or p.precision > 16) return error.UnsupportedPrecision;
    const n = @as(usize, p.width) * p.height;
    for (planes) |pl| if (pl.len != n) return error.PlaneSizeMismatch;
    const levels = p.levels orelse defaultLevels(p.width, p.height);
    if (levels > max_levels) return error.InvalidLevels;
    // Every sample must be representable at the declared precision.
    const lo: i32 = if (p.signed) -(@as(i32, 1) << @intCast(p.precision - 1)) else 0;
    const hi: i32 = if (p.signed) (@as(i32, 1) << @intCast(p.precision - 1)) - 1 else (@as(i32, 1) << @intCast(p.precision)) - 1;
    for (planes) |pl| for (pl) |s| if (s < lo or s > hi) return error.SampleOutOfRange;
    const mct = p.components >= 3;

    // DC level shift, RCT, forward DWT, per component.
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const tiles = try ar.alloc([]i32, p.components);
    const shift: i32 = if (p.signed) 0 else @as(i32, 1) << @intCast(p.precision - 1);
    for (tiles, planes) |*t, pl| {
        t.* = try ar.alloc(i32, n);
        for (t.*, pl) |*d, s| d.* = s - shift;
    }
    if (mct) transform.forwardRct(tiles[0], tiles[1], tiles[2]);
    for (tiles) |t| try transform.fdwt53(ar, t, p.width, 0, 0, p.width, p.height, levels);

    // Tier-1: every code-block of every band of every resolution.
    const nres: usize = @as(usize, levels) + 1;
    const bands = try ar.alloc([3]Band, p.components * nres);
    for (0..p.components) |c| {
        var r: u8 = 0;
        while (r <= levels) : (r += 1) {
            const prev = if (r == 0) subbands.ResRect{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0, .width = 0, .height = 0 } else subbands.resolutionExtent(0, 0, p.width, p.height, levels, r - 1);
            var sb: u8 = 0;
            while (sb < subbands.subbandCount(r)) : (sb += 1) {
                const info = subbands.subbandDims(0, 0, p.width, p.height, levels, r, sb);
                const grid = if (info.width == 0 or info.height == 0) subbands.GridSize{ .width = 0, .height = 0 } else subbands.codeBlockGrid(info, cblk_exp, cblk_exp);
                const mb: u32 = guard_bits + p.precision + gain(r, sb) - 1;
                // Band origin inside the Mallat-ordered tile buffer.
                const bx: u32 = if (r > 0 and (sb == 0 or sb == 2)) prev.width else 0;
                const by: u32 = if (r > 0 and (sb == 1 or sb == 2)) prev.height else 0;
                const blocks = try ar.alloc(CodedBlock, @as(usize, grid.width) * grid.height);
                for (blocks, 0..) |*blk, gi| {
                    const rect = subbands.cblkSubbandRect(0, 0, p.width, p.height, levels, r, sb, 0, 0, pp_default, pp_default, cblk_exp, cblk_exp, @intCast(gi % grid.width), @intCast(gi / grid.width));
                    const cw: u32 = @intCast(rect.x1 - rect.x0);
                    const ch: u32 = @intCast(rect.y1 - rect.y0);
                    const mags = try ar.alloc(u32, @as(usize, cw) * ch);
                    const signs = try ar.alloc(u1, mags.len);
                    var yy: u32 = 0;
                    while (yy < ch) : (yy += 1) {
                        var xx: u32 = 0;
                        while (xx < cw) : (xx += 1) {
                            const v = tiles[c][(by + @as(u32, @intCast(rect.y0)) + yy) * p.width + bx + @as(u32, @intCast(rect.x0)) + xx];
                            mags[yy * cw + xx] = @abs(v);
                            signs[yy * cw + xx] = @intFromBool(v < 0);
                        }
                    }
                    const enc = try tier1.encodeCblk(ar, mags, signs, cw, ch, orientation(r, sb));
                    if (enc.numbps > mb) return error.CoefficientOverflow;
                    blk.* = .{ .enc = enc, .zbp = mb - enc.numbps };
                }
                bands[c * nres + r][sb] = .{ .gw = grid.width, .gh = grid.height, .blocks = blocks };
            }
        }
    }

    // Tier-2: one packet per (resolution, component), LRCP, one layer.
    var body = std.ArrayList(u8).empty;
    defer body.deinit(a);
    var r: u8 = 0;
    while (r <= levels) : (r += 1) {
        for (0..p.components) |c| try writePacket(a, ar, &body, bands[c * nres + r][0..subbands.subbandCount(r)]);
    }

    // Marker segments.
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, &.{ 0xFF, 0x4F }); // SOC
    // SIZ (A.5.1).
    try out.appendSlice(a, &.{ 0xFF, 0x51 });
    try putU16(a, &out, @intCast(38 + 3 * @as(usize, p.components)));
    try putU16(a, &out, 0); // Rsiz: Part 1, no profile claimed
    for ([_]u32{ p.width, p.height, 0, 0, p.width, p.height, 0, 0 }) |v| try putU32(a, &out, v);
    try putU16(a, &out, p.components);
    for (0..p.components) |_| try out.appendSlice(a, &.{ (@as(u8, @intFromBool(p.signed)) << 7) | (p.precision - 1), 1, 1 });
    // COD (A.6.1): Scod 0, LRCP, 1 layer, MCT, levels, 64x64, style 0, 5/3.
    try out.appendSlice(a, &.{ 0xFF, 0x52, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x01, @intFromBool(mct), levels, cblk_exp, cblk_exp, 0x00, 0x01 });
    // QCD (A.6.4): no quantization, one exponent byte per subband.
    const nsb: usize = 3 * @as(usize, levels) + 1;
    try out.appendSlice(a, &.{ 0xFF, 0x5C });
    try putU16(a, &out, @intCast(3 + nsb));
    try out.append(a, guard_bits << 5);
    try out.append(a, (p.precision + gain(0, 0)) << 3);
    var lr: u8 = 1;
    while (lr <= levels) : (lr += 1) {
        for ([_]u8{ 0, 1, 2 }) |sb| try out.append(a, (p.precision + gain(lr, sb)) << 3);
    }
    // SOT (A.4.2): tile 0, Psot covers SOT through the last packet byte.
    const psot: u32 = @intCast(12 + 2 + body.items.len);
    try out.appendSlice(a, &.{ 0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00 });
    try putU32(a, &out, psot);
    try out.appendSlice(a, &.{ 0x00, 0x01 }); // TPsot 0, TNsot 1
    try out.appendSlice(a, &.{ 0xFF, 0x93 }); // SOD
    try out.appendSlice(a, body.items);
    try out.appendSlice(a, &.{ 0xFF, 0xD9 }); // EOC
    return out.toOwnedSlice(a);
}

/// One packet (B.9, B.10): header bits, then the code-block data in the
/// same order. `ar` is scratch for the tag trees.
fn writePacket(a: Allocator, ar: Allocator, body: *std.ArrayList(u8), bands: []const Band) !void {
    var w: tier2.BitWriter = .{};
    defer w.deinit(a);
    var any = false;
    for (bands) |b| for (b.blocks) |blk| {
        if (blk.enc.passes > 0) any = true;
    };
    if (!any) {
        try w.writeBit(a, 0); // empty packet
        try w.finish(a);
        try body.appendSlice(a, w.out.items);
        return;
    }
    try w.writeBit(a, 1);
    for (bands) |b| {
        if (b.blocks.len == 0) continue;
        const incl_vals = try ar.alloc(u32, b.blocks.len);
        const zbp_vals = try ar.alloc(u32, b.blocks.len);
        for (b.blocks, 0..) |blk, i| {
            incl_vals[i] = if (blk.enc.passes > 0) 0 else 1;
            zbp_vals[i] = blk.zbp;
        }
        var incl = try tier2.TagTreeEncoder.init(ar, b.gw, b.gh, incl_vals);
        var zbp = try tier2.TagTreeEncoder.init(ar, b.gw, b.gh, zbp_vals);
        for (b.blocks, 0..) |blk, i| {
            const x: u32 = @intCast(i % b.gw);
            const y: u32 = @intCast(i / b.gw);
            try incl.encode(a, &w, x, y, 1);
            if (blk.enc.passes == 0) continue;
            try zbp.encode(a, &w, x, y, 999);
            try writePasses(a, &w, blk.enc.passes);
            // Lblock starts at 3; raise it until the length fits (B.10.7.1).
            var lblock: u6 = 3;
            const log2p: u6 = @intCast(31 - @clz(blk.enc.passes));
            const len: u32 = @intCast(blk.enc.data.len);
            while (len >= (@as(u64, 1) << (lblock + log2p))) {
                try w.writeBit(a, 1);
                lblock += 1;
            }
            try w.writeBit(a, 0);
            try w.writeBits(a, len, lblock + log2p);
        }
    }
    try w.finish(a);
    try body.appendSlice(a, w.out.items);
    for (bands) |b| for (b.blocks) |blk| {
        if (blk.enc.passes > 0) try body.appendSlice(a, blk.enc.data);
    };
}

/// Coding-pass count codewords (T.800 Table B.4).
fn writePasses(a: Allocator, w: *tier2.BitWriter, n: u32) !void {
    std.debug.assert(n >= 1 and n <= 164);
    if (n == 1) return w.writeBit(a, 0);
    if (n == 2) return w.writeBits(a, 0b10, 2);
    if (n <= 5) return w.writeBits(a, (0b11 << 2) | (n - 3), 4);
    if (n <= 36) return w.writeBits(a, (0b1111 << 5) | (n - 6), 9);
    return w.writeBits(a, (0x1FF << 7) | (n - 37), 16);
}

fn putU16(a: Allocator, out: *std.ArrayList(u8), v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .big);
    try out.appendSlice(a, &b);
}

fn putU32(a: Allocator, out: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    try out.appendSlice(a, &b);
}

/// Encode as a JP2 file (T.800 Annex I): signature, ftyp ('jp2 '), jp2h
/// with ihdr and one colr box (greyscale below three components, sRGB from
/// three; every component shares one precision, so no bpcc), then jp2c.
pub fn encodeJp2(a: Allocator, planes: []const []const i32, p: Params) EncodeError![]u8 {
    const cs = try encodeJ2k(a, planes, p);
    defer a.free(cs);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, &.{ 0x00, 0x00, 0x00, 0x0C, 'j', 'P', ' ', ' ', 0x0D, 0x0A, 0x87, 0x0A });
    try out.appendSlice(a, &.{ 0x00, 0x00, 0x00, 0x14, 'f', 't', 'y', 'p', 'j', 'p', '2', ' ', 0x00, 0x00, 0x00, 0x00, 'j', 'p', '2', ' ' });
    try putU32(a, &out, 8 + 22 + 15);
    try out.appendSlice(a, "jp2h");
    try out.appendSlice(a, &.{ 0x00, 0x00, 0x00, 0x16, 'i', 'h', 'd', 'r' });
    try putU32(a, &out, p.height);
    try putU32(a, &out, p.width);
    try putU16(a, &out, p.components);
    try out.appendSlice(a, &.{ (@as(u8, @intFromBool(p.signed)) << 7) | (p.precision - 1), 7, 0, 0 });
    const enumcs: u8 = if (p.components >= 3) 16 else 17;
    try out.appendSlice(a, &.{ 0x00, 0x00, 0x00, 0x0F, 'c', 'o', 'l', 'r', 1, 0, 0, 0, 0, 0, enumcs });
    try putU32(a, &out, @intCast(8 + cs.len));
    try out.appendSlice(a, "jp2c");
    try out.appendSlice(a, cs);
    return out.toOwnedSlice(a);
}
