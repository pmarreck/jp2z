//! C ABI surface for jp2z. Mirrors the shape of jpegz's
//! `jpegz_jp2_*` C surface (see `jpegz/include/jpegz_core.h`) so
//! the planned jpegz integration shim can either alias jp2z symbols
//! directly or thin-wrap them with zero translation cost.

const std = @import("std");
const errors = @import("../core/errors.zig");
const jp2z = @import("../jp2z.zig");

const c_allocator = std.heap.c_allocator;

// ─────────────────────────────────────────────────────────────────────
// Status / error mapping
// ─────────────────────────────────────────────────────────────────────

fn toCStatus(err: errors.DecodeError) c_int {
    return switch (err) {
        error.NotImplemented        => -1,
        error.InvalidMarker         => -2,
        error.UnsupportedPrecision  => -3,
        error.TruncatedStream       => -4,
        error.BackendError          => -6,
        error.InvalidJp2Codestream  => -7,
        error.OutOfMemory           => -8,
        error.CallbackAborted       => -9,
    };
}

// ─────────────────────────────────────────────────────────────────────
// Thread-local last-error
// ─────────────────────────────────────────────────────────────────────

const last_error = @import("../core/last_error.zig");
const clearLastError = last_error.clear;
const setLastError = last_error.set;

export fn jp2z_last_error_message() [*:0]const u8 {
    return last_error.cPtr();
}

// ─────────────────────────────────────────────────────────────────────
// jp2z_image_t — C-side mirror of `jp2z.Image`
// ─────────────────────────────────────────────────────────────────────

const CImage = extern struct {
    pixels: ?[*]u8,
    pixels_len: usize,
    width: u32,
    height: u32,
    channels: u8,
    bits_per_sample: u8,
    source_color_space: c_int,
    layout: c_int,
};

fn writeImageToC(out: *CImage, img: jp2z.Image) void {
    out.pixels = img.pixels.ptr;
    out.pixels_len = img.pixels.len;
    out.width = img.width;
    out.height = img.height;
    out.channels = img.channels;
    out.bits_per_sample = img.bits_per_sample;
    out.source_color_space = @intCast(@intFromEnum(img.source_color_space));
    out.layout = @intCast(@intFromEnum(img.layout));
}

export fn jp2z_image_free(image: ?*CImage) void {
    const im = image orelse return;
    if (im.pixels) |p| {
        const slice: []u8 = p[0..im.pixels_len];
        c_allocator.free(slice);
    }
    im.* = std.mem.zeroes(CImage);
}

// ─────────────────────────────────────────────────────────────────────
// jp2z_decode / jp2z_decode_ex
// ─────────────────────────────────────────────────────────────────────

const CDecodeOptions = extern struct {
    threads: u8,
    lenient: u8,
    reserved: [6]u8,
};

fn buildDecodeOptions(
    c_options: ?*const CDecodeOptions,
    sink: ?*jp2z.FindingsSink,
) jp2z.DecodeOptions {
    if (c_options) |co| {
        return .{
            .threads = co.threads,
            .lenient = co.lenient != 0,
            .findings_sink = sink,
        };
    }
    return .{ .findings_sink = sink };
}

export fn jp2z_decode(data: [*c]const u8, len: usize, out_image: ?*CImage) c_int {
    return doDecodeWithOptions(data, len, null, null, out_image);
}

export fn jp2z_decode_ex(
    data: [*c]const u8,
    len: usize,
    options: ?*const CDecodeOptions,
    out_image: ?*CImage,
) c_int {
    return doDecodeWithOptions(data, len, options, null, out_image);
}

export fn jp2z_decode_with_findings(
    data: [*c]const u8,
    len: usize,
    options: ?*const CDecodeOptions,
    sink: ?*jp2z.FindingsSink,
    out_image: ?*CImage,
) c_int {
    return doDecodeWithOptions(data, len, options, sink, out_image);
}

fn doDecodeWithOptions(
    data: [*c]const u8,
    len: usize,
    c_options: ?*const CDecodeOptions,
    sink: ?*jp2z.FindingsSink,
    out_image: ?*CImage,
) c_int {
    clearLastError();
    const out = out_image orelse {
        setLastError("out_image must not be NULL", .{});
        return -3;
    };
    const slice: []const u8 = if (data == null or len == 0) &[_]u8{} else data[0..len];
    const opts = buildDecodeOptions(c_options, sink);
    const img = jp2z.decodeWithOptions(c_allocator, slice, opts) catch |err| {
        setLastError("jp2z_decode failed: {s}", .{@errorName(err)});
        return toCStatus(err);
    };
    writeImageToC(out, img);
    return 0;
}

// ─────────────────────────────────────────────────────────────────────
// FindingsSink C ABI
// ─────────────────────────────────────────────────────────────────────

const CFindingsSink = jp2z.FindingsSink;

export fn jp2z_findings_sink_create() ?*CFindingsSink {
    clearLastError();
    const sink = c_allocator.create(CFindingsSink) catch {
        setLastError("findings_sink_create: out of memory", .{});
        return null;
    };
    sink.* = jp2z.FindingsSink.init(c_allocator);
    return sink;
}

export fn jp2z_findings_sink_free(sink_opt: ?*CFindingsSink) void {
    const sink = sink_opt orelse return;
    sink.deinit();
    c_allocator.destroy(sink);
}

export fn jp2z_findings_sink_count(sink_opt: ?*const CFindingsSink) usize {
    const sink = sink_opt orelse return 0;
    return sink.items().len;
}

const CSinkFinding = extern struct {
    severity: c_int,
    code: c_int,
    offset: i64,
    detail: ?[*]const u8,
    detail_len: usize,
};

export fn jp2z_findings_sink_get(
    sink_opt: ?*const CFindingsSink,
    idx: usize,
    out_finding: ?*CSinkFinding,
) c_int {
    clearLastError();
    const sink = sink_opt orelse {
        setLastError("findings_sink_get: sink must not be NULL", .{});
        return -3;
    };
    const out = out_finding orelse {
        setLastError("findings_sink_get: out_finding must not be NULL", .{});
        return -3;
    };
    const items = sink.items();
    if (idx >= items.len) {
        setLastError("findings_sink_get: idx {d} out of range (count={d})",
            .{ idx, items.len });
        return -1;
    }
    const f = items[idx];
    out.severity = @intCast(@intFromEnum(f.severity));
    out.code = @intCast(@intFromEnum(f.code));
    if (f.offset) |o| {
        out.offset = @intCast(o);
    } else {
        out.offset = std.math.minInt(i64);
    }
    out.detail = if (f.detail) |d| d.ptr else null;
    out.detail_len = if (f.detail) |d| d.len else 0;
    return 0;
}

// ─────────────────────────────────────────────────────────────────────
// Version
// ─────────────────────────────────────────────────────────────────────

export fn jp2z_version() [*:0]const u8 {
    return jp2z.version.ptr;
}
