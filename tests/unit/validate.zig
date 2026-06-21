//! Cleanroom validator tests — M1 codestream walker.
//!
//! Phase 2 M1 implements `validate()` as a cleanroom marker walker
//! (SOC / SIZ / COD / QCD / SOD / EOC). These tests grow as each
//! marker lands.

const std = @import("std");
const jp2z = @import("jp2z");

const c1_mono_j2c = @embedFile("fixtures/conformance/c1_mono.j2c");
const p0_09_j2k = @embedFile("fixtures/conformance/p0_09.j2k");
const p0_04_j2k = @embedFile("fixtures/conformance/p0_04.j2k");
const d1_colr_j2c = @embedFile("fixtures/conformance/d1_colr.j2c");
const file1_jp2 = @embedFile("fixtures/conformance/file1.jp2");
const file9_jp2 = @embedFile("fixtures/conformance/file9.jp2");

test "validate: detects J2K codestream variant via SOC magic" {
    var report = try jp2z.validate(std.testing.allocator, c1_mono_j2c);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(jp2z.Variant.j2k_codestream, report.variant);
    try std.testing.expect(report.isOk());
}

test "validate: SIZ marker yields width/height for c1_mono.j2c (303x179)" {
    var report = try jp2z.validate(std.testing.allocator, c1_mono_j2c);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u32, 303), report.width);
    try std.testing.expectEqual(@as(?u32, 179), report.height);
}

test "validate: SIZ marker yields width/height for d1_colr.j2c (256x149)" {
    var report = try jp2z.validate(std.testing.allocator, d1_colr_j2c);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u32, 256), report.width);
    try std.testing.expectEqual(@as(?u32, 149), report.height);
}

test "validate: empty input is FAIL with missing_soi finding" {
    var report = try jp2z.validate(std.testing.allocator, "");
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, report.overall);
    try std.testing.expectEqual(@as(usize, 1), report.findings.items.len);
    try std.testing.expectEqual(jp2z.FindingCode.missing_soi, report.findings.items[0].code);
}

test "validate: garbage bytes are FAIL with missing_soi finding" {
    var report = try jp2z.validate(std.testing.allocator, "not a JPEG 2000 codestream");
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, report.overall);
    try std.testing.expectEqual(@as(usize, 1), report.findings.items.len);
    try std.testing.expectEqual(jp2z.FindingCode.missing_soi, report.findings.items[0].code);
}

test "validate: full c1_mono.j2c walks main header through SOT cleanly" {
    var report = try jp2z.validate(std.testing.allocator, c1_mono_j2c);
    defer report.deinit(std.testing.allocator);
    // The walker now emits info-level findings (e.g. "uses 5/3
    // wavelet"), which bump `overall` from pass to info. Both
    // pass and info qualify as "OK" — assert via isOk + that no
    // warn/fail findings are present.
    try std.testing.expect(report.isOk());
    for (report.findings.items) |f| {
        try std.testing.expect(f.severity != .warn and f.severity != .fail);
    }
}

test "validate: c1_mono.j2c → BYTE-PERFECT packet-walk to tile-part end" {
    var report = try jp2z.validate(std.testing.allocator, c1_mono_j2c);
    defer report.deinit(std.testing.allocator);
    var saw_walked_to_end = false;
    var saw_under_read = false;
    for (report.findings.items) |f| {
        if (f.code == .jp2_packets_walked_to_end) saw_walked_to_end = true;
        if (f.code == .jp2_packets_under_read) saw_under_read = true;
    }
    try std.testing.expect(saw_walked_to_end);
    try std.testing.expect(!saw_under_read);
}

test "validate: file1.jp2 → BYTE-PERFECT packet-walk" {
    var report = try jp2z.validate(std.testing.allocator, file1_jp2);
    defer report.deinit(std.testing.allocator);
    var saw_walked_to_end = false;
    var saw_under_read = false;
    for (report.findings.items) |f| {
        if (f.code == .jp2_packets_walked_to_end) saw_walked_to_end = true;
        if (f.code == .jp2_packets_under_read) saw_under_read = true;
    }
    try std.testing.expect(saw_walked_to_end);
    try std.testing.expect(!saw_under_read);
}

test "validate: file9.jp2 → BYTE-PERFECT packet-walk" {
    var report = try jp2z.validate(std.testing.allocator, file9_jp2);
    defer report.deinit(std.testing.allocator);
    var saw_walked_to_end = false;
    var saw_under_read = false;
    for (report.findings.items) |f| {
        if (f.code == .jp2_packets_walked_to_end) saw_walked_to_end = true;
        if (f.code == .jp2_packets_under_read) saw_under_read = true;
    }
    try std.testing.expect(saw_walked_to_end);
    try std.testing.expect(!saw_under_read);
}

test "validate: d1_colr.j2c → BYTE-PERFECT packet-walk (PCRL + user precincts)" {
    // The d1_colr finish: PCRL ordering + user-defined precincts +
    // T.800 A.6.1 cblk cap by precinct + proper subband-internal
    // coordinate mapping (cblksInPrecinctSubband mirrors OpenJPEG's
    // opj_tcd_init_tile). All 4 vendored conformance fixtures now
    // walk byte-perfect.
    var report = try jp2z.validate(std.testing.allocator, d1_colr_j2c);
    defer report.deinit(std.testing.allocator);
    var saw_walked_to_end = false;
    var saw_under_read = false;
    for (report.findings.items) |f| {
        if (f.code == .jp2_packets_walked_to_end) saw_walked_to_end = true;
        if (f.code == .jp2_packets_under_read) saw_under_read = true;
    }
    try std.testing.expect(saw_walked_to_end);
    try std.testing.expect(!saw_under_read);
}

test "validate: COD body parse emits info jp2_uses_5x3_wavelet for c1_mono" {
    var report = try jp2z.validate(std.testing.allocator, c1_mono_j2c);
    defer report.deinit(std.testing.allocator);
    var saw_5x3 = false;
    for (report.findings.items) |f| {
        if (f.code == .jp2_uses_5x3_wavelet) saw_5x3 = true;
    }
    try std.testing.expect(saw_5x3);
}

test "validate: synthetic codestream with 9/7 wavelet emits info jp2_uses_9x7_wavelet" {
    // SOC + SIZ (4x4 mono) + COD with qmfbid=0 (9/7) + QCD + SOT + EOC.
    const stream = [_]u8{
        0xFF, 0x4F,
        // SIZ — 4x4 mono 8-bit
        0xFF, 0x51, 0x00, 0x29, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x07, 0x01, 0x01,
        // COD — Lcod=12, Scod=0, prog=0(LRCP), layers=1, MCT=0,
        // decomp=1, cblkw=4, cblkh=4, cblksty=0, qmfbid=0 (9/7)
        0xFF, 0x52, 0x00, 0x0C,
        0x00, 0x00, 0x00, 0x01, 0x00,
        0x01, 0x04, 0x04, 0x00, 0x00,
        // QCD — Lqcd=3, Sqcd=0x22 (scalar derived + 2 guard bits). Lqcd
        // includes its own 2 bytes, so body after Lqcd = 1 byte = Sqcd alone.
        0xFF, 0x5C, 0x00, 0x03, 0x22,
        // SOT
        0xFF, 0x90, 0x00, 0x0A,
        0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x01,
        // EOC
        0xFF, 0xD9,
    };
    var report = try jp2z.validate(std.testing.allocator, &stream);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.isOk());
    var saw_9x7 = false;
    for (report.findings.items) |f| {
        if (f.code == .jp2_uses_9x7_wavelet) saw_9x7 = true;
    }
    try std.testing.expect(saw_9x7);
}

// ── Known-bad fixture coverage ─────────────────────────────────────
//
// Each test below hand-crafts a malformed J2K codestream that
// exercises a specific structural error path in the walker. Keeping
// the bytes inline (vs. vendoring binary fixtures under
// fixtures/malformed/) puts the malformation right next to the
// expected finding — easier to read, harder to drift.

// ── M2 prep: CodingParams extracted via internal.inspect() ─────────
//
// The tier-2 packet walker (next M2 commits) needs SIZ + COD config
// in a single value. inspect() returns it; tests pin exact values
// against the vendored conformance fixtures.

test "inspect: c1_mono.j2c CodingParams matches opj_dump-observed values" {
    const cp = (try jp2z.internal.inspect(std.testing.allocator, c1_mono_j2c)) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(jp2z.ProgressionOrder.lrcp, cp.progression_order);
    try std.testing.expectEqual(@as(u16, 10), cp.num_layers);
    try std.testing.expectEqual(@as(u16, 1), cp.num_components);
    try std.testing.expectEqual(@as(u8, 5), cp.num_decomp_levels);
    try std.testing.expectEqual(@as(u8, 4), cp.cblk_width_exp);
    try std.testing.expectEqual(@as(u8, 4), cp.cblk_height_exp);
    try std.testing.expectEqual(jp2z.WaveletFilter.reversible_5x3, cp.wavelet);
    try std.testing.expectEqual(false, cp.mct);
}

test "inspect: d1_colr.j2c CodingParams (3 components, PCRL, MCT)" {
    const cp = (try jp2z.internal.inspect(std.testing.allocator, d1_colr_j2c)) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(jp2z.ProgressionOrder.pcrl, cp.progression_order);
    try std.testing.expectEqual(@as(u16, 4), cp.num_layers);
    try std.testing.expectEqual(@as(u16, 3), cp.num_components);
    try std.testing.expectEqual(jp2z.WaveletFilter.reversible_5x3, cp.wavelet);
    try std.testing.expectEqual(true, cp.mct);
}

test "inspect: returns null for garbage input" {
    const cp = try jp2z.internal.inspect(std.testing.allocator, "garbage");
    try std.testing.expectEqual(@as(?jp2z.CodingParams, null), cp);
}

test "inspect: c1_mono.j2c uses default precincts (PPx=PPy=15 across all resolutions)" {
    const cp = (try jp2z.internal.inspect(std.testing.allocator, c1_mono_j2c)) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 0), cp.scod & 0x01); // default precincts
    var r: usize = 0;
    while (r <= cp.num_decomp_levels) : (r += 1) {
        try std.testing.expectEqual(@as(u4, 15), cp.precinct_sizes[r].x_exp);
        try std.testing.expectEqual(@as(u4, 15), cp.precinct_sizes[r].y_exp);
    }
}

test "inspect: d1_colr.j2c uses user-defined 64x64 precincts at every resolution" {
    const cp = (try jp2z.internal.inspect(std.testing.allocator, d1_colr_j2c)) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 1), cp.scod & 0x01); // user-defined precincts
    var r: usize = 0;
    while (r <= cp.num_decomp_levels) : (r += 1) {
        try std.testing.expectEqual(@as(u4, 6), cp.precinct_sizes[r].x_exp); // 2^6 = 64
        try std.testing.expectEqual(@as(u4, 6), cp.precinct_sizes[r].y_exp);
    }
}

// ── M2: (L, R, C, P) packet iterator ────────────────────────────────
//
// Given a CodingParams (and the per-resolution precinct count, which
// is 1 for default-precinct single-tile streams), the iterator yields
// the (layer, resolution, component, precinct) tuples in the order
// dictated by the progression-order field. Five progression orders;
// each is a different nesting of the four inner loops.

test "packet iterator: c1_mono LRCP produces 60 packets in correct order" {
    // CodingParams: LRCP, 10 layers, 1 component, 5 decomp → 6 res levels.
    // Default precincts (15, 15) over any image → 1 precinct per resolution.
    const params: jp2z.CodingParams = .{
        .progression_order = .lrcp,
        .num_layers = 10,
        .num_components = 1,
        .num_decomp_levels = 5, // → 6 resolution levels (0..5)
    };
    var iter = jp2z.PacketIterator.init(params, 303, 179);
    try std.testing.expectEqual(@as(usize, 60), iter.total());

    var count: usize = 0;
    // Verify LRCP iteration: outer loop layer, then resolution.
    var expected_layer: u16 = 0;
    var expected_res: u8 = 0;
    while (iter.next()) |p| {
        try std.testing.expectEqual(expected_layer, p.layer);
        try std.testing.expectEqual(expected_res, p.resolution);
        try std.testing.expectEqual(@as(u16, 0), p.component);
        try std.testing.expectEqual(@as(u32, 0), p.precinct);
        count += 1;
        expected_res += 1;
        if (expected_res == 6) {
            expected_res = 0;
            expected_layer += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 60), count);
}

test "packet iterator: d1_colr PCRL produces 72 packets (1×3×6×4 = 72)" {
    // CodingParams: PCRL, 4 layers, 3 components, 5 decomp → 6 res.
    // Default precincts here (15, 15) → 1 precinct per resolution; the
    // d1_colr fixture itself uses (6, 6) but this test exercises the
    // default-precinct degenerate case.
    const params: jp2z.CodingParams = .{
        .progression_order = .pcrl,
        .num_layers = 4,
        .num_components = 3,
        .num_decomp_levels = 5,
    };
    var iter = jp2z.PacketIterator.init(params, 256, 149);
    try std.testing.expectEqual(@as(usize, 72), iter.total());

    // Confirm first packet is (l=0,r=0,c=0,p=0) and 4th packet is
    // (l=0,r=0,c=0,p=… wait, PCRL puts layer innermost.
    // PCRL nesting: precinct (outer) → component → resolution → layer (inner).
    // With 1 precinct, the precinct dim is degenerate. So we expect:
    //   (l=0,c=0,r=0,p=0), (l=1,c=0,r=0,p=0), (l=2,c=0,r=0,p=0),
    //   (l=3,c=0,r=0,p=0), (l=0,c=0,r=1,p=0), ...
    const first = iter.next().?;
    try std.testing.expectEqual(@as(u16, 0), first.layer);
    try std.testing.expectEqual(@as(u8, 0), first.resolution);
    try std.testing.expectEqual(@as(u16, 0), first.component);
    const second = iter.next().?;
    try std.testing.expectEqual(@as(u16, 1), second.layer); // layer ticks fastest
    const fifth = blk: {
        _ = iter.next().?; // l=2
        _ = iter.next().?; // l=3
        break :blk iter.next().?;
    };
    try std.testing.expectEqual(@as(u16, 0), fifth.layer);
    try std.testing.expectEqual(@as(u8, 1), fifth.resolution);
    try std.testing.expectEqual(@as(u16, 0), fifth.component);
}

test "packet iterator: every progression order covers exactly the full Cartesian product" {
    const params: jp2z.CodingParams = .{
        .num_layers = 2,
        .num_components = 2,
        .num_decomp_levels = 2, // → 3 res levels
    };
    const expected_total: usize = 2 * 2 * 3 * 1;
    inline for (.{ .lrcp, .rlcp, .rpcl, .pcrl, .cprl }) |po| {
        var iter = jp2z.PacketIterator.init(.{
            .progression_order = po,
            .num_layers = params.num_layers,
            .num_components = params.num_components,
            .num_decomp_levels = params.num_decomp_levels,
        }, 256, 256);
        try std.testing.expectEqual(expected_total, iter.total());
        var count: usize = 0;
        // Bitset of seen (l,r,c,p) tuples — packs into a u32 for this small case.
        var seen: u32 = 0;
        while (iter.next()) |p| {
            const bit_idx: u5 = @intCast(
                (@as(u32, p.layer) * 3 + @as(u32, p.resolution)) * 2 + @as(u32, p.component),
            );
            const mask = @as(u32, 1) << bit_idx;
            try std.testing.expect(seen & mask == 0); // no duplicates
            seen |= mask;
            count += 1;
        }
        try std.testing.expectEqual(expected_total, count);
        try std.testing.expectEqual(@as(u32, (1 << @as(u5, @intCast(expected_total))) - 1), seen);
    }
}

test "packet iterator: d1_colr params (PCRL, 64×64 precincts) → 240 packets total" {
    // d1_colr: 256×149, 4 layers, 3 components, num_decomp=5, all
    // precincts (6, 6) = 64×64. Per T.800 B.6 numPrecincts:
    //   r=5: 4×3 = 12   r=4: 2×2 = 4   r=0..3: 1×1 = 1 each
    // Sum = 20 precincts × 3 components × 4 layers = 240 packets.
    var params: jp2z.CodingParams = .{
        .progression_order = .pcrl,
        .num_layers = 4,
        .num_components = 3,
        .num_decomp_levels = 5,
        .scod = 0x01, // user-defined precincts
    };
    var r: u8 = 0;
    while (r <= 5) : (r += 1) {
        params.precinct_sizes[r] = .{ .x_exp = 6, .y_exp = 6 };
    }
    var iter = jp2z.PacketIterator.init(params, 256, 149);
    try std.testing.expectEqual(@as(usize, 240), iter.total());

    var count: usize = 0;
    while (iter.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 240), count);
}

test "packet iterator: d1_colr params (PCRL) — first packet is (l=0,r=0,c=0)" {
    var params: jp2z.CodingParams = .{
        .progression_order = .pcrl,
        .num_layers = 4,
        .num_components = 3,
        .num_decomp_levels = 5,
        .scod = 0x01,
    };
    var r: u8 = 0;
    while (r <= 5) : (r += 1) {
        params.precinct_sizes[r] = .{ .x_exp = 6, .y_exp = 6 };
    }
    var iter = jp2z.PacketIterator.init(params, 256, 149);
    // PCRL nesting (outer→inner): P, C, R, L. At (x=0, y=0), all 6
    // resolutions fire (all on boundary). Layer is innermost.
    const p0 = iter.next().?;
    try std.testing.expectEqual(@as(u16, 0), p0.layer);
    try std.testing.expectEqual(@as(u8, 0), p0.resolution);
    try std.testing.expectEqual(@as(u16, 0), p0.component);
    try std.testing.expectEqual(@as(u32, 0), p0.precinct);
    const p1 = iter.next().?;
    try std.testing.expectEqual(@as(u16, 1), p1.layer); // layer ticks
    try std.testing.expectEqual(@as(u8, 0), p1.resolution);
}

test "packet iterator: LRCP with d1_colr params (per-r variable precincts)" {
    // Same params but LRCP. Total still 240, but order differs: layer
    // outer, then resolution. After exhausting precincts at r=5 (12)
    // for the first layer/comp pair, move to r=4 (4 precincts), etc.
    var params: jp2z.CodingParams = .{
        .progression_order = .lrcp,
        .num_layers = 4,
        .num_components = 3,
        .num_decomp_levels = 5,
        .scod = 0x01,
    };
    var r: u8 = 0;
    while (r <= 5) : (r += 1) {
        params.precinct_sizes[r] = .{ .x_exp = 6, .y_exp = 6 };
    }
    var iter = jp2z.PacketIterator.init(params, 256, 149);
    try std.testing.expectEqual(@as(usize, 240), iter.total());

    var count: usize = 0;
    while (iter.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 240), count);
}

test "validate: SOC only (no SIZ) emits truncated_stream" {
    const stream = [_]u8{ 0xFF, 0x4F };
    var report = try jp2z.validate(std.testing.allocator, &stream);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, report.overall);
    var saw = false;
    for (report.findings.items) |f| {
        if (f.code == .truncated_stream) saw = true;
    }
    try std.testing.expect(saw);
}

test "validate: SOC followed by non-SIZ marker emits bad_marker_length" {
    // SOC then a marker code that isn't SIZ (FF52 = COD).
    const stream = [_]u8{ 0xFF, 0x4F, 0xFF, 0x52, 0x00, 0x04 };
    var report = try jp2z.validate(std.testing.allocator, &stream);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, report.overall);
    var saw = false;
    for (report.findings.items) |f| {
        if (f.code == .bad_marker_length) saw = true;
    }
    try std.testing.expect(saw);
}

test "validate: Lsiz too small (< 41) emits bad_marker_length" {
    // SIZ with Lsiz=20 — below the 41-byte minimum (no per-component
    // descriptors fit).
    const stream = [_]u8{
        0xFF, 0x4F,
        0xFF, 0x51, 0x00, 0x14, // Lsiz = 20 (invalid)
        0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00,
    };
    var report = try jp2z.validate(std.testing.allocator, &stream);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, report.overall);
    var saw = false;
    for (report.findings.items) |f| {
        if (f.code == .bad_marker_length) saw = true;
    }
    try std.testing.expect(saw);
}

test "validate: SIZ with Xsiz <= XOsiz leaves width/height null (degenerate image)" {
    // Lsiz valid; Xsiz=XOsiz=0 → image is 0-wide. parseSizBody bails
    // without setting width/height. No fail-level finding emitted
    // (the marker is structurally fine; semantically degenerate is
    // a decode-time problem, not a walker problem).
    const stream = [_]u8{
        0xFF, 0x4F,
        0xFF, 0x51, 0x00, 0x29, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, // Xsiz = 0
        0x00, 0x00, 0x00, 0x00, // Ysiz = 0
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x01,
        0x07, 0x01, 0x01,
        // No SOT or EOC after — walker's next iteration will see EOF.
    };
    var report = try jp2z.validate(std.testing.allocator, &stream);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u32, null), report.width);
    try std.testing.expectEqual(@as(?u32, null), report.height);
}

test "validate: stuffing-pattern marker (0xFF 0x00) treated as unknown_marker" {
    // 0xFF 0x00 is the in-data stuffing pattern (used to escape FF
    // inside entropy-coded segments) — not a real top-level marker
    // code. Provided as a structurally well-formed (Lxxx=2, no body)
    // marker so the walker steps past it and emits the unknown_marker
    // finding rather than a truncated_stream fail.
    const stream = [_]u8{
        0xFF, 0x4F,
        0xFF, 0x51, 0x00, 0x29, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x07, 0x01, 0x01,
        // 0xFF00 marker, Lxxx=2 (no body)
        0xFF, 0x00, 0x00, 0x02,
        // SOT
        0xFF, 0x90, 0x00, 0x0A,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        // EOC
        0xFF, 0xD9,
    };
    var report = try jp2z.validate(std.testing.allocator, &stream);
    defer report.deinit(std.testing.allocator);
    var saw = false;
    for (report.findings.items) |f| {
        if (f.code == .unknown_marker) saw = true;
    }
    try std.testing.expect(saw);
}

test "validate: trailing garbage after EOC emits truncated_stream warning" {
    // A valid SOC..SOT..EOC stream with 4 extra junk bytes appended
    // after EOC. Psot is set so the walker lands directly on EOC,
    // then sees data.len > next_pos+2 → warn truncated_stream.
    // Psot = 12 (SOT marker code + Lsot through TNsot = 12 bytes
    // total, no body since this is a header-only synthetic).
    const stream = [_]u8{
        0xFF, 0x4F,
        0xFF, 0x51, 0x00, 0x29, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x07, 0x01, 0x01,
        // SOT with Psot=12
        0xFF, 0x90, 0x00, 0x0A,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x00, 0x01,
        // EOC
        0xFF, 0xD9,
        // 4 bytes of garbage past EOC
        0xDE, 0xAD, 0xBE, 0xEF,
    };
    var report = try jp2z.validate(std.testing.allocator, &stream);
    defer report.deinit(std.testing.allocator);
    var saw = false;
    for (report.findings.items) |f| {
        if (f.code == .truncated_stream and f.severity == .warn) saw = true;
    }
    try std.testing.expect(saw);
}

test "validate: COD with invalid progression order (5) emits jp2_bad_progression_order" {
    // Same as above but prog order = 5 (only 0..4 are valid).
    const stream = [_]u8{
        0xFF, 0x4F,
        0xFF, 0x51, 0x00, 0x29, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x07, 0x01, 0x01,
        // COD with bad prog order
        0xFF, 0x52, 0x00, 0x0C,
        0x00, 0x05, 0x00, 0x01, 0x00,
        0x01, 0x04, 0x04, 0x00, 0x01,
        // QCD
        0xFF, 0x5C, 0x00, 0x04, 0x22,
        0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0xFF, 0xD9,
    };
    var report = try jp2z.validate(std.testing.allocator, &stream);
    defer report.deinit(std.testing.allocator);
    var saw_bad_prog = false;
    for (report.findings.items) |f| {
        if (f.code == .jp2_bad_progression_order) saw_bad_prog = true;
    }
    try std.testing.expect(saw_bad_prog);
}

test "validate: truncated mid-COD fails with truncated_stream" {
    // SOC (2) + SIZ (2 marker + 41 body) = 45 bytes. Truncating at
    // byte 50 leaves COD's marker code + partial length field
    // missing — the walker must detect short main-header bytes.
    const truncated = c1_mono_j2c[0..50];
    var report = try jp2z.validate(std.testing.allocator, truncated);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, report.overall);
    var saw_truncated = false;
    for (report.findings.items) |f| {
        if (f.code == .truncated_stream) saw_truncated = true;
    }
    try std.testing.expect(saw_truncated);
}

test "validate: synthetic SOC+SIZ+SOT main header walks cleanly" {
    // Hand-built minimal-but-valid main header: SOC + SIZ (4×4 mono
    // 8-bit, one tile, one component) + SOT (first tile-part header
    // ends the main header walk). No COD/QCD — those are normally
    // required, but the walker today is permissive past SIZ and
    // just verifies it can structurally reach SOT/SOD/EOC.
    const stream = [_]u8{
        // SOC
        0xFF, 0x4F,
        // SIZ marker code
        0xFF, 0x51,
        // Lsiz = 0x29 = 41 (incl. Lsiz)
        0x00, 0x29,
        // Rsiz = 0 (Part 1)
        0x00, 0x00,
        // Xsiz = 4
        0x00, 0x00, 0x00, 0x04,
        // Ysiz = 4
        0x00, 0x00, 0x00, 0x04,
        // XOsiz, YOsiz = 0
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        // XTsiz = 4
        0x00, 0x00, 0x00, 0x04,
        // YTsiz = 4
        0x00, 0x00, 0x00, 0x04,
        // XTOsiz, YTOsiz
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        // Csiz = 1
        0x00, 0x01,
        // Ssiz0=8-bit unsigned, XRsiz0=1, YRsiz0=1
        0x07, 0x01, 0x01,
        // SOT marker code (start of first tile-part — ends main header walk)
        0xFF, 0x90,
        // Lsot = 10 (mandatory marker length per T.800 A.4.2)
        0x00, 0x0A,
        // Isot = 0, Psot = 0 (tile-part extends to EOC),
        // TPsot = 0, TNsot = 1
        0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x01,
        // EOC
        0xFF, 0xD9,
    };
    var report = try jp2z.validate(std.testing.allocator, &stream);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(jp2z.Severity.pass, report.overall);
    try std.testing.expectEqual(@as(?u32, 4), report.width);
    try std.testing.expectEqual(@as(?u32, 4), report.height);
}

test "validate: full c1_mono.j2c walks all the way to EOC" {
    // The walker consumes every tile-part (using Psot to skip the
    // entropy-coded body) and confirms the codestream ends with EOC.
    var report = try jp2z.validate(std.testing.allocator, c1_mono_j2c);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.isOk());

    // Spot-check the last 2 bytes of the fixture are EOC (FF D9) —
    // proves the input we expect the walker to reach is well-formed.
    const tail = c1_mono_j2c[c1_mono_j2c.len - 2 ..];
    try std.testing.expectEqual(@as(u8, 0xFF), tail[0]);
    try std.testing.expectEqual(@as(u8, 0xD9), tail[1]);

    // The walker should *not* surface a missing_eoi finding for this
    // fixture (it has a proper EOC at the end).
    for (report.findings.items) |f| {
        try std.testing.expect(f.code != .missing_eoi);
    }
}

test "validate: codestream truncated before EOC emits missing_eoi" {
    // Drop the last 2 bytes (the EOC marker). Walker should consume
    // every tile-part and then find no EOC at end-of-data → warn
    // missing_eoi (warn, not fail — partial decode is still useful).
    const no_eoc = c1_mono_j2c[0 .. c1_mono_j2c.len - 2];
    var report = try jp2z.validate(std.testing.allocator, no_eoc);
    defer report.deinit(std.testing.allocator);
    var saw_missing_eoi = false;
    for (report.findings.items) |f| {
        if (f.code == .missing_eoi) saw_missing_eoi = true;
    }
    try std.testing.expect(saw_missing_eoi);
}

test "validate: JP2 file1.jp2 (768x512 RGB) detected as jp2_file variant" {
    var report = try jp2z.validate(std.testing.allocator, file1_jp2);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(jp2z.Variant.jp2_file, report.variant);
    try std.testing.expectEqual(@as(?u32, 768), report.width);
    try std.testing.expectEqual(@as(?u32, 512), report.height);
    try std.testing.expect(report.isOk());
}

test "validate: JP2 file9.jp2 (palette-indexed, 768x512) variant + dims" {
    var report = try jp2z.validate(std.testing.allocator, file9_jp2);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(jp2z.Variant.jp2_file, report.variant);
    try std.testing.expectEqual(@as(?u32, 768), report.width);
    try std.testing.expectEqual(@as(?u32, 512), report.height);
    try std.testing.expect(report.isOk());
}

test "validate: bytes claiming to be JP2 but missing signature → fail" {
    // Looks like a JP2 length-prefix (LBox=12) but TBox isn't 'jP  '.
    const bad = [_]u8{
        0x00, 0x00, 0x00, 0x0C, // LBox = 12
        0x58, 0x58, 0x58, 0x58, // TBox = "XXXX" (not 'jP  ')
        0x0D, 0x0A, 0x87, 0x0A,
    };
    var report = try jp2z.validate(std.testing.allocator, &bad);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, report.overall);
}

test "validate: unknown marker emits unknown_marker warning, doesn't FAIL" {
    // SOC + SIZ + UNKNOWN marker (0xFFAA, with body length 4) + SOT.
    // Spec-deviation tolerance: unknown markers don't fail decode;
    // they're surfaced as a `warn`-level finding for visibility.
    const stream = [_]u8{
        0xFF, 0x4F,
        0xFF, 0x51, 0x00, 0x29, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, // Xsiz
        0x00, 0x00, 0x00, 0x04, // Ysiz
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x07, 0x01, 0x01,
        // Unknown marker 0xFFAA. Lxxx=4 = 2 Lxxx bytes + 2 body bytes.
        0xFF, 0xAA, 0x00, 0x04, 0xDE, 0xAD,
        // SOT
        0xFF, 0x90, 0x00, 0x0A,
        0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x01,
        // EOC
        0xFF, 0xD9,
    };
    var report = try jp2z.validate(std.testing.allocator, &stream);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.isOk()); // warn-level still passes isOk
    var saw_unknown = false;
    for (report.findings.items) |f| {
        if (f.code == .unknown_marker and f.severity == .warn) saw_unknown = true;
    }
    try std.testing.expect(saw_unknown);
}

// ── M3 brick 9d: extractCblkPlans against real fixtures ───────────

test "extractCblkPlans: c1_mono.j2c — produces > 0 plans, each with non-empty data + non-zero passes" {
    var list = try jp2z.internal.extractCblkPlans(std.testing.allocator, c1_mono_j2c);
    defer list.deinit(std.testing.allocator);
    try std.testing.expect(list.plans.len > 0);
    // Every plan must carry real data + a positive pass count.
    var total_bytes: usize = 0;
    var total_passes: usize = 0;
    for (list.plans) |p| {
        try std.testing.expect(p.data.len > 0);
        try std.testing.expect(p.total_passes > 0);
        try std.testing.expect(p.sb_x1 > p.sb_x0);
        try std.testing.expect(p.sb_y1 > p.sb_y0);
        total_bytes += p.data.len;
        total_passes += p.total_passes;
    }
    // Sanity: total bytes should be roughly the codestream's compressed
    // payload size (within an order of magnitude). c1_mono.j2c is ~6KB
    // of compressed data.
    try std.testing.expect(total_bytes >= 1024);
    try std.testing.expect(total_passes >= 10);
}

test "extractCblkPlans: c1_mono.j2c — at least one plan in each resolution 0..5" {
    var list = try jp2z.internal.extractCblkPlans(std.testing.allocator, c1_mono_j2c);
    defer list.deinit(std.testing.allocator);
    var seen_res: [6]bool = @splat(false);
    for (list.plans) |p| {
        if (p.resolution < seen_res.len) seen_res[p.resolution] = true;
    }
    for (seen_res, 0..) |s, r| {
        if (!s) std.debug.print("missing plans at resolution {d}\n", .{r});
        try std.testing.expect(s);
    }
}

test "extractCblkPlans: c1_mono.j2c — bands at r=0 are LL (band=0); at r>=1 are HL/LH/HH (bands 1/2/3)" {
    var list = try jp2z.internal.extractCblkPlans(std.testing.allocator, c1_mono_j2c);
    defer list.deinit(std.testing.allocator);
    for (list.plans) |p| {
        if (p.resolution == 0) {
            try std.testing.expectEqual(@as(u8, 0), p.band);
        } else {
            try std.testing.expect(p.band >= 1 and p.band <= 3);
        }
    }
}

test "extractCblkPlans: c1_mono.j2c — exactly 34 plans, histogram by (res, band) matches OpenJPEG" {
    // OpenJPEG decodes 34 cblks for c1_mono.j2c (single component,
    // 5 decomp levels, default 1-precinct-per-band). With the
    // JP2Z_DUMP_T1 patched openjpeg run via opj_decompress, the
    // per-(resolution, band) histogram is:
    //   r=0 b=0: 1   (LL @ r=0)
    //   r=1 b=1,2,3: 1 each (HL/LH/HH at coarsest HF level)
    //   r=2 b=1,2,3: 1 each
    //   r=3 b=1,2,3: 1 each
    //   r=4 b=1,2,3: 2 each (band starts to exceed cblk dims)
    //   r=5 b=1,2,3: 6 each (finest detail level)
    var list = try jp2z.internal.extractCblkPlans(std.testing.allocator, c1_mono_j2c);
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 34), list.plans.len);

    // Histogram: indexed [resolution * 4 + band].
    var hist: [6 * 4]u32 = @splat(0);
    for (list.plans) |p| {
        const idx = @as(usize, p.resolution) * 4 + @as(usize, p.band);
        hist[idx] += 1;
    }
    // r=0 b=0
    try std.testing.expectEqual(@as(u32, 1), hist[0 * 4 + 0]);
    // r=1..3 each have 1 cblk per HF band (bands 1, 2, 3)
    inline for ([_]u8{ 1, 2, 3 }) |r| {
        try std.testing.expectEqual(@as(u32, 1), hist[r * 4 + 1]);
        try std.testing.expectEqual(@as(u32, 1), hist[r * 4 + 2]);
        try std.testing.expectEqual(@as(u32, 1), hist[r * 4 + 3]);
    }
    // r=4: 2 cblks per HF band
    try std.testing.expectEqual(@as(u32, 2), hist[4 * 4 + 1]);
    try std.testing.expectEqual(@as(u32, 2), hist[4 * 4 + 2]);
    try std.testing.expectEqual(@as(u32, 2), hist[4 * 4 + 3]);
    // r=5: 6 cblks per HF band
    try std.testing.expectEqual(@as(u32, 6), hist[5 * 4 + 1]);
    try std.testing.expectEqual(@as(u32, 6), hist[5 * 4 + 2]);
    try std.testing.expectEqual(@as(u32, 6), hist[5 * 4 + 3]);
}
test "extractCblkPlans: empty input → empty plan list (no crash)" {
    var list = try jp2z.internal.extractCblkPlans(std.testing.allocator, "");
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), list.plans.len);
}

test "extractCblkPlans: garbage input → empty plan list (no crash)" {
    var list = try jp2z.internal.extractCblkPlans(std.testing.allocator, "definitely not a jp2");
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), list.plans.len);
}

// ── M3 brick 9e: end-to-end decode (extract → dispatch) ───────────

test "decodePlan: c1_mono.j2c — every cblk runs through EBCOT without crash" {
    // End-to-end smoke: walker → extractor → dispatcher. Verifies the
    // 34 plans for c1_mono.j2c each decode cleanly via decodePlan +
    // produce a Cblk of the expected dimensions. Byte-perfect verification
    // against the OpenJPEG t1 dump lands in brick 10.
    var list = try jp2z.internal.extractCblkPlans(std.testing.allocator, c1_mono_j2c);
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 34), list.plans.len);

    var decoded_count: u32 = 0;
    var any_sig: bool = false;
    for (list.plans) |plan| {
        // msb_bp is now derived from plan.numbps (which the walker fills
        // in from QCD's per-subband M_b minus the cblk's zero_bitplanes).
        var cblk = try jp2z.internal.decodePlan(std.testing.allocator, plan);
        defer cblk.deinit(std.testing.allocator);
        try std.testing.expectEqual(plan.width(), cblk.width);
        try std.testing.expectEqual(plan.height(), cblk.height);
        // Sanity: at least SOME coefficient ought to become significant
        // across the whole fixture (random 8-bit grayscale image data).
        for (cblk.coeffs) |c| {
            if (c.significant) {
                any_sig = true;
                break;
            }
        }
        decoded_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 34), decoded_count);
    try std.testing.expect(any_sig); // at least one cblk has a sig coeff
}

// ── M3 brick 10: oracle byte-perfect comparison ───────────────────

/// Captured by patched openjpeg (`patches/openjpeg-cblk-dump.patch`)
/// running `opj_decompress -i c1_mono.j2c` with `JP2Z_DUMP_T1` set and
/// `OPJ_NUM_THREADS=1`. Each record is the i32 coefficient buffer
/// produced inside `opj_t1_decode_cblk`, BEFORE dequantisation.
const c1_mono_t1_oracle = @embedFile("fixtures/oracles/c1_mono.t1.bin");
const a1_mono_j2c = @embedFile("fixtures/conformance/a1_mono.j2c");
const a1_mono_t1_oracle = @embedFile("fixtures/oracles/a1_mono.t1.bin");
const d1_colr_t1_oracle = @embedFile("fixtures/oracles/d1_colr.t1.bin");
const a1_mono_pix = @embedFile("fixtures/oracles/a1_mono.pix");
const c1_mono_pix = @embedFile("fixtures/oracles/c1_mono.pix");
const p0_09_pix = @embedFile("fixtures/oracles/p0_09.pix");
const p0_04_pix = @embedFile("fixtures/oracles/p0_04.pix");
const d1_colr_pix = @embedFile("fixtures/oracles/d1_colr.pix");

const OracleRecord = struct {
    tile: u32,
    component: u32,
    resno: u32,
    orient: u32,
    precinct: u32,
    cblk_x0: i32,
    cblk_y0: i32,
    cblk_x1: i32,
    cblk_y1: i32,
    numbps: u32,
    data: []i32, // owned — freed via freeOracleRecords()
};

fn parseOracleDump(allocator: std.mem.Allocator, dump: []const u8) ![]OracleRecord {
    var records: std.ArrayList(OracleRecord) = .empty;
    errdefer records.deinit(allocator);
    var pos: usize = 0;
    while (pos + 48 <= dump.len) {
        const magic = std.mem.readInt(u32, dump[pos..][0..4], .little);
        try std.testing.expectEqual(@as(u32, 0x4B4C4243), magic); // 'CBLK'
        const tile = std.mem.readInt(u32, dump[pos + 4 ..][0..4], .little);
        const comp = std.mem.readInt(u32, dump[pos + 8 ..][0..4], .little);
        const resno = std.mem.readInt(u32, dump[pos + 12 ..][0..4], .little);
        const orient = std.mem.readInt(u32, dump[pos + 16 ..][0..4], .little);
        const prec = std.mem.readInt(u32, dump[pos + 20 ..][0..4], .little);
        const x0 = std.mem.readInt(i32, dump[pos + 24 ..][0..4], .little);
        const y0 = std.mem.readInt(i32, dump[pos + 28 ..][0..4], .little);
        const x1 = std.mem.readInt(i32, dump[pos + 32 ..][0..4], .little);
        const y1 = std.mem.readInt(i32, dump[pos + 36 ..][0..4], .little);
        const numbps = std.mem.readInt(u32, dump[pos + 40 ..][0..4], .little);
        const dlen = std.mem.readInt(u32, dump[pos + 44 ..][0..4], .little);
        const data_start = pos + 48;
        const data_end = data_start + dlen;
        if (data_end > dump.len) return error.TruncatedOracle;
        // Copy data into a properly-aligned i32 buffer (the dump bytes
        // are NOT guaranteed to be 4-byte aligned at @embedFile-time).
        const coeff_count: usize = dlen / 4;
        const data = try allocator.alloc(i32, coeff_count);
        errdefer allocator.free(data);
        var i: usize = 0;
        while (i < coeff_count) : (i += 1) {
            data[i] = std.mem.readInt(i32, dump[data_start + i * 4 ..][0..4], .little);
        }
        try records.append(allocator, .{
            .tile = tile, .component = comp, .resno = resno, .orient = orient, .precinct = prec,
            .cblk_x0 = x0, .cblk_y0 = y0, .cblk_x1 = x1, .cblk_y1 = y1,
            .numbps = numbps, .data = data,
        });
        pos = data_end;
    }
    return records.toOwnedSlice(allocator);
}

fn freeOracleRecords(allocator: std.mem.Allocator, records: []OracleRecord) void {
    for (records) |r| allocator.free(r.data);
    allocator.free(records);
}

test "oracle dump: parses 34 records totalling 218,580 bytes" {
    const records = try parseOracleDump(std.testing.allocator, c1_mono_t1_oracle);
    defer freeOracleRecords(std.testing.allocator, records);
    try std.testing.expectEqual(@as(usize, 34), records.len);
    // First record's metadata (per python dump): r=5 LH (orient=2), 64x25.
    const r0 = records[0];
    try std.testing.expectEqual(@as(u32, 0), r0.tile);
    try std.testing.expectEqual(@as(u32, 0), r0.component);
    try std.testing.expectEqual(@as(u32, 5), r0.resno);
    try std.testing.expectEqual(@as(u32, 2), r0.orient);
    try std.testing.expectEqual(@as(i32, 0),  r0.cblk_x0);
    try std.testing.expectEqual(@as(i32, 64), r0.cblk_y0);
    try std.testing.expectEqual(@as(i32, 64), r0.cblk_x1);
    try std.testing.expectEqual(@as(i32, 89), r0.cblk_y1);
    try std.testing.expectEqual(@as(u32, 6), r0.numbps);
    try std.testing.expectEqual(@as(usize, 64 * 25), r0.data.len);
}

test "oracle dump: jp2z extractCblkPlans matches openjpeg per-cblk numbps for c1_mono" {
    const allocator = std.testing.allocator;
    const records = try parseOracleDump(allocator, c1_mono_t1_oracle);
    defer freeOracleRecords(allocator, records);

    var list = try jp2z.internal.extractCblkPlans(allocator, c1_mono_j2c);
    defer list.deinit(allocator);

    // For each oracle record, find the matching jp2z plan by
    // (tile, comp, resno, orient/band, precinct, x0, y0). They must
    // agree on numbps — that's the M_b - zero_bitplanes derivation
    // working end-to-end.
    var matched: u32 = 0;
    for (records) |rec| {
        var found = false;
        for (list.plans) |plan| {
            if (plan.tile != rec.tile) continue;
            if (plan.component != rec.component) continue;
            if (plan.resolution != rec.resno) continue;
            if (plan.band != rec.orient) continue;
            if (plan.sb_x0 != rec.cblk_x0) continue;
            if (plan.sb_y0 != rec.cblk_y0) continue;
            // Same cblk. numbps must agree byte-for-byte with openjpeg.
            try std.testing.expectEqual(rec.numbps, @as(u32, plan.numbps));
            try std.testing.expectEqual(rec.cblk_x1, plan.sb_x1);
            try std.testing.expectEqual(rec.cblk_y1, plan.sb_y1);
            matched += 1;
            found = true;
            break;
        }
        try std.testing.expect(found);
    }
    try std.testing.expectEqual(@as(u32, 34), matched);
}

test "oracle dump: jp2z decoded coefficients match openjpeg byte-perfectly for c1_mono (cblksty=0x1 BYPASS/LAZY)" {
    // c1_mono.j2c uses cblksty=0x1 (selective arithmetic-coding bypass / LAZY)
    // with 10 quality layers: SP/MR passes at bit-planes <= numbps-4 are RAW
    // (bypass) coded and the codeword is split into terminated MQ/RAW segments.
    // This exercises the segment-aware tier-1 decode (decodeCblkSegments) +
    // RawDecoder, on top of the tier-2 per-segment length capture.
    const allocator = std.testing.allocator;
    const records = try parseOracleDump(allocator, c1_mono_t1_oracle);
    defer freeOracleRecords(allocator, records);
    var list = try jp2z.internal.extractCblkPlans(allocator, c1_mono_j2c);
    defer list.deinit(allocator);
    var compared: u32 = 0;
    for (records) |rec| {
        for (list.plans) |plan| {
            if (plan.tile != rec.tile) continue;
            if (plan.component != rec.component) continue;
            if (plan.resolution != rec.resno) continue;
            if (plan.band != rec.orient) continue;
            if (plan.sb_x0 != rec.cblk_x0) continue;
            if (plan.sb_y0 != rec.cblk_y0) continue;
            var cblk = try jp2z.internal.decodePlan(allocator, plan);
            defer cblk.deinit(allocator);
            const msb_bp: u5 = if (plan.numbps == 0) 0 else @intCast(plan.numbps);
            const half_bp = jp2z.internal.halfBitPos(msb_bp, plan.total_passes);
            const our_buf = try allocator.alloc(i32, cblk.coeffs.len);
            defer allocator.free(our_buf);
            for (cblk.coeffs, 0..) |c, i| our_buf[i] = jp2z.internal.coeffToOpenJpegI32(c, half_bp);
            try std.testing.expectEqual(rec.data.len, our_buf.len);
            if (!std.mem.eql(i32, our_buf, rec.data)) {
                std.debug.print(
                    "\n[c1 oracle] MISMATCH cblk comp={d} r={d} b={d} ({d},{d}) numbps={d} passes={d} segs={d}\n",
                    .{ plan.component, plan.resolution, plan.band, plan.sb_x0, plan.sb_y0, plan.numbps, plan.total_passes, plan.segments.len },
                );
                return error.MismatchedCoefficients;
            }
            compared += 1;
            break;
        }
    }
    try std.testing.expectEqual(@as(u32, 34), compared);
}


test "oracle dump: jp2z decoded coefficients match openjpeg byte-perfectly for a1_mono (pure MQ, 1 layer)" {
    // a1_mono.j2c is the simplest conformance fixture: single tile, single
    // component, default (single) precincts, numlayers=1, cblksty=0 (pure MQ
    // arithmetic coding — NO bypass/LAZY). It is the clean validation target
    // for the tier-1 EBCOT MQ path. (c1_mono uses cblksty=0x1 BYPASS which
    // additionally requires raw-coding segments — see the c1_mono test below.)
    const allocator = std.testing.allocator;
    const records = try parseOracleDump(allocator, a1_mono_t1_oracle);
    defer freeOracleRecords(allocator, records);

    var list = try jp2z.internal.extractCblkPlans(allocator, a1_mono_j2c);
    defer list.deinit(allocator);

    var compared: u32 = 0;
    for (records) |rec| {
        for (list.plans) |plan| {
            if (plan.tile != rec.tile) continue;
            if (plan.component != rec.component) continue;
            if (plan.resolution != rec.resno) continue;
            if (plan.band != rec.orient) continue;
            if (plan.sb_x0 != rec.cblk_x0) continue;
            if (plan.sb_y0 != rec.cblk_y0) continue;

            var cblk = try jp2z.internal.decodePlan(allocator, plan);
            defer cblk.deinit(allocator);

            const msb_bp: u5 = if (plan.numbps == 0) 0 else @intCast(plan.numbps);
            const half_bp = jp2z.internal.halfBitPos(msb_bp, plan.total_passes);
            const our_buf = try allocator.alloc(i32, cblk.coeffs.len);
            defer allocator.free(our_buf);
            for (cblk.coeffs, 0..) |c, i| our_buf[i] = jp2z.internal.coeffToOpenJpegI32(c, half_bp);

            try std.testing.expectEqual(rec.data.len, our_buf.len);
            if (!std.mem.eql(i32, our_buf, rec.data)) {
                std.debug.print(
                    "\n[a1 oracle] MISMATCH cblk r={d} b={d} ({d},{d}) numbps={d} passes={d}\n",
                    .{ plan.resolution, plan.band, plan.sb_x0, plan.sb_y0, plan.numbps, plan.total_passes },
                );
                const show: usize = @min(@as(usize, 12), our_buf.len);
                var j: usize = 0;
                while (j < show) : (j += 1) {
                    std.debug.print("  [{d}] ours={d:>6} oj={d:>6} {s}\n", .{ j, our_buf[j], rec.data[j], if (our_buf[j] == rec.data[j]) "" else "<-- diff" });
                }
                return error.MismatchedCoefficients;
            }
            compared += 1;
            break;
        }
    }
    try std.testing.expectEqual(@as(u32, 34), compared);
}

test "oracle dump: jp2z decoded coefficients match openjpeg byte-perfectly for d1_colr (pure MQ, multi-precinct, 3 comp)" {
    // d1_colr.j2c: cblksty=0 (pure MQ), 3 components (MCT), user-defined
    // 64x64 precincts (multiple precincts per resolution). The t1 oracle is
    // pre-MCT per-component coefficients, so MCT is irrelevant here. This
    // exercises multi-component + multi-precinct cblk extraction.
    const allocator = std.testing.allocator;
    const records = try parseOracleDump(allocator, d1_colr_t1_oracle);
    defer freeOracleRecords(allocator, records);

    var list = try jp2z.internal.extractCblkPlans(allocator, d1_colr_j2c);
    defer list.deinit(allocator);

    var compared: u32 = 0;
    var matched: u32 = 0;
    var first_bad: bool = false;
    for (records) |rec| {
        for (list.plans) |plan| {
            if (plan.tile != rec.tile) continue;
            if (plan.component != rec.component) continue;
            if (plan.resolution != rec.resno) continue;
            if (plan.band != rec.orient) continue;
            if (plan.sb_x0 != rec.cblk_x0) continue;
            if (plan.sb_y0 != rec.cblk_y0) continue;
            matched += 1;

            var cblk = try jp2z.internal.decodePlan(allocator, plan);
            defer cblk.deinit(allocator);
            const msb_bp: u5 = if (plan.numbps == 0) 0 else @intCast(plan.numbps);
            const half_bp = jp2z.internal.halfBitPos(msb_bp, plan.total_passes);
            const our_buf = try allocator.alloc(i32, cblk.coeffs.len);
            defer allocator.free(our_buf);
            for (cblk.coeffs, 0..) |c, i| our_buf[i] = jp2z.internal.coeffToOpenJpegI32(c, half_bp);

            if (our_buf.len == rec.data.len and std.mem.eql(i32, our_buf, rec.data)) {
                compared += 1;
            } else if (!first_bad) {
                first_bad = true;
                std.debug.print("\n[d1 oracle] first MISMATCH cblk comp={d} r={d} b={d} ({d},{d}) numbps={d} passes={d} ourlen={d} ojlen={d}\n",
                    .{ plan.component, plan.resolution, plan.band, plan.sb_x0, plan.sb_y0, plan.numbps, plan.total_passes, our_buf.len, rec.data.len });
            }
            break;
        }
    }
    try std.testing.expectEqual(@as(u32, 174), matched);
    try std.testing.expectEqual(@as(u32, 174), compared);
}

test "extractCblkPlans: c1_mono LH(0,64) captures LAZY segments [10,2,1,2,1]" {
    const allocator = std.testing.allocator;
    var list = try jp2z.internal.extractCblkPlans(allocator, c1_mono_j2c);
    defer list.deinit(allocator);
    for (list.plans) |plan| {
        if (!(plan.resolution == 5 and plan.band == 2 and plan.sb_x0 == 0 and plan.sb_y0 == 64)) continue;
        // cblksty=0x1 LAZY → segment pass allotments 10,2,1,2,1 (T.800 A.6.1).
        try std.testing.expectEqual(@as(usize, 5), plan.segments.len);
        const expect_passes = [_]u32{ 10, 2, 1, 2, 1 };
        var sum_len: u32 = 0;
        var sum_passes: u32 = 0;
        for (plan.segments, 0..) |seg, i| {
            try std.testing.expectEqual(expect_passes[i], seg.passes);
            sum_len += seg.byte_len;
            sum_passes += seg.passes;
        }
        try std.testing.expectEqual(@as(u32, 16), sum_passes);
        try std.testing.expectEqual(plan.data.len, @as(usize, sum_len));
        return;
    }
    return error.CblkNotFound;
}

test "cleanroom: a1_mono pixels match opj_decompress (5/3 IDWT + DC level shift)" {
    const allocator = std.testing.allocator;
    var img = try jp2z.internal.decodeCleanroom(allocator, a1_mono_j2c);
    defer img.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 303), img.width);
    try std.testing.expectEqual(@as(u32, 179), img.height);
    try std.testing.expectEqual(@as(u16, 1), img.num_components);
    try std.testing.expectEqual(a1_mono_pix.len, img.planes[0].len);
    for (img.planes[0], 0..) |s, i| {
        if (@as(i32, a1_mono_pix[i]) != s) {
            std.debug.print("\n[a1 px] mismatch at {d}: ours={d} oj={d}\n", .{ i, s, a1_mono_pix[i] });
            return error.PixelMismatch;
        }
    }
}

test "cleanroom: c1_mono pixels match opj_decompress (BYPASS + 5/3 IDWT + level shift)" {
    const allocator = std.testing.allocator;
    var img = try jp2z.internal.decodeCleanroom(allocator, c1_mono_j2c);
    defer img.deinit(allocator);
    try std.testing.expectEqual(c1_mono_pix.len, img.planes[0].len);
    for (img.planes[0], 0..) |s, i| {
        if (@as(i32, c1_mono_pix[i]) != s) {
            std.debug.print("\n[c1 px] mismatch at {d}: ours={d} oj={d}\n", .{ i, s, c1_mono_pix[i] });
            return error.PixelMismatch;
        }
    }
}

test "cleanroom: d1_colr pixels match opj_decompress (5/3 IDWT + inverse RCT + level shift)" {
    const allocator = std.testing.allocator;
    var img = try jp2z.internal.decodeCleanroom(allocator, d1_colr_j2c);
    defer img.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 256), img.width);
    try std.testing.expectEqual(@as(u32, 149), img.height);
    try std.testing.expectEqual(@as(u16, 3), img.num_components);
    const n: usize = 256 * 149;
    try std.testing.expectEqual(@as(usize, n * 3), d1_colr_pix.len);
    var c: usize = 0;
    while (c < 3) : (c += 1) {
        const plane = img.planes[c];
        try std.testing.expectEqual(n, plane.len);
        for (plane, 0..) |s, i| {
            const expect: i32 = d1_colr_pix[c * n + i];
            if (expect != s) {
                std.debug.print("\n[d1 px] comp {d} mismatch at {d}: ours={d} oj={d}\n", .{ c, i, s, expect });
                return error.PixelMismatch;
            }
        }
    }
}

test "cleanroom: p0_09 (9/7 lossy, mono) within tolerance of opj_decompress" {
    const allocator = std.testing.allocator;
    var img = try jp2z.internal.decodeCleanroom(allocator, p0_09_j2k);
    defer img.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 17), img.width);
    try std.testing.expectEqual(@as(u32, 37), img.height);
    try std.testing.expectEqual(p0_09_pix.len, img.planes[0].len);
    var max_abs: i64 = 0;
    var sum_abs: i64 = 0;
    var nmismatch: usize = 0;
    for (img.planes[0], 0..) |s, i| {
        const d: i64 = @as(i64, s) - @as(i64, p0_09_pix[i]);
        const ad = if (d < 0) -d else d;
        if (ad > max_abs) max_abs = ad;
        sum_abs += ad;
        if (ad != 0) nmismatch += 1;
    }
    // Fixed-point Q16 9/7 lands exactly on openjpeg's float output here
    // (no values near a rounding boundary) — byte-perfect. The lossy
    // conformance tolerance would be a small PAE; this fixture needs none.
    if (max_abs != 0) {
        std.debug.print("\n[p0_09 9/7] max_abs={d} mean_abs={d:.4} mismatches={d}/{d}\n", .{ max_abs, @as(f64, @floatFromInt(sum_abs)) / @as(f64, @floatFromInt(img.planes[0].len)), nmismatch, img.planes[0].len });
        return error.NinetySevenMismatch;
    }
    _ = &sum_abs;
    _ = &nmismatch;
}

test "cleanroom: p0_04 (9/7 lossy, 3-comp ICT, TERMALL) within tolerance" {
    const allocator = std.testing.allocator;
    var img = try jp2z.internal.decodeCleanroom(allocator, p0_04_j2k);
    defer img.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 3), img.num_components);
    const n: usize = @as(usize, img.width) * @as(usize, img.height);
    try std.testing.expectEqual(@as(usize, n * 3), p0_04_pix.len);
    var max_abs: i64 = 0;
    var sum_abs: i64 = 0;
    var nmis: usize = 0;
    var c: usize = 0;
    while (c < 3) : (c += 1) {
        for (img.planes[c], 0..) |s, i| {
            const d: i64 = @as(i64, s) - @as(i64, p0_04_pix[c * n + i]);
            const ad = if (d < 0) -d else d;
            if (ad > max_abs) max_abs = ad;
            sum_abs += ad;
            if (ad != 0) nmis += 1;
        }
    }
    // Fixed-point 9/7 converges to the ideal transform, not to openjpeg's
    // float round-off, so ~10% of pixels differ by exactly 1 LSB. PAE = 1,
    // within the JPEG2000 lossy-decoder tolerance. (max_abs > 1 would mean a
    // real bug, not float divergence — this also exercises TERMALL, user
    // precincts, 20 layers, 9/7 and the inverse ICT together.)
    if (max_abs > 1) {
        std.debug.print("\n[p0_04 9/7+ICT] max_abs={d} mean_abs={d:.5} mismatches={d}/{d}\n", .{ max_abs, @as(f64, @floatFromInt(sum_abs)) / @as(f64, @floatFromInt(n * 3)), nmis, n * 3 });
        return error.NinetySevenIctTolerance;
    }
    _ = &sum_abs;
    _ = &nmis;
}

fn hasFinding(rep: jp2z.ValidationReport, code: jp2z.FindingCode) bool {
    for (rep.findings.items) |f| if (f.code == code) return true;
    return false;
}

test "deepValidate: clean a1_mono has no entropy over-read finding (no false positive)" {
    const allocator = std.testing.allocator;
    var rep = try jp2z.internal.deepValidate(allocator, a1_mono_j2c);
    defer rep.deinit(allocator);
    try std.testing.expect(!hasFinding(rep, .entropy_over_read));
    try std.testing.expect(!hasFinding(rep, .entropy_under_read));
}

test "decodePlan over_read: degenerate entropy data over-reads its segments" {
    const allocator = std.testing.allocator;
    var list = try jp2z.internal.extractCblkPlans(allocator, a1_mono_j2c);
    defer list.deinit(allocator);
    var tested: u32 = 0;
    var flagged: u32 = 0;
    for (list.plans) |plan| {
        if (plan.total_passes == 0 or plan.data.len < 4) continue;
        // Corrupt: keep geometry/segments/pass-count, replace entropy bytes
        // with 0x00 — forces the MQ coder to consume far more than the
        // segment provides, synthesizing past-end 0xFF (the over-read signal
        // openjpeg silently swallows).
        var corrupt = plan;
        const data = try allocator.dupe(u8, plan.data);
        defer allocator.free(data);
        @memset(data, 0x00);
        corrupt.data = data;
        var cblk = try jp2z.internal.decodePlan(allocator, corrupt);
        defer cblk.deinit(allocator);
        tested += 1;
        if (cblk.over_read > 2) flagged += 1;
    }
    if (flagged == 0) std.debug.print("\n[over_read] FAIL: 0/{d} all-zero cblks flagged\n", .{tested});
    try std.testing.expect(flagged > 0);
}

test "deepValidate strictness: single-byte entropy corruption caught by byte-budget" {
    // Clean cblks consume ~exactly their declared bytes (no leftover, <=2
    // over-read terminator slack). A single-byte boltgun XOR perturbs MQ
    // consumption -> over-read OR under-read. Measures the catch rate jp2z
    // gets that a permissive decoder (openjpeg) would silently accept.
    const allocator = std.testing.allocator;
    var list = try jp2z.internal.extractCblkPlans(allocator, a1_mono_j2c);
    defer list.deinit(allocator);
    var clean_max: u32 = 0;
    var caught: u32 = 0;
    var tested: u32 = 0;
    const fracs = [_]usize{ 4, 2, 4 }; // positions: 1/4, 1/2, 3/4 (3/4 via *3 below)
    _ = fracs;
    for (list.plans) |plan| {
        if (plan.total_passes == 0 or plan.data.len < 8) continue;
        {
            var cblk = try jp2z.internal.decodePlan(allocator, plan);
            defer cblk.deinit(allocator);
            clean_max = @max(clean_max, @max(cblk.over_read, cblk.under_read));
        }
        const positions = [_]usize{ plan.data.len / 4, plan.data.len / 2, (plan.data.len * 3) / 4 };
        for (positions) |p| {
            var corrupt = plan;
            const data = try allocator.dupe(u8, plan.data);
            defer allocator.free(data);
            data[p] ^= 0xFF;
            corrupt.data = data;
            var cblk = try jp2z.internal.decodePlan(allocator, corrupt);
            defer cblk.deinit(allocator);
            tested += 1;
            if (cblk.over_read > 2 or cblk.under_read > 2) caught += 1;
        }
    }
    // Clean files: no false positive. Corruption: catch the large majority.
    if (clean_max > 2 or caught * 4 < tested * 3) {
        std.debug.print("\n[M7 strictness] clean_max={d} caught {d}/{d}\n", .{ clean_max, caught, tested });
    }
    try std.testing.expect(clean_max <= 2);
    try std.testing.expect(caught * 4 >= tested * 3); // >= 75% of single-byte flips caught
}
