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
