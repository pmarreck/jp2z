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

    // 3) Oracle: the in-process openjpeg wrapper.
    const oracle = jp2z.internal.openjpegDecode(a, data) catch |e| {
        try emit(name, "DECODED", "oracle-failed", cw, ch, cc, 0);
        std.debug.print("# {s}: oracle openjpegDecode error: {s}\n", .{ name, @errorName(e) });
        return;
    };

    // 4) Decide whether a diff is meaningful, then grade it.
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

/// One NDJSON record on stdout. The `./sweep` driver aggregates these.
fn emit(name: []const u8, status: []const u8, detail: []const u8, w: ?u32, h: ?u32, comps: ?u16, max_abs: i64) !void {
    // One NDJSON record per fixture. Routed through std.debug.print (stderr)
    // because std.io.getStdOut / fixedBufferStream were removed in the 0.16
    // I/O reorg; the ./sweep driver greps lines beginning with '{'.
    std.debug.print("{{\"fixture\":\"{s}\",\"status\":\"{s}\",\"detail\":\"{s}\",\"w\":{?d},\"h\":{?d},\"comps\":{?d},\"max_abs\":{d}}}\n", .{ name, status, detail, w, h, comps, max_abs });
}
