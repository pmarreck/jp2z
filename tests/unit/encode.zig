//! Encoder round trips. Oracles: jp2z's own decoder, OpenJPEG's decoder
//! (an implementation this project did not write, through
//! jp2z.internal.openjpegDecode) and strict validation, which must report
//! nothing above INFO for every file the encoder writes.

const std = @import("std");
const jp2z = @import("jp2z");

const Case = struct { w: u32, h: u32, comps: u16, prec: u8, levels: ?u8 = null, pattern: enum { noise, gradient, flat } = .noise };

fn makePlanes(a: std.mem.Allocator, c: Case, seed: u64) ![][]i32 {
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    const planes = try a.alloc([]i32, c.comps);
    const max: i32 = (@as(i32, 1) << @intCast(c.prec)) - 1;
    for (planes, 0..) |*pl, ci| {
        pl.* = try a.alloc(i32, @as(usize, c.w) * c.h);
        for (pl.*, 0..) |*s, i| s.* = switch (c.pattern) {
            .noise => rnd.intRangeAtMost(i32, 0, max),
            .gradient => @intCast((@as(u64, @intCast(i % c.w)) * 3 + @as(u64, @intCast(i / c.w)) * 5 + ci * 17) % (@as(u64, @intCast(max)) + 1)),
            .flat => @divTrunc(max, 3),
        };
    }
    return planes;
}

fn freePlanes(a: std.mem.Allocator, planes: [][]i32) void {
    for (planes) |pl| a.free(pl);
    a.free(planes);
}

/// The decoded Image (interleaved; u8 up to 8 bits, else u16) equals the planes.
fn expectImage(img: jp2z.Image, planes: []const []const i32, c: Case, who: []const u8) !void {
    try std.testing.expectEqual(c.w, img.width);
    try std.testing.expectEqual(c.h, img.height);
    try std.testing.expectEqual(c.comps, img.channels);
    const n = @as(usize, c.w) * c.h;
    for (0..n) |i| for (0..c.comps) |ci| {
        const got: i32 = if (c.prec > 8) img.pixelsU16()[i * c.comps + ci] else img.pixels[i * c.comps + ci];
        if (got != planes[ci][i]) {
            std.debug.print("\n[{s}] {d}x{d}x{d} prec {d}: sample {d} comp {d}: want {d}, got {d}\n", .{ who, c.w, c.h, c.comps, c.prec, i, ci, planes[ci][i], got });
            return error.TestUnexpectedResult;
        }
    };
}

fn roundTrip(a: std.mem.Allocator, c: Case, seed: u64, jp2: bool) !void {
    const planes = try makePlanes(a, c, seed);
    defer freePlanes(a, planes);
    const consts: []const []const i32 = @ptrCast(planes);
    const p: jp2z.encode.Params = .{ .width = c.w, .height = c.h, .components = c.comps, .precision = c.prec, .levels = c.levels };
    const bytes = if (jp2) try jp2z.encode.encodeJp2(a, consts, p) else try jp2z.encode.encodeJ2k(a, consts, p);
    defer a.free(bytes);
    // Strict validation: nothing above INFO.
    var rep = try jp2z.internal.deepValidate(a, bytes, true);
    defer rep.deinit(a);
    for (rep.findings.items) |f| if (f.severity == .warn or f.severity == .fail) {
        std.debug.print("\n[validate] {d}x{d}x{d} prec {d} jp2={}: {s} {s} @{?d} {s}\n", .{ c.w, c.h, c.comps, c.prec, jp2, @tagName(f.severity), @tagName(f.code), f.offset, f.detail orelse "" });
        return error.TestUnexpectedResult;
    };
    var ours = try jp2z.decode(a, bytes);
    defer ours.deinit(a);
    try expectImage(ours, consts, c, "jp2z");
    var theirs = try jp2z.internal.openjpegDecode(a, bytes);
    defer theirs.deinit(a);
    try expectImage(theirs, consts, c, "openjpeg");
}

test "encode: 8-bit greyscale noise and gradients over awkward sizes decode exactly in jp2z and OpenJPEG and validate clean" {
    const a = std.testing.allocator;
    const cases = [_]Case{
        .{ .w = 1, .h = 1, .comps = 1, .prec = 8 },
        .{ .w = 3, .h = 5, .comps = 1, .prec = 8 },
        .{ .w = 64, .h = 64, .comps = 1, .prec = 8 },
        .{ .w = 65, .h = 33, .comps = 1, .prec = 8 },
        .{ .w = 130, .h = 7, .comps = 1, .prec = 8, .pattern = .gradient },
        .{ .w = 200, .h = 150, .comps = 1, .prec = 8, .pattern = .gradient },
        .{ .w = 40, .h = 40, .comps = 1, .prec = 8, .pattern = .flat },
    };
    for (cases, 0..) |c, i| try roundTrip(a, c, 0x100 + i, false);
}

test "encode: RGB (RCT) and two-component images, 8-bit, decode exactly and validate clean" {
    const a = std.testing.allocator;
    const cases = [_]Case{
        .{ .w = 17, .h = 23, .comps = 3, .prec = 8 },
        .{ .w = 96, .h = 64, .comps = 3, .prec = 8, .pattern = .gradient },
        .{ .w = 31, .h = 9, .comps = 2, .prec = 8 },
        .{ .w = 12, .h = 12, .comps = 4, .prec = 8 },
    };
    for (cases, 0..) |c, i| try roundTrip(a, c, 0x200 + i, false);
}

test "encode: 1-, 12- and 16-bit precisions and every decomposition level count 0..5" {
    const a = std.testing.allocator;
    const cases = [_]Case{
        .{ .w = 33, .h = 21, .comps = 1, .prec = 1 },
        .{ .w = 50, .h = 40, .comps = 1, .prec = 12 },
        .{ .w = 40, .h = 50, .comps = 3, .prec = 12, .pattern = .gradient },
        .{ .w = 37, .h = 29, .comps = 1, .prec = 16 },
    };
    for (cases, 0..) |c, i| try roundTrip(a, c, 0x300 + i, false);
    var levels: u8 = 0;
    while (levels <= 5) : (levels += 1) try roundTrip(a, .{ .w = 45, .h = 38, .comps = 1, .prec = 8, .levels = levels }, 0x400 + @as(u64, levels), false);
}

test "encode: JP2 output (ihdr + colr) decodes exactly and validates clean" {
    const a = std.testing.allocator;
    try roundTrip(a, .{ .w = 20, .h = 10, .comps = 1, .prec = 8 }, 0x500, true);
    try roundTrip(a, .{ .w = 20, .h = 10, .comps = 3, .prec = 8 }, 0x501, true);
    try roundTrip(a, .{ .w = 9, .h = 11, .comps = 1, .prec = 16 }, 0x502, true);
}

test "encode: invalid parameters are refused, never encoded" {
    const a = std.testing.allocator;
    const plane = [_]i32{ 0, 1, 2, 3 };
    const planes = [_][]const i32{&plane};
    try std.testing.expectError(error.InvalidDimensions, jp2z.encode.encodeJ2k(a, &planes, .{ .width = 0, .height = 4, .components = 1, .precision = 8 }));
    try std.testing.expectError(error.PlaneSizeMismatch, jp2z.encode.encodeJ2k(a, &planes, .{ .width = 3, .height = 1, .components = 1, .precision = 8 }));
    try std.testing.expectError(error.InvalidComponents, jp2z.encode.encodeJ2k(a, &planes, .{ .width = 2, .height = 2, .components = 2, .precision = 8 }));
    try std.testing.expectError(error.UnsupportedPrecision, jp2z.encode.encodeJ2k(a, &planes, .{ .width = 2, .height = 2, .components = 1, .precision = 0 }));
    try std.testing.expectError(error.UnsupportedPrecision, jp2z.encode.encodeJ2k(a, &planes, .{ .width = 2, .height = 2, .components = 1, .precision = 17 }));
    // T.800 A.5.1: Csiz ranges over 1..16384.
    const many = try a.alloc([]const i32, 16385);
    defer a.free(many);
    for (many) |*m| m.* = &plane;
    try std.testing.expectError(error.InvalidComponents, jp2z.encode.encodeJ2k(a, many, .{ .width = 2, .height = 2, .components = 16385, .precision = 8 }));
    // T.800 A.6.1 allows 0..32 decomposition levels.
    try std.testing.expectError(error.InvalidLevels, jp2z.encode.encodeJ2k(a, &planes, .{ .width = 2, .height = 2, .components = 1, .precision = 8, .levels = 33 }));
    // A sample outside [0, 2^p) cannot be represented at precision p: plane
    // value 3 at precision 1, and -1 or 2^p at the edges.
    try std.testing.expectError(error.SampleOutOfRange, jp2z.encode.encodeJ2k(a, &planes, .{ .width = 2, .height = 2, .components = 1, .precision = 1 }));
    const low = [_]i32{ 0, -1, 0, 0 };
    const high = [_]i32{ 0, 0, 0, 256 };
    try std.testing.expectError(error.SampleOutOfRange, jp2z.encode.encodeJ2k(a, &[_][]const i32{&low}, .{ .width = 2, .height = 2, .components = 1, .precision = 8 }));
    try std.testing.expectError(error.SampleOutOfRange, jp2z.encode.encodeJ2k(a, &[_][]const i32{&high}, .{ .width = 2, .height = 2, .components = 1, .precision = 8 }));
    // 32 levels on a small image is legal (the extra levels are empty), and
    // both decoders reproduce it.
    try roundTrip(a, .{ .w = 5, .h = 3, .comps = 1, .prec = 8, .levels = 32 }, 0x600, false);
}
