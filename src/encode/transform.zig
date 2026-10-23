//! Forward transforms for the encoder: the reversible 5/3 wavelet (T.800
//! Annex F, lifting form) and the reversible colour transform (RCT, G.2).
//! Each is the exact inverse of the decoder's half in decode/dwt.zig and
//! decode/reconstruct.zig, including the edge clamping that implements
//! symmetric extension and the origin parity (cas) of each resolution, so
//! decode(encode(x)) == x holds sample for sample. The round-trip tests
//! below drive the decoder's inverse, which is the oracle.

const std = @import("std");
const subbands = @import("../decode/subbands.zig");

/// Forward 5/3 lifting over one line of `sn + dn` spatial samples. On
/// return `line` holds the deinterleaved `[ low(0..sn) | high(0..dn) ]`
/// split that `dwt.idwt53Line` consumes. `tmp` needs `sn + dn` slots;
/// `cas` is the parity of the resolution origin (0: first sample is low).
pub fn fdwt53Line(line: []i32, sn: usize, dn: usize, cas: u1, tmp: []i32) void {
    const len = sn + dn;
    if (len == 0) return;
    // Spatial sample k sits at tmp[k]; low(i) is at cas + 2i, high(i) at
    // (1 - cas) + 2i, as the inverse interleaves them.
    @memcpy(tmp[0..len], line[0..len]);
    if (cas == 0) {
        // Inverse runs S -= (D(i-1)+D(i)+2)>>2, then D += (S(i)+S(i+1))>>1;
        // undo in reverse order with the same clamped neighbours.
        if (dn > 0) {
            var i: usize = 0;
            while (i < dn) : (i += 1) {
                const s0 = evenAt(tmp, sn, @intCast(i));
                const s1 = evenAt(tmp, sn, @as(isize, @intCast(i)) + 1);
                tmp[2 * i + 1] -%= (s0 +% s1) >> 1;
            }
            i = 0;
            while (i < sn) : (i += 1) {
                const dm1 = oddAt(tmp, dn, @as(isize, @intCast(i)) - 1);
                const d0 = oddAt(tmp, dn, @intCast(i));
                tmp[2 * i] +%= (dm1 +% d0 +% 2) >> 2;
            }
        }
    } else {
        if (sn == 0 and dn == 1) {
            // The inverse halves a lone high-pass sample (truncating).
            tmp[0] = tmp[0] *% 2;
        } else {
            // Inverse runs low(i) -= (high(i)+high(i+1)+2)>>2 [high clamped
            // to dn], then high(i) += (low(i)+low(i-1))>>1 [low clamped to
            // sn]; here low(i) = tmp[2i+1], high(i) = tmp[2i].
            var i: usize = 0;
            while (i < dn) : (i += 1) {
                const l0 = oddAt(tmp, sn, @intCast(i));
                const lm1 = oddAt(tmp, sn, @as(isize, @intCast(i)) - 1);
                tmp[2 * i] -%= (l0 +% lm1) >> 1;
            }
            i = 0;
            while (i < sn) : (i += 1) {
                const h0 = evenAt(tmp, dn, @intCast(i));
                const h1 = evenAt(tmp, dn, @as(isize, @intCast(i)) + 1);
                tmp[2 * i + 1] +%= (h0 +% h1 +% 2) >> 2;
            }
        }
    }
    // Deinterleave into [low | high].
    var k: usize = 0;
    while (k < sn) : (k += 1) line[k] = tmp[cas + 2 * k];
    k = 0;
    while (k < dn) : (k += 1) line[sn + k] = tmp[(1 - @as(usize, cas)) + 2 * k];
}

/// tmp[2c] with c = i clamped to [0, bound-1]: symmetric extension.
inline fn evenAt(a: []const i32, bound: usize, i: isize) i32 {
    const c: usize = if (i < 0) 0 else if (@as(usize, @intCast(i)) >= bound) bound - 1 else @intCast(i);
    return a[2 * c];
}
/// tmp[2c+1] with c = i clamped to [0, bound-1].
inline fn oddAt(a: []const i32, bound: usize, i: isize) i32 {
    const c: usize = if (i < 0) 0 else if (@as(usize, @intCast(i)) >= bound) bound - 1 else @intCast(i);
    return a[2 * c + 1];
}

/// Full forward 5/3 DWT of a tile-component (row-major, `tile_w` stride,
/// finest-resolution extent `image_w × image_h` at origin
/// (`tile_x0`, `tile_y0`)) into the Mallat quadrant layout `dwt.idwt53`
/// reads, over `num_decomp` levels, finest level first.
pub fn fdwt53(
    allocator: std.mem.Allocator,
    tile: []i32,
    tile_w: u32,
    tile_x0: u32,
    tile_y0: u32,
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
    // The inverse walks r = 1..R, rows then columns; the forward walks
    // r = R..1 and undoes columns before rows at each level.
    var r: u8 = num_decomp;
    while (r >= 1) : (r -= 1) {
        const cur = subbands.resolutionExtent(tile_x0, tile_y0, image_w, image_h, num_decomp, r);
        const prev = subbands.resolutionExtent(tile_x0, tile_y0, image_w, image_h, num_decomp, r - 1);
        const rw = cur.width;
        const rh = cur.height;
        if (rw != 0 and rh != 0) {
            const cas_x: u1 = @intCast(cur.x0 & 1);
            const cas_y: u1 = @intCast(cur.y0 & 1);
            var i: usize = 0;
            while (i < rw) : (i += 1) {
                var k: usize = 0;
                while (k < rh) : (k += 1) col[k] = tile[k * tile_w + i];
                fdwt53Line(col[0..rh], prev.height, rh - prev.height, cas_y, tmp);
                k = 0;
                while (k < rh) : (k += 1) tile[k * tile_w + i] = col[k];
            }
            var j: usize = 0;
            while (j < rh) : (j += 1) {
                const base = j * tile_w;
                fdwt53Line(tile[base .. base + rw], prev.width, rw - prev.width, cas_x, tmp);
            }
        }
        if (r == 1) break;
    }
}

/// Forward RCT (T.800 Eq. G-3..G-5) in place on DC-shifted planes:
/// (R, G, B) → (Y0, Y1, Y2) = (floor((R + 2G + B) / 4), B − G, R − G).
pub fn forwardRct(c0: []i32, c1: []i32, c2: []i32) void {
    for (c0, c1, c2) |*r, *g, *b| {
        const y0 = (r.* +% 2 *% g.* +% b.*) >> 2;
        const y1 = b.* -% g.*;
        const y2 = r.* -% g.*;
        r.* = y0;
        g.* = y1;
        b.* = y2;
    }
}

// ── Tests ──────────────────────────────────────────────────────────

const dwt = @import("../decode/dwt.zig");
const reconstruct = @import("../decode/reconstruct.zig");

test "fdwt53Line: idwt53Line inverts it for every length 1..96, both origin parities, seeded data in [-2^17, 2^17)" {
    var prng = std.Random.DefaultPrng.init(0x6a70327a);
    const rnd = prng.random();
    var orig: [96]i32 = undefined;
    var line: [96]i32 = undefined;
    var tmp: [96]i32 = undefined;
    var len: usize = 1;
    while (len <= 96) : (len += 1) {
        for ([_]u1{ 0, 1 }) |cas| {
            // Low count: ceil for cas 0, floor for cas 1 (T.800 F.3.3).
            const sn: usize = if (cas == 0) (len + 1) / 2 else len / 2;
            const dn = len - sn;
            var trial: usize = 0;
            while (trial < 20) : (trial += 1) {
                for (orig[0..len]) |*v| v.* = rnd.intRangeLessThan(i32, -(1 << 17), 1 << 17);
                @memcpy(line[0..len], orig[0..len]);
                fdwt53Line(line[0..len], sn, dn, cas, &tmp);
                if (len > 1) try std.testing.expect(!std.mem.eql(i32, line[0..len], orig[0..len]) or std.mem.allEqual(i32, orig[0..len], orig[0]));
                dwt.idwt53Line(line[0..len], sn, dn, cas, &tmp);
                try std.testing.expectEqualSlices(i32, orig[0..len], line[0..len]);
            }
        }
    }
}

test "fdwt53Line: a constant line has zero high-pass and keeps the constant in every low-pass sample" {
    var line = [_]i32{ 7, 7, 7, 7, 7, 7, 7 };
    var tmp: [7]i32 = undefined;
    fdwt53Line(&line, 4, 3, 0, &tmp);
    try std.testing.expectEqualSlices(i32, &.{ 7, 7, 7, 7, 0, 0, 0 }, &line);
}

test "fdwt53: idwt53 inverts it over sizes, decomposition levels 0..5 and odd and even tile origins" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x2a);
    const rnd = prng.random();
    const sizes = [_][2]u32{ .{ 1, 1 }, .{ 1, 9 }, .{ 9, 1 }, .{ 4, 4 }, .{ 7, 5 }, .{ 16, 16 }, .{ 33, 17 }, .{ 64, 3 }, .{ 37, 41 } };
    const origins = [_][2]u32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 3, 5 }, .{ 128, 77 } };
    for (sizes) |sz| for (origins) |org| {
        var levels: u8 = 0;
        while (levels <= 5) : (levels += 1) {
            const n = sz[0] * sz[1];
            const orig = try a.alloc(i32, n);
            defer a.free(orig);
            const tile = try a.alloc(i32, n);
            defer a.free(tile);
            for (orig) |*v| v.* = rnd.intRangeLessThan(i32, -32768, 32768);
            @memcpy(tile, orig);
            try fdwt53(a, tile, sz[0], org[0], org[1], sz[0], sz[1], levels);
            try dwt.idwt53(a, tile, sz[0], org[0], org[1], sz[0], sz[1], levels);
            std.testing.expectEqualSlices(i32, orig, tile) catch |e| {
                std.debug.print("\n[fdwt53] {d}x{d} origin ({d},{d}) levels {d}\n", .{ sz[0], sz[1], org[0], org[1], levels });
                return e;
            };
        }
    };
}

test "forwardRct: inverseRct inverts it over every 8-bit DC-shifted triple (2^24, exhaustive) and seeded 16-bit triples" {
    var c0: [256]i32 = undefined;
    var c1: [256]i32 = undefined;
    var c2: [256]i32 = undefined;
    var r: i32 = -128;
    while (r < 128) : (r += 1) {
        var g: i32 = -128;
        while (g < 128) : (g += 1) {
            for (0..256) |k| {
                c0[k] = r;
                c1[k] = g;
                c2[k] = @as(i32, @intCast(k)) - 128;
            }
            forwardRct(&c0, &c1, &c2);
            reconstruct.inverseRct(&c0, &c1, &c2);
            for (0..256) |k| {
                if (c0[k] != r or c1[k] != g or c2[k] != @as(i32, @intCast(k)) - 128) {
                    std.debug.print("\n[rct] ({d},{d},{d}) → ({d},{d},{d})\n", .{ r, g, @as(i32, @intCast(k)) - 128, c0[k], c1[k], c2[k] });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
    var prng = std.Random.DefaultPrng.init(16);
    const rnd = prng.random();
    var trial: usize = 0;
    while (trial < 4096) : (trial += 1) {
        for (0..256) |k| {
            c0[k] = rnd.intRangeLessThan(i32, -32768, 32768);
            c1[k] = rnd.intRangeLessThan(i32, -32768, 32768);
            c2[k] = rnd.intRangeLessThan(i32, -32768, 32768);
        }
        const o0 = c0;
        const o1 = c1;
        const o2 = c2;
        forwardRct(&c0, &c1, &c2);
        reconstruct.inverseRct(&c0, &c1, &c2);
        try std.testing.expectEqualSlices(i32, &o0, &c0);
        try std.testing.expectEqualSlices(i32, &o1, &c1);
        try std.testing.expectEqualSlices(i32, &o2, &c2);
    }
}

test "forwardRct: grey input (R = G = B) maps to Y0 = value and zero chroma" {
    var c0 = [_]i32{ -128, 0, 77, 127 };
    var c1 = c0;
    var c2 = c0;
    forwardRct(&c0, &c1, &c2);
    try std.testing.expectEqualSlices(i32, &.{ -128, 0, 77, 127 }, &c0);
    try std.testing.expectEqualSlices(i32, &.{ 0, 0, 0, 0 }, &c1);
    try std.testing.expectEqualSlices(i32, &.{ 0, 0, 0, 0 }, &c2);
}
