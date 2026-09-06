//! Per-tile max_abs histogram: cleanroom decode vs the in-process openjpeg
//! oracle on ONE fixture (SWEEP_FIXTURE=<abs-path>), printing every tile
//! whose max_abs exceeds 1 with the first offending sample. Diagnostic for
//! decode-divergence hunts (which tiles / which component / how big) — the
//! sweep only reports a whole-image max_abs. Non-sub-sampled fixtures only
//! (the wrapper oracle is at reference-grid resolution).
const std = @import("std");
const jp2z = @import("jp2z");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = std.mem.span(std.c.getenv("SWEEP_FIXTURE") orelse {
        std.debug.print("usage: SWEEP_FIXTURE=<absolute-path> jp2z-tile-hist\n", .{});
        std.process.exit(2);
    });
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var fr = file.reader(io, &.{});
    const data = try fr.interface.allocRemaining(a, .limited(64 * 1024 * 1024));

    // Strict findings first: a decode divergence often has a validator
    // symptom (a false c25x on a valid file) and vice versa.
    {
        var rep = try jp2z.deepValidate(a, data, true);
        defer rep.deinit(a);
        std.debug.print("deepValidate(strict): overall={s}, {d} findings\n", .{ @tagName(rep.overall), rep.findings.items.len });
        for (rep.findings.items) |f| {
            if (f.severity == .warn or f.severity == .fail) {
                std.debug.print("  {s} {s} @{?d} {s}\n", .{ @tagName(f.severity), @tagName(f.code), f.offset, f.detail orelse "" });
            }
        }
    }
    const img = jp2z.internal.decodeCleanroom(a, data) catch |e| {
        std.debug.print("decodeCleanroom failed: {s}\n", .{@errorName(e)});
        std.process.exit(3);
    };
    const oracle = try jp2z.internal.openjpegDecode(a, data);
    const p = (try jp2z.internal.inspect(a, data)) orelse return error.NoCodingParams;
    const w = img.width;
    const h = img.height;
    const comps: usize = img.num_components;
    if (w != oracle.width or h != oracle.height or comps != oracle.channels) return error.OracleDimMismatch;
    const xsiz = p.image_x0 + w;
    const ysiz = p.image_y0 + h;
    const nt = p.numTilesXY(xsiz, ysiz);
    std.debug.print("{s}: {d}x{d}x{d}, {d}x{d} tiles of {d}x{d}, decomp {d}, {s}\n", .{ std.fs.path.basename(path), w, h, comps, nt.x, nt.y, p.tile_w, p.tile_h, p.num_decomp_levels, @tagName(p.wavelet) });
    var bad_tiles: u32 = 0;
    var t: u32 = 0;
    while (t < nt.x * nt.y) : (t += 1) {
        const tr = p.tileRect(xsiz, ysiz, t);
        var m: i64 = 0;
        var fx: u32 = 0;
        var fy: u32 = 0;
        var fc: usize = 0;
        var ours: i32 = 0;
        var oj: i32 = 0;
        var y = tr.y0;
        while (y < tr.y1) : (y += 1) {
            var x = tr.x0;
            while (x < tr.x1) : (x += 1) {
                var c: usize = 0;
                while (c < comps) : (c += 1) {
                    const i: usize = @as(usize, y - p.image_y0) * w + (x - p.image_x0);
                    const d: i64 = @as(i64, img.planes[c][i]) - @as(i64, oracle.pixels[i * comps + c]);
                    const ad = if (d < 0) -d else d;
                    if (ad > m) {
                        m = ad;
                        fx = x - tr.x0;
                        fy = y - tr.y0;
                        fc = c;
                        ours = img.planes[c][i];
                        oj = oracle.pixels[i * comps + c];
                    }
                }
            }
        }
        if (m > 1) {
            bad_tiles += 1;
            std.debug.print("tile {d} ({d},{d}) x[{d},{d}) y[{d},{d}) max_abs={d} first at local ({d},{d}) c{d} ours={d} oj={d}\n", .{ t, t % nt.x, t / nt.x, tr.x0, tr.x1, tr.y0, tr.y1, m, fx, fy, fc, ours, oj });
        }
    }
    std.debug.print("{d}/{d} tiles with max_abs > 1\n", .{ bad_tiles, nt.x * nt.y });
    if (std.c.getenv("JP2Z_DUMP_T1")) |dp| try t1Diff(a, io, data, std.mem.span(dp));
}

// ── Optional tier-1 differential (JP2Z_DUMP_T1) ─────────────────────
//
// When JP2Z_DUMP_T1 names a file, the patched openjpeg oracle appends one
// 'CBLK' record per decoded code-block during openjpegDecode (see
// patches/openjpeg-cblk-dump.patch). t1Diff() then decodes every jp2z plan
// and compares coefficient-for-coefficient, so a divergence can be
// attributed to tier-1 (mismatch here) or to dequant/DWT (match here).
// Delete the file before running: the oracle APPENDS.

const OracleRecord = struct {
    tile: u32,
    component: u32,
    resno: u32,
    orient: u32,
    cblk_x0: i32,
    cblk_y0: i32,
    numbps: u32,
    data: []i32,
};

fn parseOracleDump(a: std.mem.Allocator, dump: []const u8) ![]OracleRecord {
    var records: std.ArrayList(OracleRecord) = .empty;
    var pos: usize = 0;
    while (pos + 48 <= dump.len) {
        if (std.mem.readInt(u32, dump[pos..][0..4], .little) != 0x4B4C4243) return error.BadMagic;
        const dlen = std.mem.readInt(u32, dump[pos + 44 ..][0..4], .little);
        const data = try a.alloc(i32, dlen / 4);
        var i: usize = 0;
        while (i < data.len) : (i += 1) data[i] = std.mem.readInt(i32, dump[pos + 48 + i * 4 ..][0..4], .little);
        try records.append(a, .{
            .tile = std.mem.readInt(u32, dump[pos + 4 ..][0..4], .little),
            .component = std.mem.readInt(u32, dump[pos + 8 ..][0..4], .little),
            .resno = std.mem.readInt(u32, dump[pos + 12 ..][0..4], .little),
            .orient = std.mem.readInt(u32, dump[pos + 16 ..][0..4], .little),
            .cblk_x0 = std.mem.readInt(i32, dump[pos + 24 ..][0..4], .little),
            .cblk_y0 = std.mem.readInt(i32, dump[pos + 28 ..][0..4], .little),
            .numbps = std.mem.readInt(u32, dump[pos + 40 ..][0..4], .little),
            .data = data,
        });
        pos += 48 + dlen;
    }
    return records.toOwnedSlice(a);
}

fn t1Diff(a: std.mem.Allocator, io: std.Io, data: []const u8, dump_path: []const u8) !void {
    var file = try std.Io.Dir.openFileAbsolute(io, dump_path, .{});
    defer file.close(io);
    var fr = file.reader(io, &.{});
    const dump = try fr.interface.allocRemaining(a, .limited(256 * 1024 * 1024));
    const records = try parseOracleDump(a, dump);
    var list = try jp2z.internal.extractCblkPlans(a, data);
    defer list.deinit(a);
    const p = (try jp2z.internal.inspect(a, data)) orelse return error.NoCodingParams;
    const img_w = (try jp2z.internal.decodeCleanroom(a, data)).width;
    const img_h = (try jp2z.internal.decodeCleanroom(a, data)).height;
    const xsiz = p.image_x0 + img_w;
    const ysiz = p.image_y0 + img_h;
    var matched: u32 = 0;
    var mismatched: u32 = 0;
    var numbps_diff: u32 = 0;
    var shown: u32 = 0;
    // mismatch histogram by resolution (0..32) and band (0..3)
    var hist: [33][4]u32 = @splat(@splat(0));
    var total: [33][4]u32 = @splat(@splat(0));
    for (records) |rec| {
        for (list.plans) |plan| {
            if (plan.component != rec.component or plan.resolution != rec.resno or plan.band != rec.orient) continue;
            // Translate jp2z's tile-relative subband coords to absolute band coords.
            const tr = p.tileRect(xsiz, ysiz, plan.tile);
            const bo = jp2z.internal.bandOrigin(tr.x0, tr.y0, p.num_decomp_levels, plan.resolution, plan.band);
            const abs_x0 = bo.x0 + plan.sb_x0;
            const abs_y0 = bo.y0 + plan.sb_y0;
            if (abs_x0 != rec.cblk_x0 or abs_y0 != rec.cblk_y0) continue;
            matched += 1;
            total[plan.resolution][plan.band] += 1;
            if (@as(u32, plan.numbps) != rec.numbps) numbps_diff += 1;
            var cblk = try jp2z.internal.decodePlan(a, plan);
            defer cblk.deinit(a);
            var bad: usize = 0;
            var first_bad: ?usize = null;
            var k: usize = 0;
            while (k < cblk.coeffs.len and k < rec.data.len) : (k += 1) {
                const ours = jp2z.internal.coeffToOpenJpegI32(cblk.coeffs[k]);
                if (ours != rec.data[k]) {
                    bad += 1;
                    if (first_bad == null) first_bad = k;
                }
            }
            if (bad > 0 or cblk.coeffs.len != rec.data.len) {
                mismatched += 1;
                hist[plan.resolution][plan.band] += 1;
                if (shown < 12) {
                    shown += 1;
                    const fb = first_bad orelse 0;
                    std.debug.print("  MISMATCH tile {d} c{d} r{d} b{d} sb({d},{d}) {d}x{d} numbps {d}/{d} (zbp {d} expn {d}) passes {d} cblksty 0x{x} segs {d}: {d}/{d} coeffs differ, first [{d}] ours={d} oj={d}\n", .{
                        plan.tile, plan.component, plan.resolution, plan.band, plan.sb_x0, plan.sb_y0, plan.width(), plan.height(),
                        plan.numbps, rec.numbps, plan.zero_bitplanes, plan.qcd_expn, plan.total_passes, plan.cblksty, plan.segments.len, bad, rec.data.len, fb,
                        if (fb < cblk.coeffs.len) jp2z.internal.coeffToOpenJpegI32(cblk.coeffs[fb]) else 0, if (fb < rec.data.len) rec.data[fb] else 0,
                    });
                }
            }
            break;
        }
    }
    std.debug.print("t1-diff: oracle records {d}, jp2z plans {d}, matched {d}, mismatched {d}, numbps-diff {d}\n", .{ records.len, list.plans.len, matched, mismatched, numbps_diff });
    var r: usize = 0;
    while (r < 33) : (r += 1) {
        var b: usize = 0;
        while (b < 4) : (b += 1) {
            if (hist[r][b] > 0) std.debug.print("  r{d} b{d}: {d}/{d} cblks mismatched\n", .{ r, b, hist[r][b], total[r][b] });
        }
    }
}
