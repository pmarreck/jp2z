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
    channels: u16,
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
// Deep strict validation (jp2z's `validate`-facing entry point)
// ─────────────────────────────────────────────────────────────────────

/// Structural walk PLUS a full entropy decode, emitting deep-integrity
/// findings that permissive decoders never report. `strict` != 0 escalates
/// those findings to FAIL. Findings are pushed into `sink` (may be NULL).
/// Returns the report's overall severity (>= 0: pass/info/warn/fail per the
/// Severity enum) or a negative status on error.
export fn jp2z_deep_validate(
    data: [*c]const u8,
    len: usize,
    strict: c_int,
    sink: ?*jp2z.FindingsSink,
) c_int {
    clearLastError();
    const slice: []const u8 = if (data == null or len == 0) &[_]u8{} else data[0..len];
    var report = jp2z.internal.deepValidate(c_allocator, slice, strict != 0) catch |err| {
        setLastError("jp2z_deep_validate failed: {s}", .{@errorName(err)});
        return toCStatus(err);
    };
    defer report.deinit(c_allocator);
    if (sink) |s| {
        for (report.findings.items) |f| {
            s.emit(f.severity, f.code, f.offset, f.detail) catch {
                setLastError("jp2z_deep_validate: sink out of memory", .{});
                return -2;
            };
        }
    }
    return @intCast(@intFromEnum(report.overall));
}

// ─────────────────────────────────────────────────────────────────────
// Version
// ─────────────────────────────────────────────────────────────────────

export fn jp2z_version() [*:0]const u8 {
    return jp2z.version.ptr;
}

// ─────────────────────────────────────────────────────────────────────
// Encode
// ─────────────────────────────────────────────────────────────────────

const CEncodeParams = extern struct {
    width: u32,
    height: u32,
    components: u16,
    precision: u8,
    levels: u8,
    format: u8,
    reserved: [7]u8,
};
comptime {
    std.debug.assert(@sizeOf(CEncodeParams) == 20); // header: "Total size 20 bytes"
}

const CBuffer = extern struct {
    data: ?[*]u8,
    len: usize,
};

const levels_default: u8 = 0xFF;
const format_j2k: u8 = 0;
const format_jp2: u8 = 1;
const status_invalid_argument: c_int = -10;
const status_encode_failed: c_int = -11;

export fn jp2z_buffer_free(buffer: ?*CBuffer) void {
    const b = buffer orelse return;
    if (b.data) |d| c_allocator.free(d[0..b.len]);
    b.* = .{ .data = null, .len = 0 };
}

/// C entry to the lossless encoder: validates the caller's struct and byte
/// count, de-interleaves the jp2z_image_t-layout samples (u8, or native u16
/// above 8 bits) into per-component i32 planes, and hands the encoded bytes
/// back in a c_allocator buffer released by jp2z_buffer_free.
export fn jp2z_encode(
    samples: [*c]const u8,
    samples_len: usize,
    params: ?*const CEncodeParams,
    out: ?*CBuffer,
) c_int {
    clearLastError();
    const o = out orelse {
        setLastError("jp2z_encode: out must not be NULL", .{});
        return status_invalid_argument;
    };
    o.* = .{ .data = null, .len = 0 };
    const p = params orelse {
        setLastError("jp2z_encode: params must not be NULL", .{});
        return status_invalid_argument;
    };
    for (p.reserved) |r| if (r != 0) {
        setLastError("jp2z_encode: reserved bytes must be zero", .{});
        return status_invalid_argument;
    };
    if (p.format != format_j2k and p.format != format_jp2) {
        setLastError("jp2z_encode: unknown format {d}", .{p.format});
        return status_invalid_argument;
    }
    if (p.precision == 0 or p.precision > 16) {
        setLastError("jp2z_encode: precision {d} is outside 1..16", .{p.precision});
        return -3;
    }
    if (p.width == 0 or p.height == 0 or p.components == 0) {
        setLastError("jp2z_encode: width, height and components must be nonzero", .{});
        return status_invalid_argument;
    }
    const bps: usize = if (p.precision > 8) 2 else 1;
    const pixels = std.math.mul(usize, p.width, p.height) catch return tooLarge();
    const count = std.math.mul(usize, pixels, p.components) catch return tooLarge();
    const want = std.math.mul(usize, count, bps) catch return tooLarge();
    if (samples_len != want) {
        setLastError("jp2z_encode: samples_len is {d} bytes; {d}x{d}x{d} at precision {d} needs {d}", .{ samples_len, p.width, p.height, p.components, p.precision, want });
        return status_invalid_argument;
    }
    if (samples == null) {
        setLastError("jp2z_encode: samples must not be NULL", .{});
        return status_invalid_argument;
    }
    const bytes = samples[0..want];

    var arena_state = std.heap.ArenaAllocator.init(c_allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const planes = ar.alloc([]i32, p.components) catch return outOfMemory();
    for (planes) |*pl| pl.* = ar.alloc(i32, pixels) catch return outOfMemory();
    const nc: usize = p.components;
    for (0..pixels) |i| for (0..nc) |c| {
        const k = i * nc + c;
        planes[c][i] = if (bps == 1) bytes[k] else std.mem.bytesToValue(u16, bytes[k * 2 ..][0..2]);
    };

    const ep: jp2z.encode.Params = .{
        .width = p.width,
        .height = p.height,
        .components = p.components,
        .precision = p.precision,
        .levels = if (p.levels == levels_default) null else p.levels,
    };
    const consts: []const []const i32 = @ptrCast(planes);
    const encoded = (if (p.format == format_jp2) jp2z.encode.encodeJp2(c_allocator, consts, ep) else jp2z.encode.encodeJ2k(c_allocator, consts, ep)) catch |err| {
        setLastError("jp2z_encode failed: {s}", .{@errorName(err)});
        return switch (err) {
            error.OutOfMemory => -8,
            error.UnsupportedPrecision => -3,
            error.CoefficientOverflow, error.CarryIntoSentinel => status_encode_failed,
            error.InvalidDimensions, error.InvalidComponents, error.PlaneSizeMismatch, error.InvalidLevels, error.SampleOutOfRange => status_invalid_argument,
        };
    };
    o.* = .{ .data = encoded.ptr, .len = encoded.len };
    return 0;
}

fn tooLarge() c_int {
    setLastError("jp2z_encode: image size overflows size_t", .{});
    return status_invalid_argument;
}

fn outOfMemory() c_int {
    setLastError("jp2z_encode: out of memory", .{});
    return -8;
}
