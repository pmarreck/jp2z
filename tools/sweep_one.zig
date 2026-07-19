//! Conformance-sweep worker: decode ONE JP2/J2K fixture with the pure-Zig
//! `internal.decodeCleanroom` and classify the result on a single JSON line.
//!
//! Run one fixture per process so a panic on an unsupported profile is
//! isolated (the `./sweep` driver treats a non-zero exit / missing JSON as
//! CRASH). On a clean run this always exits 0 and prints exactly one line.
//!
//! Where the in-process openjpeg wrapper (`internal.openjpegDecode`) is a
//! valid oracle — non-sub-sampled, unsigned, uniform precision, matching
//! dims — we compute max_abs vs the cleanroom planes and grade PASS
//! (byte-exact) / NEAR (≤1, lossy 9/7 tolerance) / FAIL. Otherwise we report
//! DECODED + an honest skip reason rather than a misleading FAIL (the wrapper
//! upsamples sub-sampled comps to the reference grid and clamps signed comps,
//! so it cannot be diffed against component-resolution signed planes).

const std = @import("std");
const jp2z = @import("jp2z");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 0.16 file I/O needs an Io context; this exe gets its own (tests use
    // std.testing.io). page_allocator is threadsafe and only touched if we
    // call Io.async, which we never do here.
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Fixture path via env var: std.process.argsAlloc is gone in 0.16, and
    // std.c.getenv mirrors how decode.zig reads OPENJPEG_DATA. Must be absolute.
    const path_z = std.c.getenv("SWEEP_FIXTURE") orelse {
        std.debug.print("usage: SWEEP_FIXTURE=<absolute-path> jp2z-sweep-one\n", .{});
        std.process.exit(2);
    };
    const path = std.mem.span(path_z);
    const name = std.fs.path.basename(path);

    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |e| {
        try emit(name, "IO_ERROR", @errorName(e), null, null, null, 0);
        return;
    };
    defer file.close(io);
    var file_reader = file.reader(io, &.{});
    const data = file_reader.interface.allocRemaining(a, .limited(64 * 1024 * 1024)) catch |e| {
        try emit(name, "IO_ERROR", @errorName(e), null, null, null, 0);
        return;
    };

    // 1) The pure-Zig decode under test. A returned error is a valid
    //    classification (ERROR + name); only a panic escapes to CRASH.
    var img = jp2z.internal.decodeCleanroom(a, data) catch |e| {
        try emit(name, "ERROR", @errorName(e), null, null, null, 0);
        return;
    };
    const cw = img.width;
    const ch = img.height;
    const cc = img.num_components;

    // 2) Pull signedness / sub-sampling so we know whether the wrapper oracle
    //    is comparable. inspect() reuses the same validate() walk.
    const cp = jp2z.internal.inspect(a, data) catch null;
    var any_signed = false;
    var any_subsampled = false;
    if (cp) |p| {
        var i: usize = 0;
        while (i < cc and i < 16) : (i += 1) {
            if ((p.comp_signed >> @intCast(i)) & 1 != 0) any_signed = true;
            if (p.comp_dx[i] != 1 or p.comp_dy[i] != 1) any_subsampled = true;
        }
    }

    // 3) PREFERRED oracle: a committed planar `.pix` (raw opj_decompress
    //    output, de-interleaved to per-component planes at COMPONENT
    //    resolution). Passed by the ./sweep driver via SWEEP_PIX when the file
    //    exists. Unlike the in-process wrapper it is directly comparable to the
    //    cleanroom's component-resolution planes — so sub-sampled fixtures
    //    (p0_10) grade honestly instead of skip:dim-mismatch. The `.pix` is a
    //    causally-independent external oracle (opj CLI), a stronger diff than
    //    the wrapper. Only used when its size matches the cleanroom sample
    //    count exactly (1 byte/sample, u8) — a mismatched/stale `.pix` falls
    //    through to the wrapper rather than producing a bogus verdict.
    if (std.c.getenv("SWEEP_PIX")) |pix_z| {
        if (readPix(io, a, std.mem.span(pix_z))) |pix| {
            if (comparePix(&img, pix)) |max_abs| {
                const status = if (max_abs == 0) "PASS" else if (max_abs <= 1) "NEAR" else "FAIL";
                try emit(name, status, "oracle:pix", cw, ch, cc, max_abs);
                return;
            }
        }
    }

    // 4) Fallback oracle: the in-process openjpeg wrapper.
    const oracle = jp2z.internal.openjpegDecode(a, data) catch |e| {
        try emit(name, "DECODED", "oracle-failed", cw, ch, cc, 0);
        std.debug.print("# {s}: oracle openjpegDecode error: {s}\n", .{ name, @errorName(e) });
        return;
    };

    // 5) No usable `.pix`: decide whether the wrapper diff is meaningful.
    if (any_signed) {
        try emit(name, "DECODED", "skip:signed", cw, ch, cc, 0);
        return;
    }
    if (any_subsampled or cw != oracle.width or ch != oracle.height or cc != @as(u16, oracle.channels)) {
        try emit(name, "DECODED", "skip:dim-mismatch", cw, ch, cc, 0);
        std.debug.print("# {s}: cleanroom {d}x{d}x{d} vs oracle {d}x{d}x{d} (sub-sampled?)\n", .{ name, cw, ch, cc, oracle.width, oracle.height, oracle.channels });
        return;
    }

    const max_abs = compare(&img, oracle);
    const status = if (max_abs == 0) "PASS" else if (max_abs <= 1) "NEAR" else "FAIL";
    try emit(name, status, "", cw, ch, cc, max_abs);
}

/// max_abs over every component sample: cleanroom plane (i32, level-shifted)
/// vs the wrapper's interleaved pixels (de-interleaved here). u8 or u16 by
/// bit depth.
fn compare(img: *jp2z.internal.CleanroomImage, oracle: jp2z.Image) i64 {
    const n: usize = @as(usize, img.width) * @as(usize, img.height);
    const comps: usize = img.num_components;
    var max_abs: i64 = 0;
    if (oracle.bits_per_sample > 8) {
        const px = oracle.pixelsU16();
        var c: usize = 0;
        while (c < comps) : (c += 1) {
            const plane = img.planes[c];
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const d: i64 = @as(i64, plane[i]) - @as(i64, px[i * comps + c]);
                const ad = if (d < 0) -d else d;
                if (ad > max_abs) max_abs = ad;
            }
        }
    } else {
        var c: usize = 0;
        while (c < comps) : (c += 1) {
            const plane = img.planes[c];
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const d: i64 = @as(i64, plane[i]) - @as(i64, oracle.pixels[i * comps + c]);
                const ad = if (d < 0) -d else d;
                if (ad > max_abs) max_abs = ad;
            }
        }
    }
    return max_abs;
}

/// Read a committed planar `.pix` oracle from disk. Returns null on any I/O
/// error (the caller then falls back to the wrapper oracle).
fn readPix(io: std.Io, a: std.mem.Allocator, path: []const u8) ?[]u8 {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    var fr = file.reader(io, &.{});
    return fr.interface.allocRemaining(a, .limited(64 * 1024 * 1024)) catch null;
}

/// max_abs of the cleanroom planes vs a PLANAR u8 `.pix` oracle
/// (plane0 ++ plane1 ++ …, one byte per sample, at component resolution).
/// Returns null when the `.pix` byte count doesn't equal the total cleanroom
/// sample count — i.e. it isn't a 1-byte/sample planar oracle for THIS decode
/// (wrong file, stale dims, or a >8-bit depth we don't diff here) — so a
/// size-mismatched oracle is ignored rather than mis-graded. complexity: O(samples).
fn comparePix(img: *jp2z.internal.CleanroomImage, pix: []const u8) ?i64 {
    var total: usize = 0;
    var c: usize = 0;
    while (c < img.num_components) : (c += 1) total += img.planes[c].len;
    if (pix.len != total) return null;

    var max_abs: i64 = 0;
    var off: usize = 0;
    c = 0;
    while (c < img.num_components) : (c += 1) {
        const plane = img.planes[c];
        var i: usize = 0;
        while (i < plane.len) : (i += 1) {
            const d: i64 = @as(i64, plane[i]) - @as(i64, pix[off + i]);
            const ad = if (d < 0) -d else d;
            if (ad > max_abs) max_abs = ad;
        }
        off += plane.len;
    }
    return max_abs;
}

/// One NDJSON record on stdout. The `./sweep` driver aggregates these.
fn emit(name: []const u8, status: []const u8, detail: []const u8, w: ?u32, h: ?u32, comps: ?u16, max_abs: i64) !void {
    // One NDJSON record per fixture. Routed through std.debug.print (stderr)
    // because std.io.getStdOut / fixedBufferStream were removed in the 0.16
    // I/O reorg; the ./sweep driver greps lines beginning with '{'.
    std.debug.print("{{\"fixture\":\"{s}\",\"status\":\"{s}\",\"detail\":\"{s}\",\"w\":{?d},\"h\":{?d},\"comps\":{?d},\"max_abs\":{d}}}\n", .{ name, status, detail, w, h, comps, max_abs });
}
