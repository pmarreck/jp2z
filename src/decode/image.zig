//! Planar cleanroom output → the public interleaved `Image`.
//!
//! This is the contract the Phase-1 openjpeg wrapper established and that
//! consumers (the C ABI, `validate`) already rely on: a canvas at the
//! finest sub-sampling with coarser components replicated by nearest
//! neighbour, the JP2 palette applied through `cmap` (pclr / cmap,
//! T.800 I.5.3.4-5), samples clamped to [0, 2^prec−1] (signed components
//! lose their negatives, as the wrapper did), u8 or u16 storage, colour
//! space from `colr` (I.5.3.3) and layout from the channel count.
//! `decode` is the wrapper-free route; the wrapper stays an oracle.
const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../core/types.zig");
const errors = @import("../core/errors.zig");
const codestream = @import("codestream.zig");
const reconstruct = @import("reconstruct.zig");

inline fn ceilDiv(a: u32, b: u32) u32 {
    return (a + b - 1) / b;
}

/// Validate once, reconstruct through the cleanroom decoder, then shape
/// the planes into the public `Image`. Structural failures that stop the
/// walk map to InvalidJp2Codestream; valid-but-unsupported features to
/// NotImplemented (the C ABI's -1, documented as such).
pub fn decode(allocator: Allocator, data: []const u8) errors.DecodeError!types.Image {
    if (data.len < 4) return error.TruncatedStream;
    var report = try codestream.validate(allocator, data);
    defer report.deinit(allocator);
    const params = report.coding_params orelse return error.InvalidJp2Codestream;
    var img = reconstruct.decodeFromReport(allocator, data, &report) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooManyComponents, error.UnsupportedTileCodingOverride, error.UnsupportedHtCodeBlocks, error.MctNonUniformSubsampling => error.NotImplemented,
        else => error.InvalidJp2Codestream,
    };
    defer img.deinit(allocator);
    return toImage(allocator, &img, params, &report);
}

/// Shape planar cleanroom output into the public `Image`.
pub fn toImage(allocator: Allocator, img: *const reconstruct.Image, params: codestream.CodingParams, report: *const codestream.ValidationReport) errors.DecodeError!types.Image {
    const ncomp: usize = img.num_components;
    if (ncomp == 0) return error.InvalidJp2Codestream;
    const image_w = report.width orelse return error.InvalidJp2Codestream;
    const image_h = report.height orelse return error.InvalidJp2Codestream;
    const xsiz = params.image_x0 + image_w;
    const ysiz = params.image_y0 + image_h;

    // Output channels: cmap's outputs when a palette is present, else the
    // codestream components. The wrapper (openjpeg) accepted 1, 3 or 4.
    const has_cmap = report.cmap.len > 0 and report.palette != null;
    const channels: usize = if (has_cmap) report.cmap.len else ncomp;
    const num_ch: u8 = switch (channels) {
        1, 3, 4 => @intCast(channels),
        else => return error.BackendError,
    };
    const layout: types.PixelLayout = switch (num_ch) {
        1 => .grayscale,
        3 => .rgb,
        else => .cmyk,
    };

    // Per-channel source component, palette column, and precision; all
    // channels must share one precision (the Image contract).
    var src_comp: [4]usize = undefined;
    var pal_col: [4]?u8 = .{ null, null, null, null };
    var prec: u8 = 0;
    var k: usize = 0;
    while (k < channels) : (k += 1) {
        var cmp: usize = k;
        if (has_cmap) {
            const e = report.cmap[k];
            cmp = e.cmp;
            if (e.mtyp == 1) pal_col[k] = e.pcol;
        }
        if (cmp >= ncomp) return error.InvalidJp2Codestream;
        src_comp[k] = cmp;
        const p: u8 = if (pal_col[k]) |col| blk: {
            const pal = report.palette.?;
            if (col >= pal.npc) return error.InvalidJp2Codestream;
            break :blk pal.depths[col];
        } else img.precs[cmp];
        if (k == 0) prec = p else if (p != prec) return error.BackendError;
    }
    if (prec == 0 or prec > 16) return error.UnsupportedPrecision;

    // Canvas at the finest sub-sampling (the wrapper's rule).
    var min_dx: u32 = std.math.maxInt(u32);
    var min_dy: u32 = std.math.maxInt(u32);
    var c: usize = 0;
    while (c < ncomp) : (c += 1) {
        const ci = @min(c, 15);
        min_dx = @min(min_dx, params.comp_dx[ci]);
        min_dy = @min(min_dy, params.comp_dy[ci]);
    }
    const width: u32 = ceilDiv(image_w, min_dx);
    const height: u32 = ceilDiv(image_h, min_dy);
    var comp_w: [16]u32 = @splat(0);
    var comp_h: [16]u32 = @splat(0);
    c = 0;
    while (c < ncomp and c < 16) : (c += 1) {
        const dx = params.comp_dx[c];
        const dy = params.comp_dy[c];
        comp_w[c] = ceilDiv(xsiz, dx) - ceilDiv(params.image_x0, dx);
        comp_h[c] = ceilDiv(ysiz, dy) - ceilDiv(params.image_y0, dy);
    }

    const bytes_per_sample: usize = if (prec > 8) 2 else 1;
    const pixel_count: usize = @as(usize, width) * @as(usize, height);
    const pixels = try allocator.alloc(u8, pixel_count * channels * bytes_per_sample);
    errdefer allocator.free(pixels);
    const max_val: i64 = (@as(i64, 1) << @intCast(prec)) - 1;
    const out16: []align(1) u16 = if (prec > 8) std.mem.bytesAsSlice(u16, pixels) else &.{};

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const pixel_idx: usize = @as(usize, y) * width + x;
            k = 0;
            while (k < channels) : (k += 1) {
                const cmp = src_comp[k];
                const ci = @min(cmp, 15);
                const dx = params.comp_dx[ci];
                const dy = params.comp_dy[ci];
                const cx: u32 = @min((x * min_dx) / dx, comp_w[ci] - 1);
                const cy: u32 = @min((y * min_dy) / dy, comp_h[ci] - 1);
                var v: i64 = img.planes[cmp][@as(usize, cy) * comp_w[ci] + cx];
                if (pal_col[k]) |col| {
                    const pal = report.palette.?;
                    const idx: usize = @intCast(std.math.clamp(v, 0, @as(i64, pal.ne) - 1));
                    v = pal.entries[idx * pal.npc + col];
                }
                const clamped: u16 = @intCast(std.math.clamp(v, 0, max_val));
                if (prec > 8) out16[pixel_idx * channels + k] = clamped else pixels[pixel_idx * channels + k] = @intCast(clamped);
            }
        }
    }

    const source_cs: types.ColorSpace = if (report.colr_enumcs) |cs| switch (cs) {
        16 => .srgb,
        17 => .greyscale_jp2,
        else => if (num_ch == 1) .greyscale_jp2 else .srgb,
    } else if (num_ch == 1) .greyscale_jp2 else .srgb;

    return types.Image{
        .pixels = pixels,
        .width = width,
        .height = height,
        .channels = num_ch,
        .bits_per_sample = prec,
        .source_color_space = source_cs,
        .layout = layout,
    };
}
