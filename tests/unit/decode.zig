//! Phase 1 decode tests — exercise the openjpeg wrapper end-to-end
//! against vendored ISO 15444-4 conformance fixtures.
//!
//! Phase 2 will add cleanroom-vs-oracle byte-perfect tests over the
//! pinned `openjpeg-data` flake input (see flake.nix → openjpegData).

const std = @import("std");
const jp2z = @import("jp2z");

const c1_mono_j2c = @embedFile("fixtures/conformance/c1_mono.j2c");
const d1_colr_j2c = @embedFile("fixtures/conformance/d1_colr.j2c");
const file1_jp2 = @embedFile("fixtures/conformance/file1.jp2");
const file9_jp2 = @embedFile("fixtures/conformance/file9.jp2");

test "decode J2K codestream: c1_mono.j2c (303x179, 8-bit grayscale)" {
    const allocator = std.testing.allocator;
    var img = try jp2z.decode(allocator, c1_mono_j2c);
    defer img.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 303), img.width);
    try std.testing.expectEqual(@as(u32, 179), img.height);
    try std.testing.expectEqual(@as(u8, 1), img.channels);
    try std.testing.expectEqual(@as(u8, 8), img.bits_per_sample);
    try std.testing.expectEqual(jp2z.PixelLayout.grayscale, img.layout);
    try std.testing.expectEqual(@as(usize, 303 * 179), img.pixels.len);
}

test "decode J2K codestream: d1_colr.j2c (256x149, 8-bit RGB)" {
    const allocator = std.testing.allocator;
    var img = try jp2z.decode(allocator, d1_colr_j2c);
    defer img.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 256), img.width);
    try std.testing.expectEqual(@as(u32, 149), img.height);
    try std.testing.expectEqual(@as(u8, 3), img.channels);
    try std.testing.expectEqual(@as(u8, 8), img.bits_per_sample);
    try std.testing.expectEqual(jp2z.PixelLayout.rgb, img.layout);
    try std.testing.expectEqual(@as(usize, 256 * 149 * 3), img.pixels.len);
}

test "decode JP2 container: file1.jp2 (768x512, 8-bit RGB)" {
    const allocator = std.testing.allocator;
    var img = try jp2z.decode(allocator, file1_jp2);
    defer img.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 768), img.width);
    try std.testing.expectEqual(@as(u32, 512), img.height);
    try std.testing.expectEqual(@as(u8, 3), img.channels);
    try std.testing.expectEqual(@as(u8, 8), img.bits_per_sample);
    try std.testing.expectEqual(jp2z.PixelLayout.rgb, img.layout);
    try std.testing.expectEqual(@as(usize, 768 * 512 * 3), img.pixels.len);
}

test "decode JP2 container: file9.jp2 (768x512, palette-indexed → 3ch RGB)" {
    // file9.jp2 has a single-component codestream wrapped in a JP2
    // container with `pclr` (palette) + `cmap` boxes. The decoder
    // applies the palette and outputs 3-channel RGB. Phase 2
    // cleanroom must mirror this for byte-perfect oracle parity.
    const allocator = std.testing.allocator;
    var img = try jp2z.decode(allocator, file9_jp2);
    defer img.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 768), img.width);
    try std.testing.expectEqual(@as(u32, 512), img.height);
    try std.testing.expectEqual(@as(u8, 3), img.channels);
    try std.testing.expectEqual(@as(u8, 8), img.bits_per_sample);
    try std.testing.expectEqual(jp2z.PixelLayout.rgb, img.layout);
    try std.testing.expectEqual(@as(usize, 768 * 512 * 3), img.pixels.len);
}

test "internal.openjpegDecode bypasses the public dispatcher" {
    const allocator = std.testing.allocator;
    var img = try jp2z.internal.openjpegDecode(allocator, c1_mono_j2c);
    defer img.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 303), img.width);
    try std.testing.expectEqual(@as(u32, 179), img.height);
}

test "corpus: decode p0_04.j2k from pinned openjpeg-data flake input" {
    // Reads from $OPENJPEG_DATA (set by the Nix devShell and the
    // test derivation; see flake.nix → openjpeg-data input). Skips
    // when the env var is unset so plain `zig build test` outside
    // Nix still works.
    //
    // Notes on Zig 0.16 std restructure:
    //   - std.process.getEnvVarOwned is gone; we use std.c.getenv
    //     directly (requires link_libc, set on this module).
    //   - std.fs.openFileAbsolute moved under std.Io.Dir and takes
    //     a threaded Io context (std.testing.io is the test default).
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const data_root_z = std.c.getenv("OPENJPEG_DATA") orelse return error.SkipZigTest;
    const data_root = std.mem.span(data_root_z);

    const fixture_path = try std.fs.path.join(allocator, &.{ data_root, "input", "conformance", "p0_04.j2k" });
    defer allocator.free(fixture_path);

    var file = try std.Io.Dir.openFileAbsolute(io, fixture_path, .{});
    defer file.close(io);
    var file_reader = file.reader(io, &.{});
    const data = try file_reader.interface.allocRemaining(allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(data);

    var img = try jp2z.decode(allocator, data);
    defer img.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 640), img.width);
    try std.testing.expectEqual(@as(u32, 480), img.height);
    try std.testing.expectEqual(@as(u8, 3), img.channels);
    try std.testing.expectEqual(@as(u8, 8), img.bits_per_sample);
    try std.testing.expectEqual(jp2z.PixelLayout.rgb, img.layout);
}

// ── Cleanroom decode route vs the openjpeg wrapper (MFIC differential) ──
//
// `decodeToImage` is the wrapper-free route that `decode` switches to when
// openjpeg leaves the runtime build. The wrapper is the causally
// independent oracle for the whole Image contract: dims, channels,
// precision, layout, colour space and every sample (exact for 5/3,
// within 1 for 9/7's fixed-point reconstruction).

const a5_mono_j2c = @embedFile("fixtures/conformance/a5_mono.j2c");
const e1_colr_j2c = @embedFile("fixtures/conformance/e1_colr.j2c");
const p1_04_j2k = @embedFile("fixtures/conformance/p1_04.j2k");
const p0_06_j2k = @embedFile("fixtures/conformance/p0_06.j2k");
const balloon_jp2 = @embedFile("fixtures/conformance/balloon_eciRGB_icc.jp2");

fn expectMatchesWrapper(data: []const u8, tolerance: i64) !void {
    const allocator = std.testing.allocator;
    var ours = try jp2z.internal.decodeToImage(allocator, data);
    defer ours.deinit(allocator);
    var oj = try jp2z.internal.openjpegDecode(allocator, data);
    defer oj.deinit(allocator);
    try std.testing.expectEqual(oj.width, ours.width);
    try std.testing.expectEqual(oj.height, ours.height);
    try std.testing.expectEqual(oj.channels, ours.channels);
    try std.testing.expectEqual(oj.bits_per_sample, ours.bits_per_sample);
    try std.testing.expectEqual(oj.layout, ours.layout);
    try std.testing.expectEqual(oj.source_color_space, ours.source_color_space);
    try std.testing.expectEqual(oj.pixels.len, ours.pixels.len);
    var max_abs: i64 = 0;
    if (oj.bits_per_sample > 8) {
        for (oj.pixelsU16(), ours.pixelsU16()) |a, b| max_abs = @max(max_abs, @as(i64, @intCast(@abs(@as(i64, a) - @as(i64, b)))));
    } else {
        for (oj.pixels, ours.pixels) |a, b| max_abs = @max(max_abs, @as(i64, @intCast(@abs(@as(i64, a) - @as(i64, b)))));
    }
    try std.testing.expect(max_abs <= tolerance);
}

test "decodeToImage == openjpeg wrapper: 5/3 fixtures byte-exact (c1_mono, file1, file9 palette)" {
    try expectMatchesWrapper(c1_mono_j2c, 0);
    try expectMatchesWrapper(file1_jp2, 0);
    try expectMatchesWrapper(file9_jp2, 0);
}

test "decodeToImage == openjpeg wrapper: 9/7 fixtures within 1 (d1_colr, a5_mono, e1_colr, p1_04 12-bit, p0_06 mixed+sub-sampled, balloon)" {
    try expectMatchesWrapper(d1_colr_j2c, 1);
    try expectMatchesWrapper(a5_mono_j2c, 1);
    try expectMatchesWrapper(e1_colr_j2c, 1);
    try expectMatchesWrapper(p1_04_j2k, 1);
    try expectMatchesWrapper(p0_06_j2k, 1);
    try expectMatchesWrapper(balloon_jp2, 1);
}
