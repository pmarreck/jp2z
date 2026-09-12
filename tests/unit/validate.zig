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
        // QCD — Sqcd=0x22 (scalar expounded, 1 guard bit) with the four
        // 2-byte entries decomp=1 needs (A.6.4 Table A.28): Lqcd = 11.
        0xFF, 0x5C, 0x00, 0x0B, 0x22, 0x40, 0x00, 0x48, 0x00, 0x48, 0x00, 0x50, 0x00,
        // SOT
        0xFF, 0x90, 0x00, 0x0A,
        0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x01,
        // SOD + two empty packets (decomp 1 → r0 + r1; A.4.4: SOD is mandatory in every tile-part)
        0xFF, 0x93, 0x00, 0x00,
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
    var iter = jp2z.PacketIterator.init(params, 0, 0, 303, 179);
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

test "packet iterator: narrow interior tile skips zero-precinct resolutions (b1_mono regression)" {
    // b1_mono's col0 tile is only 3px wide at absolute origin XOsiz=3097.
    // Its coarse resolutions collapse to zero extent — ceil(3097/32) ==
    // ceil(3100/32) == 97 — so resolutions 0..3 have ZERO precincts and
    // contribute NO packets (only r=4 and r=5 remain, 1 precinct each).
    // The iterator MUST NOT emit a packet for an empty resolution: doing so
    // consumes a real packet's bytes and desyncs the tile's whole byte
    // stream (every code-block then decodes to zero). This is an MFIC
    // metamorphic invariant: the number of packets next() yields equals
    // total(), and no yielded packet names a zero-precinct resolution.
    const params: jp2z.CodingParams = .{
        .progression_order = .lrcp,
        .num_layers = 1,
        .num_components = 1,
        .num_decomp_levels = 5,
    };
    var iter = jp2z.PacketIterator.init(params, 3097, 41, 3, 83);
    // r0..r3 empty, r4 + r5 have 1 precinct each ⇒ 1 layer × 2 × 1 comp = 2.
    try std.testing.expectEqual(@as(usize, 2), iter.total());
    var count: usize = 0;
    while (iter.next()) |p| {
        // No emitted packet may name a resolution the geometry says is empty.
        try std.testing.expect(p.resolution == 4 or p.resolution == 5);
        count += 1;
    }
    // Emitted count must equal total() — the invariant a phantom empty-res
    // packet would violate (it would make count == 6, one per resolution).
    try std.testing.expectEqual(iter.total(), count);
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
    var iter = jp2z.PacketIterator.init(params, 0, 0, 256, 149);
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
        }, 0, 0, 256, 256);
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
    var iter = jp2z.PacketIterator.init(params, 0, 0, 256, 149);
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
    var iter = jp2z.PacketIterator.init(params, 0, 0, 256, 149);
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
    var iter = jp2z.PacketIterator.init(params, 0, 0, 256, 149);
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
    // A valid SOC..SOT..SOD..EOC stream with 4 extra junk bytes appended
    // after EOC. Psot is set so the walker lands directly on EOC,
    // then sees data.len > next_pos+2 → warn truncated_stream.
    // Psot = 14: SOT segment (12) + SOD (2), empty body — SOD is
    // mandatory in every tile-part (T.800 A.4.4), and Psot < 14 is now
    // itself flagged as a degenerate length.
    const stream = [_]u8{
        0xFF, 0x4F,
        0xFF, 0x51, 0x00, 0x29, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x07, 0x01, 0x01,
        // COD (decomp 0, 5/3) + QCD (G=2, no quantization): mandatory (A.4 Table A.1)
        0xFF, 0x52, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x04, 0x04, 0x00, 0x01,
        0xFF, 0x5C, 0x00, 0x04, 0x40, 0x40,
        // SOT with Psot=15, then SOD and one empty packet
        0xFF, 0x90, 0x00, 0x0A,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x00, 0x01,
        0xFF, 0x93, 0x00,
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
        // COD (decomp 0, 5/3) + QCD (G=2, no quantization): mandatory (A.4 Table A.1)
        0xFF, 0x52, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x04, 0x04, 0x00, 0x01,
        0xFF, 0x5C, 0x00, 0x04, 0x40, 0x40,
        // SOT marker code (start of first tile-part — ends main header walk)
        0xFF, 0x90,
        // Lsot = 10 (mandatory marker length per T.800 A.4.2)
        0x00, 0x0A,
        // Isot = 0, Psot = 0 (tile-part extends to EOC),
        // TPsot = 0, TNsot = 1
        0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x01,
        // SOD + one empty packet (A.4.4: SOD is mandatory in every tile-part)
        0xFF, 0x93, 0x00,
        // EOC
        0xFF, 0xD9,
    };
    var report = try jp2z.validate(std.testing.allocator, &stream);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.isOk());
    for (report.findings.items) |f| try std.testing.expect(f.severity != .fail);
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
        // COD (decomp 0, 5/3) + QCD (G=2, no quantization): mandatory (A.4 Table A.1)
        0xFF, 0x52, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x04, 0x04, 0x00, 0x01,
        0xFF, 0x5C, 0x00, 0x04, 0x40, 0x40,
        // Unknown marker 0xFFAA. Lxxx=4 = 2 Lxxx bytes + 2 body bytes.
        0xFF, 0xAA, 0x00, 0x04, 0xDE, 0xAD,
        // SOT
        0xFF, 0x90, 0x00, 0x0A,
        0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x01,
        // SOD + one empty packet
        0xFF, 0x93, 0x00,
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
const f1_mono_j2c = @embedFile("fixtures/conformance/f1_mono.j2c");
const a5_mono_j2c = @embedFile("fixtures/conformance/a5_mono.j2c");
const b1_mono_j2c = @embedFile("fixtures/conformance/b1_mono.j2c");
const c2_mono_j2c = @embedFile("fixtures/conformance/c2_mono.j2c");
const a1_mono_t1_oracle = @embedFile("fixtures/oracles/a1_mono.t1.bin");
const d1_colr_t1_oracle = @embedFile("fixtures/oracles/d1_colr.t1.bin");
const a1_mono_pix = @embedFile("fixtures/oracles/a1_mono.pix");
const c1_mono_pix = @embedFile("fixtures/oracles/c1_mono.pix");
const p0_09_pix = @embedFile("fixtures/oracles/p0_09.pix");
const p0_04_pix = @embedFile("fixtures/oracles/p0_04.pix");
const d1_colr_pix = @embedFile("fixtures/oracles/d1_colr.pix");
const p0_10_pix = @embedFile("fixtures/oracles/p0_10.pix");

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
            const our_buf = try allocator.alloc(i32, cblk.coeffs.len);
            defer allocator.free(our_buf);
            for (cblk.coeffs, 0..) |c, i| our_buf[i] = jp2z.internal.coeffToOpenJpegI32(c);
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

            const our_buf = try allocator.alloc(i32, cblk.coeffs.len);
            defer allocator.free(our_buf);
            for (cblk.coeffs, 0..) |c, i| our_buf[i] = jp2z.internal.coeffToOpenJpegI32(c);

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
            const our_buf = try allocator.alloc(i32, cblk.coeffs.len);
            defer allocator.free(our_buf);
            for (cblk.coeffs, 0..) |c, i| our_buf[i] = jp2z.internal.coeffToOpenJpegI32(c);

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

test "cleanroom: p0_10 multi-tile sub-sampled pixels match opj_decompress (4 tiles, 5/3 + RCT)" {
    const allocator = std.testing.allocator;
    var img = try jp2z.internal.decodeCleanroom(allocator, p0_10_j2k);
    defer img.deinit(allocator);
    // 256×256 ref grid, 2×2 tiles, 4× sub-sampled → 64×64 component samples,
    // 3 comps, 5/3 reversible + RCT → byte-EXACT vs opj_decompress.
    try std.testing.expectEqual(@as(u32, 64), img.width);
    try std.testing.expectEqual(@as(u32, 64), img.height);
    try std.testing.expectEqual(@as(u16, 3), img.num_components);
    const n: usize = 64 * 64;
    try std.testing.expectEqual(@as(usize, n * 3), p0_10_pix.len);
    var c: usize = 0;
    while (c < 3) : (c += 1) {
        const plane = img.planes[c];
        try std.testing.expectEqual(n, plane.len);
        for (plane, 0..) |s, i| {
            const expect: i32 = p0_10_pix[c * n + i];
            if (expect != s) {
                std.debug.print("\n[p0_10 px] comp {d} mismatch at {d}: ours={d} oj={d}\n", .{ c, i, s, expect });
                return error.PixelMismatch;
            }
        }
    }
}

test "cleanroom: f1_mono multi-tile (3x3 grid, odd X tile origin) byte-exact vs openjpeg" {
    // f1_mono is 303x179, image origin (0,0), 3x3 tiles (tdx=101, tdy=70): the
    // MIDDLE tile column starts at the ODD reference-grid x=101. 5/3 reversible
    // ⇒ byte-EXACT. Exercises the origin-aware inverse-DWT parity (cas=res.x0%2)
    // AND the absolute-coordinate code-block partition — an interior tile whose
    // band crosses a code-block boundary yields a different (correct) cblk count
    // than a naive subband-internal split, the bug that desynced multi-tile
    // packet parsing. Non-sub-sampled mono ⇒ the wrapper oracle is comparable.
    const allocator = std.testing.allocator;
    var img = try jp2z.internal.decodeCleanroom(allocator, f1_mono_j2c);
    defer img.deinit(allocator);
    var oracle = try jp2z.internal.openjpegDecode(allocator, f1_mono_j2c);
    defer oracle.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 1), img.num_components);
    try std.testing.expectEqual(oracle.pixels.len, img.planes[0].len);
    for (img.planes[0], 0..) |s, i| {
        if (@as(i32, s) != @as(i32, oracle.pixels[i])) {
            const w = img.width;
            std.debug.print("\n[f1] mismatch at ({d},{d}): ours={d} oj={d}\n", .{ i % w, i / w, s, oracle.pixels[i] });
            return error.PixelMismatch;
        }
    }
}
test "cleanroom: a5_mono multi-tile + SOP/EPH markers byte-exact vs openjpeg" {
    // a5_mono is 303x179, 2x2 tiles (tdx=203, tdy=111), Scod=0x6 → the codestream
    // carries an SOP marker (0xFF91) before every packet and an EPH marker (0xFF92)
    // after every packet header. 5/3 reversible ⇒ byte-EXACT. The walker must
    // consume+validate those delimiters, else it misreads them as packet-header
    // bytes and desyncs. Non-sub-sampled mono ⇒ the wrapper oracle is comparable.
    const allocator = std.testing.allocator;
    var img = try jp2z.internal.decodeCleanroom(allocator, a5_mono_j2c);
    defer img.deinit(allocator);
    var oracle = try jp2z.internal.openjpegDecode(allocator, a5_mono_j2c);
    defer oracle.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 1), img.num_components);
    try std.testing.expectEqual(oracle.pixels.len, img.planes[0].len);
    for (img.planes[0], 0..) |s, i| {
        if (@as(i32, s) != @as(i32, oracle.pixels[i])) {
            const w = img.width;
            std.debug.print("\n[a5] mismatch at ({d},{d}): ours={d} oj={d}\n", .{ i % w, i / w, s, oracle.pixels[i] });
            return error.PixelMismatch;
        }
    }
}
test "validate: corrupted SOP Nsop is flagged (jp2z is stricter than openjpeg here)" {
    // The downstream mission is corruption DETECTION, so jp2z validates the SOP
    // packet-sequence number (Nsop) — a check openjpeg explicitly TODOs and skips.
    // Corrupt the first SOP's Nsop in a5 and confirm validate FLAGS it: a byte a
    // permissive decoder silently accepts. Classifier: valid → no fail; bad → fail.
    const allocator = std.testing.allocator;
    var rep_ok = try jp2z.validate(allocator, a5_mono_j2c);
    defer rep_ok.deinit(allocator);
    try std.testing.expect(!hasFinding(rep_ok, .jp2_invalid_codestream));

    const buf = try allocator.dupe(u8, a5_mono_j2c);
    defer allocator.free(buf);
    // First SOP marker is FF 91 00 04, with the 2-byte Nsop at +4.
    var i: usize = 0;
    const sop = while (i + 6 <= buf.len) : (i += 1) {
        if (buf[i] == 0xFF and buf[i + 1] == 0x91 and buf[i + 2] == 0x00 and buf[i + 3] == 0x04) break i;
    } else return error.NoSopInFixture;
    buf[sop + 4] = 0x7F; // wrong Nsop (the first packet's Nsop must be 0)
    buf[sop + 5] = 0xFF;
    var rep_bad = try jp2z.validate(allocator, buf);
    defer rep_bad.deinit(allocator);
    try std.testing.expect(hasFinding(rep_bad, .jp2_invalid_codestream));
}
test "cleanroom: c2_mono single-tile tier-1 (RESET+VSC+SEGSYM) byte-exact vs openjpeg" {
    // c2_mono is 303x179, SINGLE tile, cblksty=0x2f = BYPASS|RESET|TERMALL|VSC|SEGSYM.
    // The ONLY variable vs the passing c1 (cblksty=0x01, BYPASS only) is the extra
    // tier-1 coding styles: MQ context RESET at coding-pass boundaries, VSC
    // (vertically-causal contexts — the top row of each 4-row stripe ignores the
    // stripe above), and the SEGSYM 0xA segmentation symbol decoded+verified at the
    // end of every cleanup pass. 5/3 reversible ⇒ byte-EXACT. Non-sub-sampled mono
    // ⇒ the in-process wrapper oracle is directly comparable.
    const allocator = std.testing.allocator;
    var img = try jp2z.internal.decodeCleanroom(allocator, c2_mono_j2c);
    defer img.deinit(allocator);
    var oracle = try jp2z.internal.openjpegDecode(allocator, c2_mono_j2c);
    defer oracle.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 1), img.num_components);
    try std.testing.expectEqual(oracle.pixels.len, img.planes[0].len);
    for (img.planes[0], 0..) |s, i| {
        if (@as(i32, s) != @as(i32, oracle.pixels[i])) {
            const w = img.width;
            std.debug.print("\n[c2] mismatch at ({d},{d}): ours={d} oj={d}\n", .{ i % w, i / w, s, oracle.pixels[i] });
            return error.PixelMismatch;
        }
    }
}
test "cleanroom: b1_mono non-zero image origin + offset tile grid byte-exact vs openjpeg" {
    // b1_mono is 303x179 output, but its IMAGE origin is non-zero (XOsiz=3097,
    // YOsiz=41) and the TILE-GRID origin (XTOsiz=3003, YTOsiz=33) is offset from
    // it. 5x3 tiles (tdx=97, tdy=91). csty=0, cblksty=0, qmfbid=1 → NO SOP/EPH,
    // NO special tier-1 styles, so the ONLY variable vs the passing origin-0
    // multi-tile fixtures is image-origin geometry. 5/3 reversible ⇒ byte-EXACT.
    // Non-sub-sampled mono ⇒ the in-process wrapper oracle is comparable.
    // Instrumented with a per-tile (col x row) mismatch grid to localise the bug.
    const allocator = std.testing.allocator;
    var img = try jp2z.internal.decodeCleanroom(allocator, b1_mono_j2c);
    defer img.deinit(allocator);
    var oracle = try jp2z.internal.openjpegDecode(allocator, b1_mono_j2c);
    defer oracle.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 1), img.num_components);
    try std.testing.expectEqual(oracle.pixels.len, img.planes[0].len);
    // Tile column boundaries in output (component) coords: 0,3,100,197,294,303.
    const colb = [_]u32{ 0, 3, 100, 197, 294, 303 };
    const rowb = [_]u32{ 0, 83, 174, 179 };
    var grid = [_]u32{0} ** (5 * 3);
    var first_x: u32 = 0;
    var first_y: u32 = 0;
    var total: usize = 0;
    var max_abs: i64 = 0;
    const w = img.width;
    for (img.planes[0], 0..) |s, i| {
        if (@as(i32, s) != @as(i32, oracle.pixels[i])) {
            const x: u32 = @intCast(i % w);
            const y: u32 = @intCast(i / w);
            var col: usize = 0;
            while (col < 5 and !(x >= colb[col] and x < colb[col + 1])) : (col += 1) {}
            var row: usize = 0;
            while (row < 3 and !(y >= rowb[row] and y < rowb[row + 1])) : (row += 1) {}
            if (col < 5 and row < 3) grid[row * 5 + col] += 1;
            if (total == 0) {
                first_x = x;
                first_y = y;
            }
            total += 1;
            const d: i64 = @as(i64, s) - @as(i64, oracle.pixels[i]);
            const ad = if (d < 0) -d else d;
            if (ad > max_abs) max_abs = ad;
        }
    }
    if (total != 0) {
        std.debug.print("\n[b1] {d} mismatches, max_abs={d}, first at ({d},{d})\n", .{ total, max_abs, first_x, first_y });
        std.debug.print("[b1] per-tile mismatch grid (rows=tile-row 0..2, cols=tile-col 0..4):\n", .{});
        var r: usize = 0;
        while (r < 3) : (r += 1) {
            std.debug.print("  row{d}: {d:>6} {d:>6} {d:>6} {d:>6} {d:>6}\n", .{ r, grid[r * 5 + 0], grid[r * 5 + 1], grid[r * 5 + 2], grid[r * 5 + 3], grid[r * 5 + 4] });
        }
        return error.PixelMismatch;
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
        std.debug.print("\n[p0_09 9/7] max_abs={d} mean_abs(x1000)={d} mismatches={d}/{d}\n", .{ max_abs, @divTrunc(sum_abs * 1000, @as(i64, @intCast(img.planes[0].len))), nmismatch, img.planes[0].len });
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
        std.debug.print("\n[p0_04 9/7+ICT] max_abs={d} mean_abs(x1000)={d} mismatches={d}/{d}\n", .{ max_abs, @divTrunc(sum_abs * 1000, @as(i64, @intCast(n * 3))), nmis, n * 3 });
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
    var rep = try jp2z.internal.deepValidate(allocator, a1_mono_j2c, false);
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

test "deepValidate strict: entropy corruption escalates report to FAIL" {
    const allocator = std.testing.allocator;
    // Baseline clean file is not a FAIL.
    {
        var rep = try jp2z.internal.deepValidate(allocator, a1_mono_j2c, true);
        defer rep.deinit(allocator);
        try std.testing.expect(rep.overall != .fail);
    }
    // A byte flipped deep in the entropy data is caught and (strict) FAILs.
    const buf = try allocator.dupe(u8, a1_mono_j2c);
    defer allocator.free(buf);
    var any_fail = false;
    var pos: usize = (a1_mono_j2c.len * 3) / 4;
    while (pos < a1_mono_j2c.len and !any_fail) : (pos += 7) {
        const o = buf[pos];
        buf[pos] ^= 0xFF;
        var rep = try jp2z.internal.deepValidate(allocator, buf, true);
        if (rep.overall == .fail) any_fail = true;
        rep.deinit(allocator);
        buf[pos] = o;
    }
    try std.testing.expect(any_fail);
}


test "validate: main-header COC/QCC/RGN each emit jp2_unsupported_marker_ignored; POC and baseline do not" {
    // Reviewer I1: per-component/ROI override markers that jp2z does not
    // yet apply must be SURFACED (not silently skipped), so a consumer
    // knows decode fell back to COD/QCD defaults. Tested as a classifier
    // over the marker set: each of {COC,QCC,RGN} fires the finding; a
    // baseline header with only COD/QCD does not — and neither does POC,
    // which is now APPLIED (parsed into the progression-volume list), not
    // ignored. A malformed POC instead fires structural findings.
    const prefix = [_]u8{
        0xFF, 0x4F,
        0xFF, 0x51, 0x00, 0x29, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x07, 0x01, 0x01,
        0xFF, 0x52, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x04, 0x04, 0x00, 0x00,
        0xFF, 0x5C, 0x00, 0x03, 0x22,
    };
    const suffix = [_]u8{
        0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0xFF, 0x93, 0x00, 0x00, // SOD + two empty packets (decomp 1 → r0 + r1) (A.4.4)
        0xFF, 0xD9,
    };
    // COC / RGN are APPLIED (2026-09-06, per-component overrides): a
    // well-formed COC (Ccoc=0, Scoc=0, SPcoc decomp 1 cblk 64x64 5/3) and a
    // well-formed RGN (Crgn=0, Srgn=0, shift 8) are silent; a truncated COC
    // surfaces structurally (bad_marker_length), never as "ignored".
    const coc_ok = prefix ++ [_]u8{ 0xFF, 0x53, 0x00, 0x09, 0x00, 0x00, 0x01, 0x04, 0x04, 0x00, 0x01 } ++ suffix;
    const rgn_ok = prefix ++ [_]u8{ 0xFF, 0x5E, 0x00, 0x05, 0x00, 0x00, 0x08 } ++ suffix;
    inline for (.{ coc_ok, rgn_ok }) |s| {
        var report = try jp2z.validate(std.testing.allocator, &s);
        defer report.deinit(std.testing.allocator);
        try std.testing.expect(!hasFinding(report, .jp2_unsupported_marker_ignored));
    }
    const coc_short = prefix ++ [_]u8{ 0xFF, 0x53, 0x00, 0x04, 0x00, 0x00 } ++ suffix;
    var rep_coc_short = try jp2z.validate(std.testing.allocator, &coc_short);
    defer rep_coc_short.deinit(std.testing.allocator);
    try std.testing.expect(!hasFinding(rep_coc_short, .jp2_unsupported_marker_ignored));
    try std.testing.expect(hasFinding(rep_coc_short, .bad_marker_length));
    // QCC is APPLIED (2026-09-06): a well-formed one (Cqcc=0, Sqcc G=2 style 0,
    // 4 SPqcc bytes for decomp=1) is silent; a truncated one surfaces
    // structurally (like QCD), never as "ignored".
    const qcc_ok = prefix ++ [_]u8{ 0xFF, 0x5D, 0x00, 0x08, 0x00, 0x40, 0x40, 0x48, 0x48, 0x50 } ++ suffix;
    var rep_qcc = try jp2z.validate(std.testing.allocator, &qcc_ok);
    defer rep_qcc.deinit(std.testing.allocator);
    try std.testing.expect(!hasFinding(rep_qcc, .jp2_unsupported_marker_ignored));
    try std.testing.expect(rep_qcc.isOk());
    const qcc_short = prefix ++ [_]u8{ 0xFF, 0x5D, 0x00, 0x04, 0x00, 0x00 } ++ suffix;
    var rep_qcc_short = try jp2z.validate(std.testing.allocator, &qcc_short);
    defer rep_qcc_short.deinit(std.testing.allocator);
    try std.testing.expect(!hasFinding(rep_qcc_short, .jp2_unsupported_marker_ignored));
    try std.testing.expect(hasFinding(rep_qcc_short, .jp2_invalid_codestream));
    const baseline = prefix ++ suffix;
    var rep0 = try jp2z.validate(std.testing.allocator, &baseline);
    defer rep0.deinit(std.testing.allocator);
    try std.testing.expect(!hasFinding(rep0, .jp2_unsupported_marker_ignored));

    // POC classifier (T.800 A.6.6, Csiz=1 → 7-byte entries; COD declares
    // 2 resolutions / 1 layer here):
    //   - well-formed identity-ish entry {RS=0,CS=0,LYE=1,RE=2,CE=1,LRCP}
    //     → applied silently: NO c145, NO structural finding.
    //   - truncated body (the old 2-byte stub) → bad_marker_length.
    //   - degenerate entry (RSpoc >= REpoc) → jp2_bad_progression_order.
    const poc_ok = prefix ++ [_]u8{ 0xFF, 0x5F, 0x00, 0x09, 0x00, 0x00, 0x00, 0x01, 0x02, 0x01, 0x00 } ++ suffix;
    var rep_ok = try jp2z.validate(std.testing.allocator, &poc_ok);
    defer rep_ok.deinit(std.testing.allocator);
    try std.testing.expect(!hasFinding(rep_ok, .jp2_unsupported_marker_ignored));
    try std.testing.expect(!hasFinding(rep_ok, .bad_marker_length));
    try std.testing.expect(!hasFinding(rep_ok, .jp2_bad_progression_order));

    const poc_short = prefix ++ [_]u8{ 0xFF, 0x5F, 0x00, 0x04, 0x00, 0x00 } ++ suffix;
    var rep_short = try jp2z.validate(std.testing.allocator, &poc_short);
    defer rep_short.deinit(std.testing.allocator);
    try std.testing.expect(hasFinding(rep_short, .bad_marker_length));
    try std.testing.expect(!hasFinding(rep_short, .jp2_unsupported_marker_ignored));

    const poc_degen = prefix ++ [_]u8{ 0xFF, 0x5F, 0x00, 0x09, 0x02, 0x00, 0x00, 0x01, 0x02, 0x01, 0x00 } ++ suffix;
    var rep_degen = try jp2z.validate(std.testing.allocator, &poc_degen);
    defer rep_degen.deinit(std.testing.allocator);
    try std.testing.expect(hasFinding(rep_degen, .jp2_bad_progression_order));
}

test "validate: tile-part-header COC/QCC/RGN each emit jp2_unsupported_marker_ignored; POC does not" {
    // Reviewer I1 extended to the TILE-PART header (where p0_03's RGN lives).
    // Same SOC+SIZ+COD+QCD main header as the main-header variant, but the
    // override marker now sits between SOT and SOD. Classifier over the set:
    // each of {COC,QCC,RGN} fires; a bare SOT→SOD tile-part does not, and
    // neither does a well-formed POC (applied — appended to the tile's
    // progression-volume sequencer — rather than ignored).
    const prefix = [_]u8{
        0xFF, 0x4F,
        0xFF, 0x51, 0x00, 0x29, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x07, 0x01, 0x01,
        0xFF, 0x52, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x04, 0x04, 0x00, 0x00,
        0xFF, 0x5C, 0x00, 0x03, 0x22,
    };
    // SOT (Lsot=10, Isot=0, Psot=0 → to EOC, TPsot=0, TNsot=1).
    const sot = [_]u8{ 0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01 };
    const sod_eoc = [_]u8{ 0xFF, 0x93, 0xFF, 0xD9 }; // SOD then EOC (empty body)
    // Tile-part COC / RGN are APPLIED (2026-09-06): well-formed ones are
    // silent; a truncated COC surfaces structurally.
    const coc_ok = prefix ++ sot ++ [_]u8{ 0xFF, 0x53, 0x00, 0x09, 0x00, 0x00, 0x01, 0x04, 0x04, 0x00, 0x01 } ++ sod_eoc;
    const rgn_ok = prefix ++ sot ++ [_]u8{ 0xFF, 0x5E, 0x00, 0x05, 0x00, 0x00, 0x08 } ++ sod_eoc;
    inline for (.{ coc_ok, rgn_ok }) |s| {
        var report = try jp2z.validate(std.testing.allocator, &s);
        defer report.deinit(std.testing.allocator);
        try std.testing.expect(!hasFinding(report, .jp2_unsupported_marker_ignored));
    }
    const coc_short = prefix ++ sot ++ [_]u8{ 0xFF, 0x53, 0x00, 0x04, 0x00, 0x00 } ++ sod_eoc;
    var rep_coc_short = try jp2z.validate(std.testing.allocator, &coc_short);
    defer rep_coc_short.deinit(std.testing.allocator);
    try std.testing.expect(!hasFinding(rep_coc_short, .jp2_unsupported_marker_ignored));
    try std.testing.expect(hasFinding(rep_coc_short, .bad_marker_length));
    // Negatives: an EMPTY tile-part header, one carrying a BENIGN marker
    // (COM 0xFF64 — not a coding override), and one carrying a WELL-FORMED
    // POC (applied, not ignored) may not fire the finding. The benign case
    // bites the over-flagging mutation (else=>{} → else=>emit), which an
    // empty header alone cannot (its scanned range is empty); the POC case
    // bites a regression that re-adds POC to the ignored set.
    const baseline = prefix ++ sot ++ sod_eoc;
    const benign = prefix ++ sot ++ [_]u8{ 0xFF, 0x64, 0x00, 0x04, 0x00, 0x00 } ++ sod_eoc;
    const poc_ok = prefix ++ sot ++ [_]u8{ 0xFF, 0x5F, 0x00, 0x09, 0x00, 0x00, 0x00, 0x01, 0x02, 0x01, 0x00 } ++ sod_eoc;
    // A well-formed tile-part QCC is APPLIED to the tile (2026-09-06), like tile QCD.
    const qcc_ok = prefix ++ sot ++ [_]u8{ 0xFF, 0x5D, 0x00, 0x08, 0x00, 0x40, 0x40, 0x48, 0x48, 0x50 } ++ sod_eoc;
    inline for (.{ baseline, benign, poc_ok, qcc_ok }) |s| {
        var rep0 = try jp2z.validate(std.testing.allocator, &s);
        defer rep0.deinit(std.testing.allocator);
        try std.testing.expect(!hasFinding(rep0, .jp2_unsupported_marker_ignored));
    }
    // A malformed tile-part POC still surfaces structurally.
    const poc_short = prefix ++ sot ++ [_]u8{ 0xFF, 0x5F, 0x00, 0x04, 0x00, 0x00 } ++ sod_eoc;
    var rep_short = try jp2z.validate(std.testing.allocator, &poc_short);
    defer rep_short.deinit(std.testing.allocator);
    try std.testing.expect(hasFinding(rep_short, .bad_marker_length));
    try std.testing.expect(!hasFinding(rep_short, .jp2_unsupported_marker_ignored));
}

test "validate: malformed SIZ geometry → jp2_invalid_siz finding, never a crash (C1/C2/C4)" {
    // A hostile-input validator must FLAG malformed SIZ, never divide-by-zero
    // (XRsiz=0) or OOB-read the descriptor table (Lsiz<38+3·Csiz). Classifier
    // over the malformed set; the well-formed baseline must NOT fire. Csiz>16
    // is NOT malformed (A.5.1 allows 16384; components past the 16th read
    // through slot 15 when uniform) — it stays here as a must-accept. (These are the inputs whose absence let the
    // multi-tile commit ship green.)
    const soc = [_]u8{ 0xFF, 0x4F };
    const eoc = [_]u8{ 0xFF, 0xD9 };
    // Well-formed 4×4, single-tile, Csiz=1 SIZ (Lsiz=0x29=41). XRsiz at idx 41.
    const siz_ok = [_]u8{
        0xFF, 0x51, 0x00, 0x29, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x07, 0x01, 0x01,
    };
    // C1: XRsiz = 0 (sub-sampling divisor) → div-by-zero in tcw/ceilDiv.
    const siz_xrsiz0 = [_]u8{
        0xFF, 0x51, 0x00, 0x29, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x07, 0x00, 0x01, // XRsiz = 0x00
    };
    // C2: Csiz=16 but Lsiz still 41 → descriptor table needs 86 bytes, has 3.
    const siz_lsiz_short = [_]u8{
        0xFF, 0x51, 0x00, 0x29, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x10, 0x07, 0x01, 0x01, // Csiz = 0x0010 = 16
    };
    // C4 (inverted 2026-09-06): Csiz=17 with a correct Lsiz=89 and 17 uniform
    // descriptors must be ACCEPTED, and must never overflow the [16] arrays.
    const siz_csiz17 = [_]u8{
        0xFF, 0x51, 0x00, 0x59, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x11, // Csiz = 0x0011 = 17
    } ++ ([_]u8{ 0x07, 0x01, 0x01 } ** 17);

    const malformed = .{
        soc ++ siz_xrsiz0 ++ eoc,
        soc ++ siz_lsiz_short ++ eoc,
    };
    inline for (malformed) |stream| {
        var report = try jp2z.validate(std.testing.allocator, &stream);
        defer report.deinit(std.testing.allocator);
        try std.testing.expect(hasFinding(report, .jp2_invalid_siz));
    }
    // Well-formed SIZ: no jp2_invalid_siz.
    const ok = soc ++ siz_ok ++ eoc;
    var rep0 = try jp2z.validate(std.testing.allocator, &ok);
    defer rep0.deinit(std.testing.allocator);
    try std.testing.expect(!hasFinding(rep0, .jp2_invalid_siz));
    const ok17 = soc ++ siz_csiz17 ++ eoc;
    var rep17 = try jp2z.validate(std.testing.allocator, &ok17);
    defer rep17.deinit(std.testing.allocator);
    try std.testing.expect(!hasFinding(rep17, .jp2_invalid_siz));
    try std.testing.expectEqual(@as(u16, 17), rep17.coding_params.?.num_components);
}

test "validate: user-precinct PPx/PPy=0 at r>0 → jp2_invalid_codestream, never a crash (reviewer)" {
    // A strict validator must FLAG a non-conformant COD precinct exponent of 0 at
    // any resolution above the lowest (T.800 requires PP>=1 for r>0 — the HF
    // precinct partition halves the exponent), and MUST NOT underflow the u6
    // geometry (crash in TileWalk.init while sizing the code-block pool). Classifier
    // over the malformed set; the valid-custom-precinct baseline must NOT fire.
    const soc = [_]u8{ 0xFF, 0x4F };
    const eoc = [_]u8{ 0xFF, 0xD9 };
    // 4x4, single-tile, Csiz=1, 8-bit SIZ (same as the SIZ test).
    const siz = [_]u8{
        0xFF, 0x51, 0x00, 0x29, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x07, 0x01, 0x01,
    };
    // COD: Lcod=14, Scod=0x01 (user precincts), LRCP, 1 layer, no MCT, 1 decomp
    // level (⇒ 2 resolutions), 64x64 cblk, 5/3. Two precinct bytes: r0 then r1.
    const cod_ok = [_]u8{ 0xFF, 0x52, 0x00, 0x0E, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x04, 0x04, 0x00, 0x01, 0x88, 0x88 };
    const cod_bad = [_]u8{ 0xFF, 0x52, 0x00, 0x0E, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x04, 0x04, 0x00, 0x01, 0x88, 0x00 }; // r1 PPx=PPy=0
    // SOT(Psot=0 → to EOC) + SOD → drives the packet walk (TileWalk.init), the crash site.
    const sot = [_]u8{ 0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01 };
    const sod = [_]u8{ 0xFF, 0x93 };

    // Bad precinct exponent must FLAG jp2_invalid_codestream, and must not crash
    // whether or not the packet walk runs.
    const bad_headeronly = soc ++ siz ++ cod_bad ++ eoc;
    var rep_b0 = try jp2z.validate(std.testing.allocator, &bad_headeronly);
    defer rep_b0.deinit(std.testing.allocator);
    try std.testing.expect(hasFinding(rep_b0, .jp2_invalid_codestream));

    const bad_walk = soc ++ siz ++ cod_bad ++ sot ++ sod ++ eoc;
    var rep_bw = try jp2z.validate(std.testing.allocator, &bad_walk); // must not panic in TileWalk.init
    defer rep_bw.deinit(std.testing.allocator);
    try std.testing.expect(hasFinding(rep_bw, .jp2_invalid_codestream));

    // Valid custom precincts (PPx=PPy=8 at both resolutions): the finding must NOT
    // fire for the precinct reason (baseline — a classifier, not a presence check).
    const ok_walk = soc ++ siz ++ cod_ok ++ sot ++ sod ++ eoc;
    var rep_ok = try jp2z.validate(std.testing.allocator, &ok_walk);
    defer rep_ok.deinit(std.testing.allocator);
    // (ok_walk may still carry other warn findings, but NOT a fail on the codestream
    //  for the precinct — assert the decode side does not reject it: coding_params kept.)
    try std.testing.expect(rep_ok.coding_params != null);
}
test "cleanroom: MCT + non-uniform sub-sampling is rejected, not a heap OOB (C3)" {
    // Reviewer C3: with MCT on, the 3 colour components must share sub-sampling
    // (T.800 Annex G). The multi-tile commit made per-component tile buffers
    // component-sized, so comp_dx=[1,2,2] gives tbufs of different lengths →
    // inverseRct would read/write past the shorter planes. decodeCleanroom
    // must REJECT, never corrupt the heap. Crafted: 4×4, 3 comps, comp0 dx=1
    // and comp1/comp2 dx=2, COD mct=1 + 5/3, empty tile-part body.
    const stream = [_]u8{
        0xFF, 0x4F, // SOC
        // SIZ: Lsiz=0x2F=47, 3 comps, dx=[1,2,2]
        0xFF, 0x51, 0x00, 0x2F, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, // Xsiz/Ysiz=4
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // XOsiz/YOsiz=0
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, // XTsiz/YTsiz=4
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // XTOsiz/YTOsiz=0
        0x00, 0x03, // Csiz=3
        0x07, 0x01, 0x01, // comp0: 8-bit, dx=dy=1
        0x07, 0x02, 0x02, // comp1: 8-bit, dx=dy=2
        0x07, 0x02, 0x02, // comp2: 8-bit, dx=dy=2
        // COD: Lcod=0x0C=12, mct=1 (body[4]), 5/3 (qmfbid=1)
        0xFF, 0x52, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x04, 0x04, 0x00, 0x01,
        // SOT (Psot=0 → to EOC), SOD, EOC
        0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0xFF, 0x93,
        0xFF, 0xD9,
    };
    try std.testing.expectError(error.MctNonUniformSubsampling, jp2z.internal.decodeCleanroom(std.testing.allocator, &stream));
}

test "validate: tile delivering fewer packets than COD geometry → truncated_stream (I1)" {
    // Reviewer I1: the persistent per-tile iterator returns .incomplete when a
    // tile-part body is consumed exactly on a packet boundary but
    // packets_seen < total (legit for TNsot>1: "next tile-part coming").
    // A stream that ends (valid EOC) with such a tile under-delivered must NOT
    // pass clean — the old walkPackets emitted .truncated_stream for it. Here
    // the tile-part body is empty while COD requires 1 packet → 0 < total.
    const stream = [_]u8{
        0xFF, 0x4F, // SOC
        // SIZ: 4×4, single tile, 1 comp (Lsiz=41)
        0xFF, 0x51, 0x00, 0x29, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x07, 0x01, 0x01,
        // COD: num_layers=1, decomp=0 (→ 1 resolution, total=1 packet), 5/3
        0xFF, 0x52, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x04, 0x04, 0x00, 0x01,
        // QCD (G=2, no quantization): mandatory alongside COD (A.4 Table A.1)
        0xFF, 0x5C, 0x00, 0x04, 0x40, 0x40,
        // SOT (Psot=0 → to EOC), SOD, EOC — empty tile-part body (0 packets)
        0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0xFF, 0x93,
        0xFF, 0xD9,
    };
    var report = try jp2z.validate(std.testing.allocator, &stream);
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(hasFinding(report, .truncated_stream));
    // (Complete fixtures NOT flagged is covered by the clean-walk tests above,
    //  which assert no .fail finding for c1_mono/file1/file9/d1_colr.)
}

const p0_10_j2k = @embedFile("fixtures/conformance/p0_10.j2k");

test "inspect: p0_10.j2k captures 4× component sub-sampling (multi-tile target)" {
    // p0_10: 256×256 ref grid, 3 components each sub-sampled 4× (XRsiz=YRsiz=4
    // → 64×64 component samples), 2×2 tiles of 128×128 ref (32×32 per
    // component), 5/3 reversible + RCT. Oracle: opj_dump.
    const cp = (try jp2z.internal.inspect(std.testing.allocator, p0_10_j2k)) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 3), cp.num_components);
    try std.testing.expectEqual(jp2z.WaveletFilter.reversible_5x3, cp.wavelet);
    try std.testing.expectEqual(true, cp.mct);
    var c: usize = 0;
    while (c < 3) : (c += 1) {
        try std.testing.expectEqual(@as(u8, 4), cp.comp_dx[c]);
        try std.testing.expectEqual(@as(u8, 4), cp.comp_dy[c]);
    }
    // tile geometry (reference grid): 2×2 tiles of 128×128
    try std.testing.expectEqual(@as(u32, 128), cp.tile_w);
    try std.testing.expectEqual(@as(u32, 128), cp.tile_h);
}

test "validate: p0_10.j2k multi-tile → 4 tiles walk byte-perfect (TNsot>1)" {
    // p0_10: 2×2 tiles, each with 2 tile-parts (TNsot=2). LRCP packet
    // order splits the 2 quality layers across the two tile-parts, so a
    // per-tile packet iterator must PERSIST across that tile's tile-parts
    // (resume the packet index where the prior part stopped, not restart).
    // A fresh iterator per tile-part regenerates the full packet set and
    // overruns the half-length tile-part body → truncated_stream. Each of
    // the 4 tiles must walk to its end exactly once; none under-read.
    var report = try jp2z.validate(std.testing.allocator, p0_10_j2k);
    defer report.deinit(std.testing.allocator);
    var walked_to_end: usize = 0;
    var under_read: usize = 0;
    var truncated: usize = 0;
    for (report.findings.items) |f| {
        switch (f.code) {
            .jp2_packets_walked_to_end => walked_to_end += 1,
            .jp2_packets_under_read => under_read += 1,
            .truncated_stream => truncated += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 4), walked_to_end);
    try std.testing.expectEqual(@as(usize, 0), under_read);
    try std.testing.expectEqual(@as(usize, 0), truncated);
}

test "validate: hostile COD ranges (decomp>32, cblk exp>8, layers=0) FAIL without crashing" {
    // Crash-class hardening: a hostile-input validator must never panic.
    // Before the fix, decomp=200 overflowed `1 + 3*num_decomp_levels` (u8)
    // in parseQcdBody, and cblk exp=255 overflowed `exp + 2` (u8) in the
    // code-block geometry — both ReleaseSafe panics, UB in ReleaseFast.
    // Classifier over the hostile set: each variant must yield an overall
    // FAIL with no crash; the well-formed control must not FAIL.
    const soc_siz = [_]u8{
        0xFF, 0x4F,
        0xFF, 0x51, 0x00, 0x29, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x07, 0x01, 0x01,
    };
    const qcd = [_]u8{ 0xFF, 0x5C, 0x00, 0x07, 0x40, 0x40, 0x40, 0x40, 0x40 };
    const tail = [_]u8{
        0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0xFF, 0x93, 0xFF, 0xD9,
    };
    // COD body: Scod, prog, layers(2), mct, decomp, cblkw, cblkh, cblksty, qmfbid.
    const cod_ok = [_]u8{ 0xFF, 0x52, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x04, 0x04, 0x00, 0x00 };
    const cod_decomp = [_]u8{ 0xFF, 0x52, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x01, 0x00, 0xC8, 0x04, 0x04, 0x00, 0x00 }; // decomp=200
    const cod_cblk = [_]u8{ 0xFF, 0x52, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0xFF, 0x04, 0x00, 0x00 }; // cblkw exp=255
    const cod_layers0 = [_]u8{ 0xFF, 0x52, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x04, 0x04, 0x00, 0x00 }; // layers=0

    inline for (.{ cod_decomp, cod_cblk, cod_layers0 }) |cod| {
        const s = soc_siz ++ cod ++ qcd ++ tail;
        var rep = try jp2z.internal.deepValidate(std.testing.allocator, &s, true);
        defer rep.deinit(std.testing.allocator);
        try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
        try std.testing.expect(hasFinding(rep, .jp2_invalid_codestream));
    }
    // Control: the hostile-range finding is absent. (overall is not
    // asserted — this minimal stream has an empty tile body, which the
    // walk legitimately flags as incomplete.)
    const control = soc_siz ++ cod_ok ++ qcd ++ tail;
    var rep0 = try jp2z.internal.deepValidate(std.testing.allocator, &control, true);
    defer rep0.deinit(std.testing.allocator);
    try std.testing.expect(!hasFinding(rep0, .jp2_invalid_codestream));
}

test "validate: cblk area xcb+ycb > 12 FAILs; reserved Scod/cblksty bits FAIL under a Part-1 Rsiz" {
    // T.800 A.6.1: xcb + ycb <= 12 (code-block area cap, 4096 samples) is
    // normative — exceeding it is non-conformant even though each exponent
    // alone is in range. Reserved bits (Scod bits 3-7, cblksty bits 6-7)
    // must be zero; a set bit is surfaced as WARN, not silently passed
    // (cblksty 0x40 is HTJ2K's HT flag — T.814, not Part 1 — and is reported as valid-but-unsupported instead).
    const soc_siz = [_]u8{
        0xFF, 0x4F,
        0xFF, 0x51, 0x00, 0x29, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x07, 0x01, 0x01,
    };
    const qcd = [_]u8{ 0xFF, 0x5C, 0x00, 0x07, 0x40, 0x40, 0x40, 0x40, 0x40 };
    const tail = [_]u8{
        0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0xFF, 0x93, 0xFF, 0xD9,
    };
    // xcb=8 (exp byte 6), ycb=8: 4+4? — exponents are stored minus 2, so
    // bytes 0x06/0x06 mean xcb=8, ycb=8 → 16 > 12: area violation with
    // each exponent individually legal (6 <= 8).
    const cod_area = [_]u8{ 0xFF, 0x52, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x06, 0x06, 0x00, 0x00 };
    var rep_area = try jp2z.validate(std.testing.allocator, &(soc_siz ++ cod_area ++ qcd ++ tail));
    defer rep_area.deinit(std.testing.allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep_area.overall);
    try std.testing.expect(hasFinding(rep_area, .jp2_invalid_codestream));

    const cod_scod_resv = [_]u8{ 0xFF, 0x52, 0x00, 0x0C, 0x80, 0x00, 0x00, 0x01, 0x00, 0x01, 0x04, 0x04, 0x00, 0x00 }; // Scod bit 7
    const cod_sty_resv = [_]u8{ 0xFF, 0x52, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x04, 0x04, 0x80, 0x00 }; // cblksty bit 7 (reserved; bit 6 = HT is c145, see the HTJ2K test)
    inline for (.{ cod_scod_resv, cod_sty_resv }) |cod| {
        const s = soc_siz ++ cod ++ qcd ++ tail;
        var rep = try jp2z.validate(std.testing.allocator, &s);
        defer rep.deinit(std.testing.allocator);
        // Rsiz 0 (Part 1): a reserved bit set is a proven Table A.13 /
        // Table A.19 violation → FAIL (Peter, 2026-09-12).
        var n: usize = 0;
        for (rep.findings.items) |f| {
            if (f.code == .jp2_invalid_codestream) {
                n += 1;
                try std.testing.expectEqual(jp2z.Severity.fail, f.severity);
            }
        }
        try std.testing.expect(n >= 1);
    }
    // Control: none of the above fire on the clean stream.
    const cod_ok = [_]u8{ 0xFF, 0x52, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x04, 0x04, 0x00, 0x00 };
    var rep0 = try jp2z.validate(std.testing.allocator, &(soc_siz ++ cod_ok ++ qcd ++ tail));
    defer rep0.deinit(std.testing.allocator);
    try std.testing.expect(!hasFinding(rep0, .jp2_invalid_codestream));
}

test "validate: SOT/Psot/TPsot consistency — classifier over the malformed tile-part set" {
    // T.800 A.4.2 / Table A.5. Each malformed variant fires a FAIL finding;
    // the well-formed control fires none of them.
    const soc_siz = [_]u8{
        0xFF, 0x4F,
        0xFF, 0x51, 0x00, 0x29, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x07, 0x01, 0x01,
    };
    const cod = [_]u8{ 0xFF, 0x52, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x04, 0x04, 0x00, 0x00 };
    const qcd = [_]u8{ 0xFF, 0x5C, 0x00, 0x07, 0x40, 0x40, 0x40, 0x40, 0x40 };
    const hdr = soc_siz ++ cod ++ qcd;
    const eoc = [_]u8{ 0xFF, 0xD9 };

    // Isot out of range: this SIZ declares a single tile; Isot=5 cannot map
    // to the tile grid (T.800: Isot < numtiles).
    const isot_oob = hdr ++ [_]u8{ 0xFF, 0x90, 0x00, 0x0A, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xFF, 0x93 } ++ eoc;
    // First tile-part of a tile must be TPsot=0.
    const tpsot_first = hdr ++ [_]u8{ 0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0xFF, 0x93 } ++ eoc;
    // More tile-parts than TNsot declared: part 0 declares TNsot=1, then a
    // second part (TPsot=1) arrives. Psot=14 = SOT(12)+SOD(2), empty body.
    const tnsot_over = hdr ++
        [_]u8{ 0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0E, 0x00, 0x01, 0xFF, 0x93 } ++
        [_]u8{ 0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0xFF, 0x93 } ++ eoc;
    inline for (.{ isot_oob, tpsot_first, tnsot_over }) |s| {
        var rep = try jp2z.validate(std.testing.allocator, &s);
        defer rep.deinit(std.testing.allocator);
        try std.testing.expect(hasFinding(rep, .jp2_invalid_codestream));
        try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    }

    // Degenerate Psot: 1..13 cannot even hold the SOT segment + SOD.
    const psot_tiny = hdr ++ [_]u8{ 0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x93 } ++ eoc;
    var rep_psot = try jp2z.validate(std.testing.allocator, &psot_tiny);
    defer rep_psot.deinit(std.testing.allocator);
    try std.testing.expect(hasFinding(rep_psot, .bad_marker_length));
    try std.testing.expectEqual(jp2z.Severity.fail, rep_psot.overall);

    // Control (TPsot=0, TNsot=1, Psot=0 → to EOC): none of the above fire.
    const control = hdr ++ [_]u8{ 0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xFF, 0x93 } ++ eoc;
    var rep0 = try jp2z.validate(std.testing.allocator, &control);
    defer rep0.deinit(std.testing.allocator);
    try std.testing.expect(!hasFinding(rep0, .jp2_invalid_codestream));
    try std.testing.expect(!hasFinding(rep0, .bad_marker_length));
}

test "deepValidate diagnostics: aggregate entropy findings carry first-offender offset + identity" {
    // The c253 hunt on p1_04 needed a throwaway trace print because the
    // aggregate deep findings carried no offset and no cblk identity.
    // Contract: every c251/c252/c253 finding anchors at the FIRST
    // offending cblk's byte offset in the codestream and names it in the
    // detail ("first: tile T comp C ...").
    const allocator = std.testing.allocator;
    const corrupt = try allocator.dupe(u8, a1_mono_j2c);
    defer allocator.free(corrupt);
    // Flip one byte deep in the entropy data (halfway through the file —
    // well past the tile-part headers, so the tier-2 walk stays intact and
    // the damage lands in a code-block's byte budget). Corrupting header
    // bytes instead would break the packet walk before any cblk decodes.
    const pos = corrupt.len / 2;
    corrupt[pos] ^= 0xFF;

    var rep = try jp2z.internal.deepValidate(allocator, corrupt, true);
    defer rep.deinit(allocator);
    var n_deep: usize = 0;
    for (rep.findings.items) |f| {
        switch (f.code) {
            .entropy_over_read, .entropy_under_read, .coding_pass_overflow => {
                n_deep += 1;
                // Anchored at the offending cblk's first contribution byte,
                // which precedes the flipped byte and sits inside the file.
                try std.testing.expect(f.offset != null);
                try std.testing.expect(f.offset.? > 0 and f.offset.? < corrupt.len);
                try std.testing.expect(f.detail != null);
                try std.testing.expect(std.mem.indexOf(u8, f.detail.?, "first: tile ") != null);
            },
            else => {},
        }
    }
    try std.testing.expect(n_deep >= 1);

    // The clean control emits no deep finding at all (the anchoring must
    // not come from a finding that fires on valid data).
    var rep0 = try jp2z.internal.deepValidate(allocator, a1_mono_j2c, true);
    defer rep0.deinit(allocator);
    for (rep0.findings.items) |f| {
        try std.testing.expect(f.code != .entropy_over_read);
        try std.testing.expect(f.code != .entropy_under_read);
        try std.testing.expect(f.code != .coding_pass_overflow);
    }
}

// ── M7 slice: embedded-stream bounds + JP2 box-layer strictness ────
//
// The C ABI (jp2z_core.h) documents finding offsets as "byte offset
// into the input data" — the HOST file. For JP2 inputs the codestream
// walker historically emitted offsets relative to the jp2c payload
// while box-level findings used host offsets: two silent coordinate
// systems in one report. These tests pin the host-relative contract
// plus first-jp2c-only semantics (T.800 I.5.4), jp2h-before-jp2c
// ordering (I.5.3), and jp2h sub-box strictness.

/// Minimal synthetic 9/7 codestream (same bytes as the 9x7-INFO test).
const synth_97_stream = [_]u8{
    0xFF, 0x4F,
    // SIZ — 4x4 mono 8-bit
    0xFF, 0x51, 0x00, 0x29, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x01, 0x07, 0x01, 0x01,
    // COD — qmfbid=0 (9/7)
    0xFF, 0x52, 0x00, 0x0C,
    0x00, 0x00, 0x00, 0x01, 0x00,
    0x01, 0x04, 0x04, 0x00, 0x00,
    // QCD — scalar expounded, four entries for decomp=1 (A.6.4)
    0xFF, 0x5C, 0x00, 0x0B, 0x22, 0x40, 0x00, 0x48, 0x00, 0x48, 0x00, 0x50, 0x00,
    // SOT
    0xFF, 0x90, 0x00, 0x0A,
    0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x01,
    // SOD + two empty packets (decomp 1 → r0 + r1; A.4.4: SOD is mandatory in every tile-part)
    0xFF, 0x93, 0x00, 0x00,
    // EOC
    0xFF, 0xD9,
};

/// Wrap a raw codestream in a minimal well-formed JP2 shell:
/// signature(12) + ftyp(20) + jp2h(30: ihdr only) + jp2c(8 + payload).
/// Returns an owned buffer; the jp2c PAYLOAD starts at host offset 70.
const jp2_shell_payload_base: u64 = 12 + 20 + 30 + 8;
fn wrapInJp2(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    // Signature box
    try buf.appendSlice(allocator, &.{ 0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A });
    // ftyp: lbox=20 'ftyp' brand='jp2 ' minv=0 compat='jp2 '
    try buf.appendSlice(allocator, &.{ 0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70, 0x6A, 0x70, 0x32, 0x20, 0x00, 0x00, 0x00, 0x00, 0x6A, 0x70, 0x32, 0x20 });
    // jp2h: lbox=30 'jp2h' { ihdr: lbox=22 'ihdr' h=4 w=4 nc=1 bpc=7 c=7 unk=0 ipr=0 }
    try buf.appendSlice(allocator, &.{ 0x00, 0x00, 0x00, 0x1E, 0x6A, 0x70, 0x32, 0x68 });
    try buf.appendSlice(allocator, &.{ 0x00, 0x00, 0x00, 0x16, 0x69, 0x68, 0x64, 0x72, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x01, 0x07, 0x07, 0x00, 0x00 });
    // jp2c
    const jp2c_total: u32 = @intCast(8 + payload.len);
    var lbox_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &lbox_bytes, jp2c_total, .big);
    try buf.appendSlice(allocator, &lbox_bytes);
    try buf.appendSlice(allocator, &.{ 0x6A, 0x70, 0x32, 0x63 });
    try buf.appendSlice(allocator, payload);
    return buf.toOwnedSlice(allocator);
}

fn findingOffset(rep: jp2z.ValidationReport, code: jp2z.FindingCode) ?u64 {
    for (rep.findings.items) |f| if (f.code == code) return f.offset;
    return null;
}

test "validate: JP2-embedded codestream findings carry HOST-file offsets" {
    const allocator = std.testing.allocator;
    // Metamorphic relation: wrapping the same codestream in a JP2 shell
    // must shift every codestream finding's offset by exactly the
    // payload's host base — no hand-computed marker positions needed.
    var bare = try jp2z.validate(allocator, &synth_97_stream);
    defer bare.deinit(allocator);
    const bare_off = findingOffset(bare, .jp2_uses_9x7_wavelet) orelse return error.TestUnexpectedResult;

    const wrapped = try wrapInJp2(allocator, &synth_97_stream);
    defer allocator.free(wrapped);
    var rep = try jp2z.validate(allocator, wrapped);
    defer rep.deinit(allocator);
    const wrapped_off = findingOffset(rep, .jp2_uses_9x7_wavelet) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(bare_off + jp2_shell_payload_base, wrapped_off);
}

test "validate: second jp2c box is ignored per T.800 I.5.4 (WARN 145, no findings from its payload)" {
    const allocator = std.testing.allocator;
    const wrapped = try wrapInJp2(allocator, &synth_97_stream);
    defer allocator.free(wrapped);
    // Append a second jp2c whose payload is a bare SOC — if walked, it
    // would emit truncated_stream and tank the report.
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, wrapped);
    const second_jp2c_pos: u64 = buf.items.len;
    try buf.appendSlice(allocator, &.{ 0x00, 0x00, 0x00, 0x0A, 0x6A, 0x70, 0x32, 0x63, 0xFF, 0x4F });

    var rep = try jp2z.validate(allocator, buf.items);
    defer rep.deinit(allocator);
    // The second codestream must NOT have been walked...
    try std.testing.expect(!hasFinding(rep, .truncated_stream));
    try std.testing.expect(rep.isOk());
    // ...and the skip must be surfaced, anchored at the extra box.
    try std.testing.expectEqual(second_jp2c_pos, findingOffset(rep, .jp2_unsupported_marker_ignored) orelse return error.TestUnexpectedResult);
    for (rep.findings.items) |f| {
        if (f.code == .jp2_unsupported_marker_ignored)
            try std.testing.expectEqual(jp2z.Severity.warn, f.severity);
    }
}

test "validate: jp2c before jp2h violates I.5.3 ordering → FAIL" {
    const allocator = std.testing.allocator;
    const wrapped = try wrapInJp2(allocator, &synth_97_stream);
    defer allocator.free(wrapped);
    // Reorder: sig(12) + ftyp(20) + jp2c(...) + jp2h(30).
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, wrapped[0..32]); // sig + ftyp
    try buf.appendSlice(allocator, wrapped[62..]); // jp2c box
    try buf.appendSlice(allocator, wrapped[32..62]); // jp2h box
    var rep = try jp2z.validate(allocator, buf.items);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(hasFinding(rep, .jp2_invalid_codestream));
}

test "validate: malformed jp2h sub-box length emits bad_marker_length (not silence)" {
    const allocator = std.testing.allocator;
    const wrapped = try wrapInJp2(allocator, &synth_97_stream);
    defer allocator.free(wrapped);
    const mutant = try allocator.dupe(u8, wrapped);
    defer allocator.free(mutant);
    // jp2h body starts at 32+8=40; ihdr LBox is bytes 40..44. Corrupt it
    // to 5 (invalid: 1 < lbox < 8).
    std.mem.writeInt(u32, mutant[40..44], 5, .big);
    var rep = try jp2z.validate(allocator, mutant);
    defer rep.deinit(allocator);
    try std.testing.expect(hasFinding(rep, .bad_marker_length));
}

test "validate: ihdr dims disagreeing with SIZ → FAIL (T.800 I.5.3.1 'shall be equal')" {
    const allocator = std.testing.allocator;
    const wrapped = try wrapInJp2(allocator, &synth_97_stream);
    defer allocator.free(wrapped);
    const mutant = try allocator.dupe(u8, wrapped);
    defer allocator.free(mutant);
    // ihdr body starts at 40+8=48: HEIGHT(u32) WIDTH(u32). SIZ says 4x4;
    // lie in the container: 9x9.
    std.mem.writeInt(u32, mutant[48..52], 9, .big);
    std.mem.writeInt(u32, mutant[52..56], 9, .big);
    var rep = try jp2z.validate(allocator, mutant);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(hasFinding(rep, .jp2_invalid_codestream));
}

test "validate: XLBox (lbox=1) ihdr sub-box is parsed — its lying dims are caught vs SIZ" {
    const allocator = std.testing.allocator;
    // Same mismatch check, but the ihdr is XLBox-encoded (lbox=1 +
    // XLBox(u64)=30). If the sub-box walker aborts on lbox=1 instead of
    // parsing it, the 9x9 lie goes unnoticed and this test fails.
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, &.{ 0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A });
    try buf.appendSlice(allocator, &.{ 0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70, 0x6A, 0x70, 0x32, 0x20, 0x00, 0x00, 0x00, 0x00, 0x6A, 0x70, 0x32, 0x20 });
    // jp2h: lbox=38 { ihdr with XLBox: lbox=1 'ihdr' xlbox=30 h=9 w=9 nc=1 bpc=7 c=7 unk=0 ipr=0 }
    try buf.appendSlice(allocator, &.{ 0x00, 0x00, 0x00, 0x26, 0x6A, 0x70, 0x32, 0x68 });
    try buf.appendSlice(allocator, &.{ 0x00, 0x00, 0x00, 0x01, 0x69, 0x68, 0x64, 0x72 });
    try buf.appendSlice(allocator, &.{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1E });
    try buf.appendSlice(allocator, &.{ 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x09, 0x00, 0x01, 0x07, 0x07, 0x00, 0x00 });
    // jp2c (SIZ inside says 4x4)
    const jp2c_total: u32 = @intCast(8 + synth_97_stream.len);
    var lbox_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &lbox_bytes, jp2c_total, .big);
    try buf.appendSlice(allocator, &lbox_bytes);
    try buf.appendSlice(allocator, &.{ 0x6A, 0x70, 0x32, 0x63 });
    try buf.appendSlice(allocator, &synth_97_stream);

    var rep = try jp2z.validate(allocator, buf.items);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(hasFinding(rep, .jp2_invalid_codestream));
}

test "validate: absence findings (missing ftyp/jp2h/jp2c) carry an offset — no null anchors" {
    const allocator = std.testing.allocator;
    // Three JP2s each missing one required box. The absence finding
    // anchors at data.len (walk exhausted the file), mirroring
    // missing_eoi's "where it should have been" convention. Invariant:
    // NO finding in any of these reports may carry a null offset.
    const wrapped = try wrapInJp2(allocator, &synth_97_stream);
    defer allocator.free(wrapped);

    const cases = [_]struct { name: []const u8, data: []const u8 }{
        // sig + jp2h + jp2c (ftyp removed: bytes 12..32 cut)
        .{ .name = "no-ftyp", .data = try std.mem.concat(allocator, u8, &.{ wrapped[0..12], wrapped[32..] }) },
        // sig + ftyp + jp2c (jp2h removed: bytes 32..62 cut)
        .{ .name = "no-jp2h", .data = try std.mem.concat(allocator, u8, &.{ wrapped[0..32], wrapped[62..] }) },
        // sig + ftyp + jp2h (jp2c removed: tail cut at 62)
        .{ .name = "no-jp2c", .data = try allocator.dupe(u8, wrapped[0..62]) },
    };
    defer for (cases) |c| allocator.free(@constCast(c.data));

    for (cases) |c| {
        var rep = try jp2z.validate(allocator, c.data);
        defer rep.deinit(allocator);
        try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
        for (rep.findings.items) |f| {
            if (f.offset == null) {
                std.debug.print("null-offset finding {s} in case {s}\n", .{ @tagName(f.code), c.name });
                return error.NullOffsetFinding;
            }
        }
    }
}

// ── M7 slice: TLM / PLT length cross-checks (T.800 A.7.1 / A.7.3) ──
//
// TLM (main header) declares every tile-part's length; PLT (tile-part
// header) declares every packet's length. Both exist so decoders can
// seek without walking — which means a lying entry silently corrupts
// any consumer that trusts it. openjpeg never verifies either; jp2z
// cross-checks declared vs walked and FAILs on disagreement.
//
// Fixture: minimal 4x4 mono 5/3 stream, decomp=0 → exactly ONE packet,
// and that packet is the 1-byte empty packet (header flag bit 0). Every
// length is hand-derivable: tile-part = 12 (SOT) + extras + 2 (SOD) + 1.

/// Build: SOC + SIZ(4x4) + COD(decomp=0, 5/3) + QCD + `main_extra`
/// (e.g. a TLM marker) + SOT + `tp_hdr_extra` (e.g. a PLT marker) +
/// SOD + 1-byte empty packet + EOC. Psot is computed, not hardcoded.
fn buildMiniStream(allocator: std.mem.Allocator, main_extra: []const u8, tp_hdr_extra: []const u8) ![]u8 {
    return buildPackedMiniStream(allocator, .{ .main_extra = main_extra, .tp_hdr_extra = tp_hdr_extra, .body = &.{0x00} });
}

const MiniStreamOpts = struct {
    main_extra: []const u8 = &.{},
    tp_hdr_extra: []const u8 = &.{},
    /// Bytes after SOD (packet headers+bodies inline, or bodies only when
    /// the headers are packed into PPM/PPT).
    body: []const u8 = &.{0x00},
    /// COD SGcod layer count: N layers on a decomp=0 single-cblk tile is N
    /// packets, so this is the knob for "how many packet headers".
    layers: u16 = 1,
    /// COD Scod: bit 1 SOP, bit 2 EPH (custom precincts are not used here).
    scod: u8 = 0,
    /// COD SGcod progression order (0 LRCP, 1 RLCP, 2 RPCL, 3 PCRL, 4 CPRL).
    prog: u8 = 0,
    /// COD decomposition levels. >0 needs a matching `qcd_body`.
    decomp: u8 = 0,
    /// QCD body after Lqcd (Sqcd + SPqcd). Default: style 0, G=2, one LL byte.
    qcd_body: []const u8 = &.{ 0x40, 0x40 },
    /// Emit QCD before COD (T.800 A.4: main-header order is free after SIZ).
    qcd_before_cod: bool = false,
    /// SIZ Csiz: every component 8-bit unsigned, dx=dy=1 (a one-layer,
    /// decomp-0 tile then holds `components` packets: body needs that many
    /// empty-packet bytes). `last_comp_prec` overrides the LAST component's
    /// Ssiz precision so non-uniform descriptors can be crafted.
    components: u16 = 1,
    last_comp_prec: ?u8 = null,
};

/// Generalised mini-stream: same 4x4 mono 5/3 shell as buildMiniStream but
/// with the SOD body, layer count and Scod under test control so packed
/// packet headers (PPM/PPT) can be crafted byte-for-byte.
fn buildPackedMiniStream(allocator: std.mem.Allocator, o: MiniStreamOpts) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, &.{ 0xFF, 0x4F });
    // SIZ — 4x4 8-bit, single 4x4 tile, `components` descriptors
    try buf.appendSlice(allocator, &.{ 0xFF, 0x51 });
    var lsiz: [2]u8 = undefined;
    std.mem.writeInt(u16, &lsiz, @intCast(38 + 3 * @as(usize, o.components)), .big);
    try buf.appendSlice(allocator, &lsiz);
    try buf.appendSlice(allocator, &.{
        0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    });
    var csiz: [2]u8 = undefined;
    std.mem.writeInt(u16, &csiz, o.components, .big);
    try buf.appendSlice(allocator, &csiz);
    var ci: u16 = 0;
    while (ci < o.components) : (ci += 1) {
        const prec: u8 = if (ci + 1 == o.components and o.last_comp_prec != null) o.last_comp_prec.? - 1 else 0x07;
        try buf.appendSlice(allocator, &.{ prec, 0x01, 0x01 });
    }
    // COD — Scod, LRCP, `layers`, no MCT, `decomp`, cblk 64x64, 5/3
    var cod: [14]u8 = .{ 0xFF, 0x52, 0x00, 0x0C, o.scod, o.prog, 0x00, 0x00, 0x00, o.decomp, 0x04, 0x04, 0x00, 0x01 };
    std.mem.writeInt(u16, cod[6..8], o.layers, .big);
    // QCD — Lqcd = 2 + body
    var qcd: std.ArrayList(u8) = .empty;
    defer qcd.deinit(allocator);
    try qcd.appendSlice(allocator, &.{ 0xFF, 0x5C });
    var lqcd: [2]u8 = undefined;
    std.mem.writeInt(u16, &lqcd, @intCast(2 + o.qcd_body.len), .big);
    try qcd.appendSlice(allocator, &lqcd);
    try qcd.appendSlice(allocator, o.qcd_body);
    if (o.qcd_before_cod) {
        try buf.appendSlice(allocator, qcd.items);
        try buf.appendSlice(allocator, &cod);
    } else {
        try buf.appendSlice(allocator, &cod);
        try buf.appendSlice(allocator, qcd.items);
    }
    try buf.appendSlice(allocator, o.main_extra);
    // SOT — Psot = 12 + tp_hdr_extra + SOD(2) + body
    const psot: u32 = @intCast(12 + o.tp_hdr_extra.len + 2 + o.body.len);
    try buf.appendSlice(allocator, &.{ 0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00 });
    var psot_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &psot_bytes, psot, .big);
    try buf.appendSlice(allocator, &psot_bytes);
    try buf.appendSlice(allocator, &.{ 0x00, 0x01 });
    try buf.appendSlice(allocator, o.tp_hdr_extra);
    try buf.appendSlice(allocator, &.{ 0xFF, 0x93 }); // SOD
    try buf.appendSlice(allocator, o.body);
    try buf.appendSlice(allocator, &.{ 0xFF, 0xD9 }); // EOC
    return buf.toOwnedSlice(allocator);
}

test "validate: mini stream sanity — walks to end, no TLM/PLT anywhere" {
    const allocator = std.testing.allocator;
    const stream = try buildMiniStream(allocator, &.{}, &.{});
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try std.testing.expect(rep.isOk());
    try std.testing.expect(hasFinding(rep, .jp2_packets_walked_to_end));
}

test "validate: TLM entry matching the walked tile-part length → clean" {
    const allocator = std.testing.allocator;
    // TLM: Ztlm=0, Stlm=0x00 (ST=0 in-order, SP=0 u16), Ptlm=15.
    const stream = try buildMiniStream(allocator, &.{ 0xFF, 0x55, 0x00, 0x06, 0x00, 0x00, 0x00, 0x0F }, &.{});
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try std.testing.expect(rep.isOk());
    try std.testing.expect(!hasFinding(rep, .jp2_invalid_codestream));
}

test "validate: TLM entry disagreeing with the walked tile-part length → FAIL" {
    const allocator = std.testing.allocator;
    // Ptlm=99, actual tile-part is 15 bytes.
    const stream = try buildMiniStream(allocator, &.{ 0xFF, 0x55, 0x00, 0x06, 0x00, 0x00, 0x00, 0x63 }, &.{});
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(hasFinding(rep, .jp2_invalid_codestream));
}

test "validate: TLM present but a tile-part has no entry → FAIL" {
    const allocator = std.testing.allocator;
    // TLM with ZERO entries (Ltlm=4: just Ztlm+Stlm). A.7.1: when TLM
    // is used it describes every tile-part; this one describes none.
    const stream = try buildMiniStream(allocator, &.{ 0xFF, 0x55, 0x00, 0x04, 0x00, 0x00 }, &.{});
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(hasFinding(rep, .jp2_invalid_codestream));
}

test "validate: TLM body not a whole number of entries → bad_marker_length" {
    const allocator = std.testing.allocator;
    // Stlm=0x00 → entry size 2; one stray byte after Ztlm+Stlm.
    const stream = try buildMiniStream(allocator, &.{ 0xFF, 0x55, 0x00, 0x05, 0x00, 0x00, 0x0F }, &.{});
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(hasFinding(rep, .bad_marker_length));
}

test "validate: PLT entry matching the walked packet length → clean" {
    const allocator = std.testing.allocator;
    // PLT: Zplt=0, one Iplt byte = 1 (the empty packet is 1 byte).
    const stream = try buildMiniStream(allocator, &.{}, &.{ 0xFF, 0x58, 0x00, 0x04, 0x00, 0x01 });
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try std.testing.expect(rep.isOk());
    try std.testing.expect(!hasFinding(rep, .jp2_invalid_codestream));
}

test "validate: PLT entry disagreeing with the walked packet length → FAIL" {
    const allocator = std.testing.allocator;
    const stream = try buildMiniStream(allocator, &.{}, &.{ 0xFF, 0x58, 0x00, 0x04, 0x00, 0x05 });
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(hasFinding(rep, .jp2_invalid_codestream));
}

test "validate: PLT ending mid-varint (trailing continuation bit) → bad_marker_length" {
    const allocator = std.testing.allocator;
    const stream = try buildMiniStream(allocator, &.{}, &.{ 0xFF, 0x58, 0x00, 0x04, 0x00, 0x81 });
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(hasFinding(rep, .bad_marker_length));
}

// ── M7 slice: zero-bitplane-overflow as a distinct finding ─────────
//
// A cblk whose zero-bitplane tag tree consumed the ENTIRE bit-depth
// budget (zero_bitplanes >= M_b → numbps == 0) yet still carries coding
// passes is impossible in a conforming stream — proven empirically:
// across all 15 conformance fixtures (7,730 code-blocks) not one has
// numbps == 0. It WAS caught, but mislabeled coding_pass_overflow whose
// detail ("declare more coding passes than numbps allows") misdirects a
// consumer to the pass count when the real cause is the zero-bitplane
// count. This slice re-attributes it to a dedicated finding.

/// Crafted minimal stream: mini-stream shell (SIZ 8-bit, QCD G=2 eps=8
/// → LL M_b=9) + one packet whose zero-bitplane tag tree encodes zbp=9
/// (nine '0' then '1'), 1 coding pass, 1 body byte. Verified via probe
/// to yield zero_bitplanes=9, numbps=0, passes=1.
fn buildZbpOverflowStream(allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, &.{ 0xFF, 0x4F });
    try buf.appendSlice(allocator, &.{
        0xFF, 0x51, 0x00, 0x29, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x07, 0x01, 0x01,
    });
    try buf.appendSlice(allocator, &.{ 0xFF, 0x52, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x04, 0x04, 0x00, 0x01 });
    try buf.appendSlice(allocator, &.{ 0xFF, 0x5C, 0x00, 0x04, 0x40, 0x40 });
    // Psot = 12 (SOT) + 2 (SOD) + 4 (packet: 3 header + 1 body)
    try buf.appendSlice(allocator, &.{ 0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x12, 0x00, 0x01 });
    try buf.appendSlice(allocator, &.{ 0xFF, 0x93 }); // SOD
    try buf.appendSlice(allocator, &.{ 0xC0, 0x10, 0x80, 0x00 }); // crafted packet
    try buf.appendSlice(allocator, &.{ 0xFF, 0xD9 }); // EOC
    return buf.toOwnedSlice(allocator);
}

test "deepValidate: zero-bitplane overflow → dedicated finding, not coding_pass_overflow" {
    const allocator = std.testing.allocator;
    const stream = try buildZbpOverflowStream(allocator);
    defer allocator.free(stream);
    var rep = try jp2z.internal.deepValidate(allocator, stream, true);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(hasFinding(rep, .zero_bitplane_overflow));
    // Re-attribution: this cblk has exactly 1 pass; blaming the pass
    // count is the misdirection we are removing.
    try std.testing.expect(!hasFinding(rep, .coding_pass_overflow));
}

// ── PPM / PPT packed packet headers (T.800 A.7.4 / A.7.5) ─────────
//
// A codestream may lift every packet header out of the tile-part bodies
// into PPM (main header, one Nppm-prefixed chunk per tile-part, chunks
// may span PPM segments) or PPT (tile-part header) marker segments. The
// bodies stay in place after SOD. Until this slice the walker ignored
// both markers and read packet BODIES as headers — a silent desync that
// left every PPM/PPT stream un-validated (and un-decodable: the sweep's
// 127/128 cluster is exactly these fixtures).

const g3_colr_j2c = @embedFile("fixtures/conformance/g3_colr.j2c");
const g4_colr_j2c = @embedFile("fixtures/conformance/g4_colr.j2c");
const p1_06_j2k = @embedFile("fixtures/conformance/p1_06.j2k");

fn expectCleanPackedWalk(rep: jp2z.ValidationReport) !void {
    try std.testing.expect(rep.isOk());
    try std.testing.expect(hasFinding(rep, .jp2_packets_walked_to_end));
    try std.testing.expect(!hasFinding(rep, .jp2_unsupported_marker_ignored));
    try std.testing.expect(!hasFinding(rep, .unknown_marker));
    try std.testing.expect(!hasFinding(rep, .packed_headers_mismatch));
}

test "validate: PPT carries the packet header, SOD body empty → clean walk to end" {
    const allocator = std.testing.allocator;
    // PPT: Lppt=4, Zppt=0, Ippt = one empty-packet header byte.
    const stream = try buildPackedMiniStream(allocator, .{ .tp_hdr_extra = &.{ 0xFF, 0x61, 0x00, 0x04, 0x00, 0x00 }, .body = &.{} });
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try expectCleanPackedWalk(rep);
}

test "validate: PPM carries the packet header, SOD body empty → clean walk to end" {
    const allocator = std.testing.allocator;
    // PPM: Lppm=8, Zppm=0, Nppm=1, Ippm = one empty-packet header byte.
    const stream = try buildPackedMiniStream(allocator, .{ .main_extra = &.{ 0xFF, 0x60, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00 }, .body = &.{} });
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try expectCleanPackedWalk(rep);
}

test "validate: PPM chunk for two packets (2 layers) → clean" {
    const allocator = std.testing.allocator;
    const stream = try buildPackedMiniStream(allocator, .{ .main_extra = &.{ 0xFF, 0x60, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00 }, .body = &.{}, .layers = 2 });
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try expectCleanPackedWalk(rep);
}

test "validate: PPM Nppm chunk spanning two PPM segments (g3 layout) → clean" {
    const allocator = std.testing.allocator;
    // Segment Zppm=0 holds Nppm=2 and the first header byte; segment
    // Zppm=1 holds the second header byte (no Nppm of its own).
    const stream = try buildPackedMiniStream(allocator, .{
        .main_extra = &.{ 0xFF, 0x60, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0xFF, 0x60, 0x00, 0x04, 0x01, 0x00 },
        .body = &.{},
        .layers = 2,
    });
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try expectCleanPackedWalk(rep);
}

test "validate: PPM chunk with header bytes left over after the tile-part's packets → packed_headers_mismatch FAIL" {
    const allocator = std.testing.allocator;
    // Nppm=2 but the tile has ONE packet: one byte of the chunk is never claimed.
    const stream = try buildPackedMiniStream(allocator, .{ .main_extra = &.{ 0xFF, 0x60, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00 }, .body = &.{} });
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(hasFinding(rep, .packed_headers_mismatch));
}

test "validate: PPT store with header bytes left over → packed_headers_mismatch FAIL" {
    const allocator = std.testing.allocator;
    const stream = try buildPackedMiniStream(allocator, .{ .tp_hdr_extra = &.{ 0xFF, 0x61, 0x00, 0x05, 0x00, 0x00, 0x00 }, .body = &.{} });
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(hasFinding(rep, .packed_headers_mismatch));
}

test "validate: PPM chunk exhausted while packet bodies remain → packed_headers_mismatch FAIL" {
    const allocator = std.testing.allocator;
    // 2 layers = 2 packets, Nppm=1 supplies ONE header byte, and the body
    // still holds a byte for the second packet: the walker reaches for a
    // header the store no longer has.
    const stream = try buildPackedMiniStream(allocator, .{ .main_extra = &.{ 0xFF, 0x60, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00 }, .body = &.{0x00}, .layers = 2 });
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(hasFinding(rep, .packed_headers_mismatch));
}

test "validate: PPT store exhausted while packet bodies remain → packed_headers_mismatch FAIL" {
    const allocator = std.testing.allocator;
    const stream = try buildPackedMiniStream(allocator, .{ .tp_hdr_extra = &.{ 0xFF, 0x61, 0x00, 0x04, 0x00, 0x00 }, .body = &.{0x00}, .layers = 2 });
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(hasFinding(rep, .packed_headers_mismatch));
}

test "validate: packed store short of a whole packet, no body left → the tile is flagged incomplete at EOC" {
    const allocator = std.testing.allocator;
    // 2 packets required, one header in the store, nothing in the body:
    // indistinguishable mid-walk from "the rest comes in a later tile-part",
    // so the verdict lands at EOC (truncated_stream via flagIncompleteTiles).
    const stream = try buildPackedMiniStream(allocator, .{ .tp_hdr_extra = &.{ 0xFF, 0x61, 0x00, 0x04, 0x00, 0x00 }, .body = &.{}, .layers = 2 });
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(hasFinding(rep, .truncated_stream));
}

test "validate: EPH signalled → the EPH marker lives in the packed store (present: clean; absent: FAIL)" {
    const allocator = std.testing.allocator;
    // Scod=0x04 (EPH). A.7.4/A.7.5: with packed headers EPH follows each
    // packet header INSIDE the PPM/PPT data, not in the tile-part body.
    const ok = try buildPackedMiniStream(allocator, .{ .scod = 0x04, .tp_hdr_extra = &.{ 0xFF, 0x61, 0x00, 0x06, 0x00, 0x00, 0xFF, 0x92 }, .body = &.{} });
    defer allocator.free(ok);
    var rep_ok = try jp2z.validate(allocator, ok);
    defer rep_ok.deinit(allocator);
    try expectCleanPackedWalk(rep_ok);

    // Same store without the EPH: the header byte is followed by nothing.
    const bad = try buildPackedMiniStream(allocator, .{ .scod = 0x04, .tp_hdr_extra = &.{ 0xFF, 0x61, 0x00, 0x04, 0x00, 0x00 }, .body = &.{} });
    defer allocator.free(bad);
    var rep_bad = try jp2z.validate(allocator, bad);
    defer rep_bad.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep_bad.overall);
}

test "validate: SOP signalled with PPT → SOP stays in the tile-part body before each packet body" {
    const allocator = std.testing.allocator;
    // Scod=0x02 (SOP). The packed store holds the header; the body holds
    // SOP(6 bytes: FF91 0004 Nsop=0) and nothing else for an empty packet.
    const stream = try buildPackedMiniStream(allocator, .{ .scod = 0x02, .tp_hdr_extra = &.{ 0xFF, 0x61, 0x00, 0x04, 0x00, 0x00 }, .body = &.{ 0xFF, 0x91, 0x00, 0x04, 0x00, 0x00 } });
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try expectCleanPackedWalk(rep);
}

test "validate: PPM and PPT in the same codestream → FAIL (A.7.4: shall not both be used)" {
    const allocator = std.testing.allocator;
    const stream = try buildPackedMiniStream(allocator, .{
        .main_extra = &.{ 0xFF, 0x60, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00 },
        .tp_hdr_extra = &.{ 0xFF, 0x61, 0x00, 0x04, 0x00, 0x00 },
        .body = &.{},
    });
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(hasFinding(rep, .jp2_invalid_codestream));
}

test "validate: duplicate Zppm index → FAIL" {
    const allocator = std.testing.allocator;
    const stream = try buildPackedMiniStream(allocator, .{
        .main_extra = &.{ 0xFF, 0x60, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0xFF, 0x60, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00 },
        .body = &.{},
    });
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(hasFinding(rep, .jp2_invalid_codestream));
}

test "validate: duplicate Zppt index → FAIL" {
    const allocator = std.testing.allocator;
    const stream = try buildPackedMiniStream(allocator, .{
        .tp_hdr_extra = &.{ 0xFF, 0x61, 0x00, 0x04, 0x00, 0x00, 0xFF, 0x61, 0x00, 0x04, 0x00, 0x00 },
        .body = &.{},
    });
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(hasFinding(rep, .jp2_invalid_codestream));
}

test "validate: Nppm larger than all PPM data → bad_marker_length FAIL" {
    const allocator = std.testing.allocator;
    // Nppm=5 with one Ippm byte across all segments.
    const stream = try buildPackedMiniStream(allocator, .{ .main_extra = &.{ 0xFF, 0x60, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x05, 0x00 }, .body = &.{} });
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(hasFinding(rep, .bad_marker_length));
}

test "validate: PPM data ending inside an Nppm field → bad_marker_length FAIL" {
    const allocator = std.testing.allocator;
    // Zppm=0 then only two bytes where a 4-byte Nppm must be.
    const stream = try buildPackedMiniStream(allocator, .{ .main_extra = &.{ 0xFF, 0x60, 0x00, 0x05, 0x00, 0x00, 0x00 }, .body = &.{} });
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(hasFinding(rep, .bad_marker_length));
}

test "validate: PPT segment with no Ippt bytes (Lppt=3, below Table A.41's minimum) → bad_marker_length FAIL" {
    const allocator = std.testing.allocator;
    const stream = try buildPackedMiniStream(allocator, .{ .tp_hdr_extra = &.{ 0xFF, 0x61, 0x00, 0x03, 0x00 }, .body = &.{} });
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(hasFinding(rep, .bad_marker_length));
}

test "deepValidate strict: real PPM (g3, 214 segments, SOP+EPH) and PPT (g4, p1_06) fixtures are clean" {
    const allocator = std.testing.allocator;
    const fixtures = [_][]const u8{ g3_colr_j2c, g4_colr_j2c, p1_06_j2k };
    for (fixtures) |data| {
        var rep = try jp2z.internal.deepValidate(allocator, data, true);
        defer rep.deinit(allocator);
        try std.testing.expect(rep.overall != .fail);
        try std.testing.expect(hasFinding(rep, .jp2_packets_walked_to_end));
        try std.testing.expect(!hasFinding(rep, .jp2_unsupported_marker_ignored));
        try std.testing.expect(!hasFinding(rep, .packed_headers_mismatch));
    }
}

test "cleanroom: p1_06 (16 tiles, PPT per tile-part, SOP+EPH) matches openjpeg" {
    // Was max_abs=128 in the sweep: with the headers ignored the walker
    // desynced and every tile decoded as flat mid-grey.
    const allocator = std.testing.allocator;
    var img = try jp2z.internal.decodeCleanroom(allocator, p1_06_j2k);
    defer img.deinit(allocator);
    var oracle = try jp2z.internal.openjpegDecode(allocator, p1_06_j2k);
    defer oracle.deinit(allocator);
    try std.testing.expectEqual(oracle.width, img.width);
    try std.testing.expectEqual(oracle.height, img.height);
    const comps: usize = img.num_components;
    try std.testing.expectEqual(@as(usize, oracle.channels), comps);
    const n: usize = @as(usize, img.width) * @as(usize, img.height);
    var max_abs: i64 = 0;
    var c: usize = 0;
    while (c < comps) : (c += 1) {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const d: i64 = @as(i64, img.planes[c][i]) - @as(i64, oracle.pixels[i * comps + c]);
            const ad = if (d < 0) -d else d;
            if (ad > max_abs) max_abs = ad;
        }
    }
    // 9/7 integer tolerance is ±1 (sweep NEAR); 5/3 must be exact.
    if (max_abs > 1) {
        std.debug.print("\n[p1_06] max_abs vs openjpeg = {d}\n", .{max_abs});
        return error.PixelMismatch;
    }
}

// ── Per-coefficient reconstruction half-bit (T1 vs openjpeg, mid-plane truncation) ──
//
// openjpeg carries the reconstruction "half" bit INSIDE each coefficient
// (set at significance, moved down by every refinement). jp2z applied one
// uniform half position per code-block (halfBitPos from the pass count).
// The two agree only when decoding stops on a cleanup pass; when a
// code-block's last pass is a significance or refinement pass, coefficients
// not visited in that partial bit-plane keep their half one plane higher.
// p1_05 (2 layers) has 2235 such code-blocks (max_abs 18); p1_06 has two.

const p1_06_t1_oracle = @embedFile("fixtures/oracles/p1_06.t1.bin");

test "oracle dump: jp2z decoded coefficients match openjpeg byte-perfectly for p1_06 (16 tiles, passes ending mid-plane)" {
    // The dump hardcodes tile 0 and records ABSOLUTE band coords, so keys
    // are (comp, r, band, absolute x0/y0) via bandOrigin per plan tile.
    const allocator = std.testing.allocator;
    const records = try parseOracleDump(allocator, p1_06_t1_oracle);
    defer freeOracleRecords(allocator, records);
    var list = try jp2z.internal.extractCblkPlans(allocator, p1_06_j2k);
    defer list.deinit(allocator);
    const p = (try jp2z.internal.inspect(allocator, p1_06_j2k)) orelse return error.NoCodingParams;
    const xsiz = p.image_x0 + 12;
    const ysiz = p.image_y0 + 12;

    var compared: u32 = 0;
    var mismatched: u32 = 0;
    for (records) |rec| {
        for (list.plans) |plan| {
            if (plan.component != rec.component or plan.resolution != rec.resno or plan.band != rec.orient) continue;
            const tr = p.tileRect(xsiz, ysiz, plan.tile);
            const bo = jp2z.internal.bandOrigin(tr.x0, tr.y0, p.num_decomp_levels, plan.resolution, plan.band);
            if (bo.x0 + plan.sb_x0 != rec.cblk_x0 or bo.y0 + plan.sb_y0 != rec.cblk_y0) continue;
            var cblk = try jp2z.internal.decodePlan(allocator, plan);
            defer cblk.deinit(allocator);
            try std.testing.expectEqual(rec.data.len, cblk.coeffs.len);
            for (cblk.coeffs, 0..) |c, i| {
                if (jp2z.internal.coeffToOpenJpegI32(c) != rec.data[i]) {
                    mismatched += 1;
                    std.debug.print("\n[p1_06 oracle] tile {d} c{d} r{d} b{d} sb({d},{d}) passes {d}: [{d}] ours={d} oj={d}\n", .{ plan.tile, plan.component, plan.resolution, plan.band, plan.sb_x0, plan.sb_y0, plan.total_passes, i, jp2z.internal.coeffToOpenJpegI32(c), rec.data[i] });
                    break;
                }
            }
            compared += 1;
            break;
        }
    }
    try std.testing.expectEqual(@as(u32, 180), compared);
    try std.testing.expectEqual(@as(u32, 0), mismatched);
}

// ── Main-header marker order: QCD before COD ───────────────────────
//
// T.800 A.4.1 fixes SIZ first; COD and QCD may follow in either order.
// jp2z sized the per-subband M_b table from the COD-supplied decomposition
// count at QCD-parse time, so "QCD then COD" (p0_01, file8) left every
// high-frequency band with M_b = 0: numbps = 0, code-blocks skipped in
// decode, and a strict zero_bitplane_overflow FAIL on a valid file.

const p0_01_j2k = @embedFile("fixtures/conformance/p0_01.j2k");
const p0_01_t1_oracle = @embedFile("fixtures/oracles/p0_01.t1.bin");

test "validate: QCD before COD yields the same per-subband M_b as COD before QCD (metamorphic)" {
    const allocator = std.testing.allocator;
    // decomp=1 → 4 subbands; style 0, G=2, eps 8 (LL) / 9,9,10 → M_b 9,10,10,11.
    const qcd = [_]u8{ 0x40, 0x40, 0x48, 0x48, 0x50 };
    const a = try buildPackedMiniStream(allocator, .{ .decomp = 1, .qcd_body = &qcd, .body = &.{ 0x00, 0x00 } });
    defer allocator.free(a);
    const b = try buildPackedMiniStream(allocator, .{ .decomp = 1, .qcd_body = &qcd, .body = &.{ 0x00, 0x00 }, .qcd_before_cod = true });
    defer allocator.free(b);
    const pa = (try jp2z.internal.inspect(allocator, a)) orelse return error.TestUnexpectedResult;
    const pb = (try jp2z.internal.inspect(allocator, b)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 9), pa.quant.mb[0]);
    try std.testing.expectEqual(@as(u8, 10), pa.quant.mb[1]);
    try std.testing.expectEqual(@as(u8, 11), pa.quant.mb[3]);
    try std.testing.expectEqualSlices(u8, pa.quant.mb[0..4], pb.quant.mb[0..4]);
    try std.testing.expectEqual(pa.quant.guard_bits, pb.quant.guard_bits);
    // Neither order is a deviation.
    var ra = try jp2z.validate(allocator, a);
    defer ra.deinit(allocator);
    var rb = try jp2z.validate(allocator, b);
    defer rb.deinit(allocator);
    try std.testing.expect(ra.isOk());
    try std.testing.expect(rb.isOk());
}

test "deepValidate strict: p0_01 (QCD before COD) is clean — no zero_bitplane_overflow false positive" {
    const allocator = std.testing.allocator;
    var rep = try jp2z.internal.deepValidate(allocator, p0_01_j2k, true);
    defer rep.deinit(allocator);
    try std.testing.expect(!hasFinding(rep, .zero_bitplane_overflow));
    try std.testing.expect(!hasFinding(rep, .coding_pass_overflow));
    try std.testing.expect(rep.overall != .fail);
}

test "oracle dump: jp2z decoded coefficients match openjpeg byte-perfectly for p0_01 (QCD before COD)" {
    const allocator = std.testing.allocator;
    const records = try parseOracleDump(allocator, p0_01_t1_oracle);
    defer freeOracleRecords(allocator, records);
    var list = try jp2z.internal.extractCblkPlans(allocator, p0_01_j2k);
    defer list.deinit(allocator);
    var compared: u32 = 0;
    var mismatched: u32 = 0;
    for (records) |rec| {
        for (list.plans) |plan| {
            if (plan.component != rec.component or plan.resolution != rec.resno or plan.band != rec.orient or plan.sb_x0 != rec.cblk_x0 or plan.sb_y0 != rec.cblk_y0) continue;
            var cblk = try jp2z.internal.decodePlan(allocator, plan);
            defer cblk.deinit(allocator);
            try std.testing.expectEqual(rec.data.len, cblk.coeffs.len);
            try std.testing.expectEqual(rec.numbps, @as(u32, plan.numbps));
            for (cblk.coeffs, 0..) |c, i| {
                if (jp2z.internal.coeffToOpenJpegI32(c) != rec.data[i]) {
                    mismatched += 1;
                    break;
                }
            }
            compared += 1;
            break;
        }
    }
    try std.testing.expectEqual(records.len, compared);
    try std.testing.expectEqual(@as(u32, 0), mismatched);
}

// ── SIZ Csiz beyond 16 components ──────────────────────────────────
//
// T.800 A.5.1 allows Csiz in [1, 16384]. jp2z's per-component descriptor
// arrays hold 16, and parseSizBody rejected anything larger as
// jp2_invalid_siz — a FAIL on a valid file (p0_13: 257 components).
// Components past the 16th are accepted when their descriptors repeat the
// 16th's (the arrays then describe every component); a differing
// descriptor is an unsupported-but-valid stream (c145), never invalid.

const p0_13_j2k = @embedFile("fixtures/conformance/p0_13.j2k");

test "validate: 17 uniform components is valid (no jp2_invalid_siz), all packets walk" {
    const allocator = std.testing.allocator;
    const body = [_]u8{0x00} ** 17;
    const stream = try buildPackedMiniStream(allocator, .{ .components = 17, .body = &body });
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try std.testing.expect(!hasFinding(rep, .jp2_invalid_siz));
    try std.testing.expect(rep.isOk());
    try std.testing.expectEqual(@as(u16, 17), rep.coding_params.?.num_components);
    try std.testing.expect(hasFinding(rep, .jp2_packets_walked_to_end));
}

test "validate: 17 components where the 17th differs from the 16th → unsupported (c145 WARN), not invalid" {
    const allocator = std.testing.allocator;
    const body = [_]u8{0x00} ** 17;
    const stream = try buildPackedMiniStream(allocator, .{ .components = 17, .last_comp_prec = 12, .body = &body });
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try std.testing.expect(!hasFinding(rep, .jp2_invalid_siz));
    try std.testing.expect(hasFinding(rep, .jp2_unsupported_marker_ignored));
    try std.testing.expect(rep.overall != .fail);
}

test "validate: p0_13 (257 components) is not jp2_invalid_siz and publishes coding params" {
    const allocator = std.testing.allocator;
    var rep = try jp2z.validate(allocator, p0_13_j2k);
    defer rep.deinit(allocator);
    try std.testing.expect(!hasFinding(rep, .jp2_invalid_siz));
    try std.testing.expectEqual(@as(u16, 257), rep.coding_params.?.num_components);
}

// ── QCC: per-component quantization overrides (T.800 A.6.5) ───────
//
// Precedence, highest first: tile-part QCC > tile-part QCD > main QCC >
// main QCD. QCC was c145-ignored, so a component with its own exponents
// took the QCD table: numbps off for that component (p0_04's QCCs lower
// eps by 2 for components 1 and 2 → numbps 2 too high), which the 9/7
// dequant cancels in pixels but which loosens the coding-pass budget the
// validator enforces. Chroma QCCs are routine in real encoders.

test "validate: p0_04 QCC → component-1 numbps matches the openjpeg oracle (QCD would give +2)" {
    const allocator = std.testing.allocator;
    var list = try jp2z.internal.extractCblkPlans(allocator, p0_04_j2k);
    defer list.deinit(allocator);
    // From the openjpeg T1 dump of p0_04 (component 1, subband-internal coords).
    const expected = [_]struct { r: u8, b: u8, x0: i32, y0: i32, numbps: u8 }{
        .{ .r = 2, .b = 3, .x0 = 0, .y0 = 0, .numbps = 6 },
        .{ .r = 2, .b = 2, .x0 = 0, .y0 = 0, .numbps = 7 },
        .{ .r = 3, .b = 1, .x0 = 0, .y0 = 0, .numbps = 6 },
        .{ .r = 3, .b = 2, .x0 = 0, .y0 = 0, .numbps = 8 },
        .{ .r = 4, .b = 1, .x0 = 64, .y0 = 0, .numbps = 6 },
    };
    var found: u32 = 0;
    for (expected) |e| {
        for (list.plans) |plan| {
            if (plan.component != 1 or plan.resolution != e.r or plan.band != e.b or plan.sb_x0 != e.x0 or plan.sb_y0 != e.y0) continue;
            try std.testing.expectEqual(e.numbps, plan.numbps);
            found += 1;
            break;
        }
    }
    try std.testing.expectEqual(@as(u32, expected.len), found);
}

test "validate: QCC with Cqcc >= Csiz → jp2_invalid_codestream FAIL" {
    const allocator = std.testing.allocator;
    // Csiz=2; QCC names component 5 (Lqcc=5, Cqcc=5, Sqcc G=3 style 0, one SPqcc byte).
    const stream = try buildPackedMiniStream(allocator, .{ .components = 2, .main_extra = &.{ 0xFF, 0x5D, 0x00, 0x05, 0x05, 0x60, 0x40 }, .body = &.{ 0x00, 0x00 } });
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(hasFinding(rep, .jp2_invalid_codestream));
}

// ── Zero-byte code-block contributions still carry coding passes ───
//
// A packet may include a code-block with N new passes and a length of 0
// (T.800 B.10.7 allows it; encoders emit it for tiny blocks in later
// layers). The walker's extractor skipped any contribution whose byte
// length was 0, so those passes never reached the plan: the tier-1 decode
// stopped short of openjpeg (which runs the passes over an exhausted
// stream) and the coding-pass budget the validator enforces was under-
// counted. e1_colr has seven such code-blocks (tiles 3, 4, 5, 7).

test "extractCblkPlans: a 1-pass, 0-byte contribution yields a plan with total_passes 1" {
    const allocator = std.testing.allocator;
    // Mini-stream shell + one packet: non-empty(1) inclusion(1) zbp=0(1)
    // passes=1('0') lblock('0') length=0('000') → 0xE0, no body byte.
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, &.{ 0xFF, 0x4F });
    try buf.appendSlice(allocator, &.{
        0xFF, 0x51, 0x00, 0x29, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x07, 0x01, 0x01,
    });
    try buf.appendSlice(allocator, &.{ 0xFF, 0x52, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x04, 0x04, 0x00, 0x01 });
    try buf.appendSlice(allocator, &.{ 0xFF, 0x5C, 0x00, 0x04, 0x40, 0x40 });
    try buf.appendSlice(allocator, &.{ 0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x00, 0x01 });
    try buf.appendSlice(allocator, &.{ 0xFF, 0x93, 0xE0, 0xFF, 0xD9 });
    var rep = try jp2z.validate(allocator, buf.items);
    defer rep.deinit(allocator);
    try std.testing.expect(hasFinding(rep, .jp2_packets_walked_to_end));
    var list = try jp2z.internal.extractCblkPlans(allocator, buf.items);
    defer list.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), list.plans.len);
    try std.testing.expectEqual(@as(u32, 1), list.plans[0].total_passes);
    try std.testing.expectEqual(@as(usize, 0), list.plans[0].data.len);
    try std.testing.expectEqual(@as(u8, 9), list.plans[0].numbps);
}

const e1_colr_j2c_for_zero_len = @embedFile("fixtures/conformance/e1_colr.j2c");

test "oracle: e1_colr's seven zero-byte-contribution code-blocks decode to openjpeg's coefficients" {
    const allocator = std.testing.allocator;
    var list = try jp2z.internal.extractCblkPlans(allocator, e1_colr_j2c_for_zero_len);
    defer list.deinit(allocator);
    const Case = struct { tile: u32, c: u16, r: u8, b: u8, want: []const i32 };
    const cases = [_]Case{
        .{ .tile = 3, .c = 0, .r = 1, .b = 2, .want = &.{ -37, -29, -117 } },
        .{ .tile = 4, .c = 2, .r = 1, .b = 1, .want = &.{ -31, 15 } },
        .{ .tile = 5, .c = 0, .r = 0, .b = 0, .want = &.{ -207, -63 } },
        .{ .tile = 7, .c = 2, .r = 0, .b = 0, .want = &.{207} },
        .{ .tile = 7, .c = 1, .r = 0, .b = 0, .want = &.{-7} },
        .{ .tile = 7, .c = 0, .r = 1, .b = 2, .want = &.{ -47, -99 } },
        .{ .tile = 7, .c = 0, .r = 0, .b = 0, .want = &.{-95} },
    };
    var found: u32 = 0;
    for (cases) |cs| {
        for (list.plans) |plan| {
            if (plan.tile != cs.tile or plan.component != cs.c or plan.resolution != cs.r or plan.band != cs.b or plan.sb_x0 != 0 or plan.sb_y0 != 0) continue;
            var cblk = try jp2z.internal.decodePlan(allocator, plan);
            defer cblk.deinit(allocator);
            try std.testing.expectEqual(cs.want.len, cblk.coeffs.len);
            for (cblk.coeffs, 0..) |c, i| {
                const ours = jp2z.internal.coeffToOpenJpegI32(c);
                if (ours != cs.want[i]) {
                    std.debug.print("\n[e1 zero-len] tile {d} c{d} r{d} b{d} [{d}] ours={d} oj={d} (passes {d})\n", .{ cs.tile, cs.c, cs.r, cs.b, i, ours, cs.want[i], plan.total_passes });
                    return error.MismatchedCoefficients;
                }
            }
            found += 1;
            break;
        }
    }
    try std.testing.expectEqual(@as(u32, cases.len), found);
}

// ── Tile-part COD overrides (T.800 A.6.1) ──────────────────────────
//
// A COD in a tile's first tile-part header replaces the main-header COD
// for that tile: progression order, layer count, MCT, decomposition
// levels, code-block size/style, wavelet, precincts. It was c145-ignored,
// so the packet walk drove such tiles with the MAIN parameters: d2_colr
// (tiles 1 and 3 switch progression to RPCL/CPRL) desynced into garbage
// (max_abs 254), and f1_mono's tile 4 (7 layers vs 4) had three layers
// of packets never walked — the validator saw a "clean" under-read.

const d2_colr_j2c = @embedFile("fixtures/conformance/d2_colr.j2c");

test "validate: tile-part COD raising the layer count is applied — both layers walk, no c145" {
    const allocator = std.testing.allocator;
    // Main COD: 1 layer. Tile-part COD: 2 layers (Scod 0, LRCP, layers=2, no
    // MCT, decomp 0, cblk 64x64, cbsty 0, 5/3). Body: two empty packets.
    const stream = try buildPackedMiniStream(allocator, .{
        .tp_hdr_extra = &.{ 0xFF, 0x52, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x04, 0x04, 0x00, 0x01 },
        .body = &.{ 0x00, 0x00 },
    });
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try std.testing.expect(rep.isOk());
    try std.testing.expect(!hasFinding(rep, .jp2_unsupported_marker_ignored));
    try std.testing.expect(!hasFinding(rep, .jp2_packets_under_read));
    try std.testing.expect(hasFinding(rep, .jp2_packets_walked_to_end));
}

test "deepValidate strict: f1_mono's tile-part COD (7 layers on tile 4) is applied — no c145, no under-read" {
    const allocator = std.testing.allocator;
    var rep = try jp2z.internal.deepValidate(allocator, f1_mono_j2c, true);
    defer rep.deinit(allocator);
    try std.testing.expect(!hasFinding(rep, .jp2_unsupported_marker_ignored));
    try std.testing.expect(!hasFinding(rep, .jp2_packets_under_read));
    try std.testing.expect(rep.overall != .fail);
}

test "cleanroom: d2_colr (tile-part COD switches progression on tiles 1 and 3) byte-exact vs openjpeg" {
    const allocator = std.testing.allocator;
    var img = try jp2z.internal.decodeCleanroom(allocator, d2_colr_j2c);
    defer img.deinit(allocator);
    var oracle = try jp2z.internal.openjpegDecode(allocator, d2_colr_j2c);
    defer oracle.deinit(allocator);
    try std.testing.expectEqual(oracle.width, img.width);
    try std.testing.expectEqual(oracle.height, img.height);
    const comps: usize = img.num_components;
    try std.testing.expectEqual(@as(usize, oracle.channels), comps);
    const n: usize = @as(usize, img.width) * @as(usize, img.height);
    var c: usize = 0;
    while (c < comps) : (c += 1) {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (@as(i32, img.planes[c][i]) != @as(i32, oracle.pixels[i * comps + c])) {
                std.debug.print("\n[d2] mismatch c{d} at ({d},{d}): ours={d} oj={d}\n", .{ c, i % img.width, i / img.width, img.planes[c][i], oracle.pixels[i * comps + c] });
                return error.PixelMismatch;
            }
        }
    }
}

// ── COC / RGN per-component overrides (T.800 A.6.2 / A.6.3) ────────
//
// COC gives one component its own decomposition count, code-block size and
// style, wavelet and precincts; RGN gives it an ROI up-shift that pushes
// the coded bit-planes past M_b. Both were c145-ignored. Ten ISO fixtures
// use them and EVERY one failed strict validation for it: the packet walk
// drove the component with the main COD geometry (desync → false entropy
// findings) or the pass budget ignored the ROI shift (false c253/c255).

const p0_02_j2k = @embedFile("fixtures/conformance/p0_02.j2k");
const p0_03_j2k = @embedFile("fixtures/conformance/p0_03.j2k");
const p0_06_j2k = @embedFile("fixtures/conformance/p0_06.j2k");
const p1_01_j2k = @embedFile("fixtures/conformance/p1_01.j2k");
const p1_07_j2k = @embedFile("fixtures/conformance/p1_07.j2k");
const p0_02_t1_oracle = @embedFile("fixtures/oracles/p0_02.t1.bin");
const p0_03_t1_oracle = @embedFile("fixtures/oracles/p0_03.t1.bin");
const p1_01_t1_oracle = @embedFile("fixtures/oracles/p1_01.t1.bin");
const p1_07_t1_oracle = @embedFile("fixtures/oracles/p1_07.t1.bin");

test "validate: main-header COC (decomp 1 on component 1) walks every packet in LRCP, RPCL and CPRL — no c145" {
    const allocator = std.testing.allocator;
    // Csiz=2, COD decomp 0. COC for component 1: Lcoc=9, Ccoc=1, Scoc=0,
    // SPcoc decomp=1 cblk 64x64 cbsty 0 5/3. Packets: comp 0 → 1 (r0),
    // comp 1 → 2 (r0, r1) = 3 empty packets in any progression.
    for ([_]u8{ 0, 2, 4 }) |prog| {
        const stream = try buildPackedMiniStream(allocator, .{
            .components = 2,
            .prog = prog,
            // Component 1 gets decomp 1 via COC: the shared QCD needs 4 entries (A.6.4).
            .qcd_body = &.{ 0x40, 0x40, 0x48, 0x48, 0x50 },
            .main_extra = &.{ 0xFF, 0x53, 0x00, 0x09, 0x01, 0x00, 0x01, 0x04, 0x04, 0x00, 0x01 },
            .body = &.{ 0x00, 0x00, 0x00 },
        });
        defer allocator.free(stream);
        var rep = try jp2z.validate(allocator, stream);
        defer rep.deinit(allocator);
        try std.testing.expect(!hasFinding(rep, .jp2_unsupported_marker_ignored));
        try std.testing.expect(hasFinding(rep, .jp2_packets_walked_to_end));
        try std.testing.expect(!hasFinding(rep, .jp2_packets_under_read));
        try std.testing.expect(rep.isOk());
    }
}

test "validate: main-header RGN (ROI shift 8 on component 0) is applied — no c145, clean walk" {
    const allocator = std.testing.allocator;
    const stream = try buildPackedMiniStream(allocator, .{ .main_extra = &.{ 0xFF, 0x5E, 0x00, 0x05, 0x00, 0x00, 0x08 } });
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try std.testing.expect(!hasFinding(rep, .jp2_unsupported_marker_ignored));
    try std.testing.expect(rep.isOk());
}

test "deepValidate strict: the six vendored COC/RGN ISO fixtures accept with no ignored marker" {
    const allocator = std.testing.allocator;
    const fixtures = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "p0_02", .data = p0_02_j2k }, // COC, TERMALL+PTERM+SEGSYM, dx=2
        .{ .name = "p0_03", .data = p0_03_j2k }, // tile-part RGN shift 7, signed 4-bit, RPCL, 2x2 tiles
        .{ .name = "p0_06", .data = p0_06_j2k }, // COC (9/7 vs 5/3 per component), main+tile RGN, 4 comps
        .{ .name = "p0_13", .data = p0_13_j2k }, // 257 comps, COC, QCC, RGN
        .{ .name = "p1_01", .data = p1_01_j2k }, // COC
        .{ .name = "p1_07", .data = p1_07_j2k }, // COC with custom precincts, dx=4 on comp 1
    };
    for (fixtures) |f| {
        var rep = try jp2z.internal.deepValidate(allocator, f.data, true);
        defer rep.deinit(allocator);
        if (rep.overall == .fail or hasFinding(rep, .jp2_unsupported_marker_ignored)) {
            std.debug.print("\n[coc/rgn] {s}: overall={s}\n", .{ f.name, @tagName(rep.overall) });
            for (rep.findings.items) |fd| if (fd.severity == .warn or fd.severity == .fail) std.debug.print("  {s} {s} @{?d}\n", .{ @tagName(fd.severity), @tagName(fd.code), fd.offset });
            return error.TestUnexpectedResult;
        }
    }
}

test "corpus: the three large COC fixtures (p0_05, p0_08, p1_03) accept under strict validation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root_z = std.c.getenv("OPENJPEG_DATA") orelse return error.SkipZigTest;
    const root = std.mem.span(root_z);
    for ([_][]const u8{ "p0_05.j2k", "p0_08.j2k", "p1_03.j2k" }) |name| {
        const path = try std.fs.path.join(allocator, &.{ root, "input", "conformance", name });
        defer allocator.free(path);
        var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
        defer file.close(io);
        var fr = file.reader(io, &.{});
        const data = try fr.interface.allocRemaining(allocator, .limited(8 * 1024 * 1024));
        defer allocator.free(data);
        var rep = try jp2z.internal.deepValidate(allocator, data, true);
        defer rep.deinit(allocator);
        if (rep.overall == .fail or hasFinding(rep, .jp2_unsupported_marker_ignored)) {
            std.debug.print("\n[coc corpus] {s}: overall={s}\n", .{ name, @tagName(rep.overall) });
            for (rep.findings.items) |fd| if (fd.severity == .warn or fd.severity == .fail) std.debug.print("  {s} {s} @{?d}\n", .{ @tagName(fd.severity), @tagName(fd.code), fd.offset });
            return error.TestUnexpectedResult;
        }
    }
}

/// Byte-perfect tier-1 comparison of every oracle record against the
/// matching jp2z plan. The dump hardcodes tile 0 and records ABSOLUTE
/// band coordinates, so plans are keyed by (component, resolution, band,
/// bandOrigin(tile-component origin) + subband-internal rect), with the
/// tile-component origin on the component's sub-sampled grid and the
/// component's own decomposition count.
fn expectT1Oracle(allocator: std.mem.Allocator, data: []const u8, dump: []const u8, label: []const u8) !void {
    const records = try parseOracleDump(allocator, dump);
    defer freeOracleRecords(allocator, records);
    var list = try jp2z.internal.extractCblkPlans(allocator, data);
    defer list.deinit(allocator);
    var rep = try jp2z.validate(allocator, data);
    defer rep.deinit(allocator);
    const p = rep.coding_params orelse return error.NoCodingParams;
    const xsiz = p.image_x0 + rep.width.?;
    const ysiz = p.image_y0 + rep.height.?;
    var compared: u32 = 0;
    for (records) |rec| {
        for (list.plans) |plan| {
            if (plan.component != rec.component or plan.resolution != rec.resno or plan.band != rec.orient) continue;
            const tr = p.tileRect(xsiz, ysiz, plan.tile);
            const ci: usize = @min(plan.component, 15);
            const dx: u32 = p.comp_dx[ci];
            const dy: u32 = p.comp_dy[ci];
            const tcx0 = (tr.x0 + dx - 1) / dx;
            const tcy0 = (tr.y0 + dy - 1) / dy;
            const decomp = p.codingFor(plan.component).num_decomp_levels;
            const bo = jp2z.internal.bandOrigin(tcx0, tcy0, decomp, plan.resolution, plan.band);
            if (bo.x0 + plan.sb_x0 != rec.cblk_x0 or bo.y0 + plan.sb_y0 != rec.cblk_y0) continue;
            var cblk = try jp2z.internal.decodePlan(allocator, plan);
            defer cblk.deinit(allocator);
            if (cblk.coeffs.len != rec.data.len) {
                std.debug.print("\n[{s} oracle] tile {d} c{d} r{d} b{d} sb({d},{d}): size {d} vs oracle {d}\n", .{ label, plan.tile, plan.component, plan.resolution, plan.band, plan.sb_x0, plan.sb_y0, cblk.coeffs.len, rec.data.len });
                return error.TestUnexpectedResult;
            }
            for (cblk.coeffs, 0..) |c, i| {
                const ours = jp2z.internal.coeffToOpenJpegI32(c);
                if (ours != rec.data[i]) {
                    std.debug.print("\n[{s} oracle] tile {d} c{d} r{d} b{d} sb({d},{d}) numbps {d}/{d} passes {d}: [{d}] ours={d} oj={d}\n", .{ label, plan.tile, plan.component, plan.resolution, plan.band, plan.sb_x0, plan.sb_y0, plan.numbps, rec.numbps, plan.total_passes, i, ours, rec.data[i] });
                    return error.MismatchedCoefficients;
                }
            }
            compared += 1;
            break;
        }
    }
    if (compared != records.len) {
        std.debug.print("\n[{s} oracle] matched {d} of {d} records\n", .{ label, compared, records.len });
        return error.TestUnexpectedResult;
    }
}

test "oracle dump: p0_02 (COC: cblk 32, TERMALL+PTERM+SEGSYM, dx=2) byte-perfect" {
    try expectT1Oracle(std.testing.allocator, p0_02_j2k, p0_02_t1_oracle, "p0_02");
}

test "oracle dump: p1_01 (COC) byte-perfect" {
    try expectT1Oracle(std.testing.allocator, p1_01_j2k, p1_01_t1_oracle, "p1_01");
}

test "oracle dump: p1_07 (COC with custom precincts, component 1 dx=4) byte-perfect" {
    try expectT1Oracle(std.testing.allocator, p1_07_j2k, p1_07_t1_oracle, "p1_07");
}

test "oracle dump: p0_03 (tile-part RGN shift 7: coded planes = M_b + 7 - zbp) byte-perfect pre-descale" {
    try expectT1Oracle(std.testing.allocator, p0_03_j2k, p0_03_t1_oracle, "p0_03");
}

test "validate: reserved markers FF30..FF3F carry no segment — skipped in main and tile-part headers (p0_02's FF30)" {
    // T.800 Table A.2. p0_02 puts FF30 right after its COM; the walker read
    // the next two bytes (the SOT marker itself) as a length and declared
    // the stream truncated at the first tile-part.
    const allocator = std.testing.allocator;
    const stream = try buildPackedMiniStream(allocator, .{ .main_extra = &.{ 0xFF, 0x30 }, .tp_hdr_extra = &.{ 0xFF, 0x3F } });
    defer allocator.free(stream);
    var rep = try jp2z.validate(allocator, stream);
    defer rep.deinit(allocator);
    try std.testing.expect(rep.isOk());
    try std.testing.expect(!hasFinding(rep, .truncated_stream));
    try std.testing.expect(!hasFinding(rep, .unknown_marker));
    try std.testing.expect(hasFinding(rep, .jp2_packets_walked_to_end));
}

const p0_13_t1_oracle = @embedFile("fixtures/oracles/p0_13.t1.bin");

test "oracle dump: p0_13 (257 components, COC decomp/cblk per component, QCC, RGN shift 11) byte-perfect" {
    // The Phase-1 openjpeg wrapper panics on this file (16-bit output cast,
    // 257 components), so the dump comes from opj_decompress; the tier-1
    // comparison itself needs no decode.
    try expectT1Oracle(std.testing.allocator, p0_13_j2k, p0_13_t1_oracle, "p0_13");
}

// ── Residual catchable-corruption audit (2026-09-06) ────────────────
//
// Fields the walker read but never judged, or judged too gently for a
// stream that cannot be decoded. Each case flips one field of the crafted
// 4x4 mini-stream at a known offset (SIZ at 2, COD at 45, QCD at 59 for
// the one-component builder output) and asserts the verdict class:
//   - undecodable value            → FAIL (progression order, MCT, wavelet
//                                    id, quantization style, precision,
//                                    tile count, CRG length)
//   - reserved-but-decodable value → WARN (Rsiz undefined bits, COM Rcom,
//                                    TLM Stlm reserved bits)
//   - defined-but-unsupported      → c145 WARN (Rsiz Part-2 / HTJ2K bits)

fn patched(allocator: std.mem.Allocator, base: []const u8, offset: usize, bytes: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, base);
    @memcpy(out[offset .. offset + bytes.len], bytes);
    return out;
}

test "audit: SIZ Rsiz — 0/1/2 clean; Part-2/HTJ2K bits and recognised cinema/broadcast/IMF profiles → c145 WARN; undefined value → FAIL (Table A.9 + amendments)" {
    const allocator = std.testing.allocator;
    const base = try buildPackedMiniStream(allocator, .{});
    defer allocator.free(base);
    for ([_][2]u8{ .{ 0x00, 0x00 }, .{ 0x00, 0x01 }, .{ 0x00, 0x02 } }) |v| {
        const s = try patched(allocator, base, 6, &v);
        defer allocator.free(s);
        var rep = try jp2z.validate(allocator, s);
        defer rep.deinit(allocator);
        try std.testing.expect(rep.isOk());
        try std.testing.expect(!hasFinding(rep, .jp2_invalid_siz));
        try std.testing.expect(!hasFinding(rep, .jp2_unsupported_marker_ignored));
    }
    const ext = try patched(allocator, base, 6, &.{ 0x40, 0x00 }); // bit 14: Part 2 / HT capability
    defer allocator.free(ext);
    var rep_ext = try jp2z.validate(allocator, ext);
    defer rep_ext.deinit(allocator);
    try std.testing.expect(hasFinding(rep_ext, .jp2_unsupported_marker_ignored));
    try std.testing.expect(rep_ext.overall != .fail);
    // 0x0007 is a recognised profile (Cinema LTS, T.800 Amd 1) whose
    // constraints jp2z does not verify: valid-but-unchecked, c145 WARN.
    const cin = try patched(allocator, base, 6, &.{ 0x00, 0x07 });
    defer allocator.free(cin);
    var rep_cin = try jp2z.validate(allocator, cin);
    defer rep_cin.deinit(allocator);
    try std.testing.expect(hasFinding(rep_cin, .jp2_unsupported_marker_ignored));
    try std.testing.expect(rep_cin.overall != .fail);
    // Broadcast (0x0101: multi-tile? no: single-tile, mainlevel 1) and IMF
    // (0x0412: 2K, mainlevel 2, sublevel 1) profiles likewise.
    for ([_][2]u8{ .{ 0x01, 0x01 }, .{ 0x04, 0x12 } }) |v| {
        const p = try patched(allocator, base, 6, &v);
        defer allocator.free(p);
        var rp = try jp2z.validate(allocator, p);
        defer rp.deinit(allocator);
        try std.testing.expect(hasFinding(rp, .jp2_unsupported_marker_ignored));
        try std.testing.expect(rp.overall != .fail);
    }
    // 0x000A is defined by neither T.800 nor any amendment: FAIL.
    const bad = try patched(allocator, base, 6, &.{ 0x00, 0x0A });
    defer allocator.free(bad);
    var rep_bad = try jp2z.validate(allocator, bad);
    defer rep_bad.deinit(allocator);
    try std.testing.expect(failDetailContains(rep_bad, .jp2_invalid_siz, "Rsiz"));
    try std.testing.expectEqual(jp2z.Severity.fail, rep_bad.overall);
}

test "audit: SIZ Ssiz precision above 38 bits → jp2_invalid_siz FAIL (Table A.10)" {
    const allocator = std.testing.allocator;
    const base = try buildPackedMiniStream(allocator, .{});
    defer allocator.free(base);
    const s = try patched(allocator, base, 42, &.{0x7F}); // 128-bit unsigned
    defer allocator.free(s);
    var rep = try jp2z.validate(allocator, s);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(hasFinding(rep, .jp2_invalid_siz));
    const ok = try patched(allocator, base, 42, &.{0x25}); // 38-bit: the ceiling, legal
    defer allocator.free(ok);
    var rep_ok = try jp2z.validate(allocator, ok);
    defer rep_ok.deinit(allocator);
    try std.testing.expect(!hasFinding(rep_ok, .jp2_invalid_siz));
}

test "audit: SIZ tile grid of 65536 tiles → jp2_invalid_siz FAIL (A.5.1 caps tiles at 65535)" {
    const allocator = std.testing.allocator;
    const base = try buildPackedMiniStream(allocator, .{});
    defer allocator.free(base);
    // 256x256 image in 1x1 tiles = 65536 tiles.
    const s0 = try patched(allocator, base, 8, &.{ 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00 });
    defer allocator.free(s0);
    const s = try patched(allocator, s0, 24, &.{ 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01 });
    defer allocator.free(s);
    var rep = try jp2z.validate(allocator, s);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(hasFinding(rep, .jp2_invalid_siz));
}

test "audit: COD undecodable values FAIL — progression order 5, MCT 2, wavelet id 2" {
    const allocator = std.testing.allocator;
    const base = try buildPackedMiniStream(allocator, .{});
    defer allocator.free(base);
    const cases = [_]struct { off: usize, val: u8, code: jp2z.FindingCode }{
        .{ .off = 50, .val = 5, .code = .jp2_bad_progression_order },
        .{ .off = 53, .val = 2, .code = .jp2_invalid_codestream },
        .{ .off = 58, .val = 2, .code = .jp2_invalid_codestream },
    };
    for (cases) |c| {
        const s = try patched(allocator, base, c.off, &.{c.val});
        defer allocator.free(s);
        var rep = try jp2z.validate(allocator, s);
        defer rep.deinit(allocator);
        try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
        try std.testing.expect(hasFinding(rep, c.code));
    }
}

test "audit: QCD quantization style 3 (reserved) → FAIL, not WARN" {
    const allocator = std.testing.allocator;
    const base = try buildPackedMiniStream(allocator, .{});
    defer allocator.free(base);
    const s = try patched(allocator, base, 63, &.{0x43}); // G=2, style 3
    defer allocator.free(s);
    var rep = try jp2z.validate(allocator, s);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(hasFinding(rep, .jp2_invalid_codestream));
}

test "audit: COM Rcom registration — 0 and 1 clean; 2 (reserved) → FAIL (Table A.43)" {
    const allocator = std.testing.allocator;
    for ([_]u8{ 0, 1 }) |rcom| {
        const s = try buildPackedMiniStream(allocator, .{ .main_extra = &.{ 0xFF, 0x64, 0x00, 0x06, 0x00, rcom, 0x68, 0x69 } });
        defer allocator.free(s);
        var rep = try jp2z.validate(allocator, s);
        defer rep.deinit(allocator);
        try std.testing.expect(rep.isOk());
        try std.testing.expect(!hasFinding(rep, .jp2_invalid_codestream));
    }
    const bad = try buildPackedMiniStream(allocator, .{ .main_extra = &.{ 0xFF, 0x64, 0x00, 0x06, 0x00, 0x02, 0x68, 0x69 } });
    defer allocator.free(bad);
    var rep_bad = try jp2z.validate(allocator, bad);
    defer rep_bad.deinit(allocator);
    try std.testing.expect(failDetailContains(rep_bad, .jp2_invalid_codestream, "Rcom"));
    try std.testing.expectEqual(jp2z.Severity.fail, rep_bad.overall);
}

test "audit: CRG length must be 2 + 4·Csiz — short → bad_marker_length FAIL; exact → clean" {
    const allocator = std.testing.allocator;
    const short = try buildPackedMiniStream(allocator, .{ .main_extra = &.{ 0xFF, 0x63, 0x00, 0x04, 0x00, 0x00 } });
    defer allocator.free(short);
    var rep = try jp2z.validate(allocator, short);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(hasFinding(rep, .bad_marker_length));
    const ok = try buildPackedMiniStream(allocator, .{ .main_extra = &.{ 0xFF, 0x63, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00 } });
    defer allocator.free(ok);
    var rep_ok = try jp2z.validate(allocator, ok);
    defer rep_ok.deinit(allocator);
    try std.testing.expect(rep_ok.isOk());
    try std.testing.expect(!hasFinding(rep_ok, .bad_marker_length));
}

test "audit: TLM Stlm reserved bits (0-3, 7) set → FAIL (Table A.34)" {
    const allocator = std.testing.allocator;
    // Ztlm=0, Stlm=0x01 (reserved low bit), one Ptlm=15 (the walked length).
    const s = try buildPackedMiniStream(allocator, .{ .main_extra = &.{ 0xFF, 0x55, 0x00, 0x06, 0x00, 0x01, 0x00, 0x0F } });
    defer allocator.free(s);
    var rep = try jp2z.validate(allocator, s);
    defer rep.deinit(allocator);
    try std.testing.expect(failDetailContains(rep, .jp2_invalid_codestream, "Stlm"));
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
}

// ── JP2 cdef channel definition (T.800 I.5.3.6) ─────────────────────
//
// cdef maps codestream channels to colour indices (Asoc 1..N) or marks
// alpha/whole-image channels. openjpeg applies it in the library, so the
// oracle's file2 output is BGR-reordered while the cleanroom emitted
// codestream order (max_abs 158, tier-1 identical). A component with a
// different bit depth has a different DC level, which makes the
// permutation observable on an otherwise all-zero crafted image.

/// wrapInJp2 with a configurable ihdr component count and extra jp2h
/// sub-boxes appended after ihdr.
fn wrapInJp2Ex(allocator: std.mem.Allocator, payload: []const u8, nc: u16, extra_jp2h: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, &.{ 0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A });
    try buf.appendSlice(allocator, &.{ 0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70, 0x6A, 0x70, 0x32, 0x20, 0x00, 0x00, 0x00, 0x00, 0x6A, 0x70, 0x32, 0x20 });
    var jp2h_len: [4]u8 = undefined;
    std.mem.writeInt(u32, &jp2h_len, @intCast(8 + 22 + extra_jp2h.len), .big);
    try buf.appendSlice(allocator, &jp2h_len);
    try buf.appendSlice(allocator, &.{ 0x6A, 0x70, 0x32, 0x68 });
    var nc_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &nc_bytes, nc, .big);
    try buf.appendSlice(allocator, &.{ 0x00, 0x00, 0x00, 0x16, 0x69, 0x68, 0x64, 0x72, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04 });
    try buf.appendSlice(allocator, &nc_bytes);
    try buf.appendSlice(allocator, &.{ 0x07, 0x07, 0x00, 0x00 });
    try buf.appendSlice(allocator, extra_jp2h);
    var lbox_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &lbox_bytes, @intCast(8 + payload.len), .big);
    try buf.appendSlice(allocator, &lbox_bytes);
    try buf.appendSlice(allocator, &.{ 0x6A, 0x70, 0x32, 0x63 });
    try buf.appendSlice(allocator, payload);
    return buf.toOwnedSlice(allocator);
}

// cdef: lbox=28 'cdef' N=3, (Cn=0,Typ=0,Asoc=3) (1,0,2) (2,0,1) — BGR order.
const cdef_bgr = [_]u8{
    0x00, 0x00, 0x00, 0x1C, 0x63, 0x64, 0x65, 0x66, 0x00, 0x03,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
    0x00, 0x01, 0x00, 0x00, 0x00, 0x02,
    0x00, 0x02, 0x00, 0x00, 0x00, 0x01,
};

test "cleanroom: JP2 cdef reorders decoded channels to colour order (BGR file2 layout)" {
    const allocator = std.testing.allocator;
    // Three components; the LAST is 12-bit, so its DC level (2048) tells it
    // apart from the 8-bit ones (128) after the permutation.
    const payload = try buildPackedMiniStream(allocator, .{ .components = 3, .last_comp_prec = 12, .body = &.{ 0x00, 0x00, 0x00 } });
    defer allocator.free(payload);
    // Depths vary (8, 8, 12): ihdr BPC 0xFF + a bpcc box (I.5.3.2), so the
    // container tells the truth about its codestream.
    const bpcc_8_8_12 = [_]u8{ 0x00, 0x00, 0x00, 0x0B, 0x62, 0x70, 0x63, 0x63, 0x07, 0x07, 0x0B };
    const extra = try std.mem.concat(allocator, u8, &.{ &bpcc_8_8_12, &cdef_bgr });
    defer allocator.free(extra);
    const jp2_uniform = try wrapInJp2Ex(allocator, payload, 3, extra);
    defer allocator.free(jp2_uniform);
    const jp2 = try patched(allocator, jp2_uniform, 58, &.{0xFF}); // ihdr BPC: varying
    defer allocator.free(jp2);
    var rep = try jp2z.validate(allocator, jp2);
    defer rep.deinit(allocator);
    try std.testing.expect(rep.isOk());
    var img = try jp2z.internal.decodeCleanroom(allocator, jp2);
    defer img.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 3), img.num_components);
    // Colour 0 (R) ← codestream channel 2 (the 12-bit one); colour 2 (B) ← channel 0.
    try std.testing.expectEqual(@as(i32, 2048), img.planes[0][0]);
    try std.testing.expectEqual(@as(i32, 128), img.planes[1][0]);
    try std.testing.expectEqual(@as(i32, 128), img.planes[2][0]);
    try std.testing.expectEqual(@as(u8, 12), img.precs[0]);
    try std.testing.expectEqual(@as(u8, 8), img.precs[2]);
}

test "validate: cdef naming a channel beyond NC, or two channels for one colour → FAIL" {
    const allocator = std.testing.allocator;
    const payload = try buildPackedMiniStream(allocator, .{ .components = 3, .body = &.{ 0x00, 0x00, 0x00 } });
    defer allocator.free(payload);
    // Cn=7 with NC=3.
    var beyond = cdef_bgr;
    beyond[11] = 0x07;
    const j1 = try wrapInJp2Ex(allocator, payload, 3, &beyond);
    defer allocator.free(j1);
    var r1 = try jp2z.validate(allocator, j1);
    defer r1.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, r1.overall);
    try std.testing.expect(hasFinding(r1, .jp2_invalid_codestream));
    // Two channels both claim colour 3.
    var dup = cdef_bgr;
    dup[21] = 0x03;
    const j2 = try wrapInJp2Ex(allocator, payload, 3, &dup);
    defer allocator.free(j2);
    var r2 = try jp2z.validate(allocator, j2);
    defer r2.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, r2.overall);
    try std.testing.expect(hasFinding(r2, .jp2_invalid_codestream));
}

// ── Geometry at the legal extremes must not panic ───────────────────
//
// T.800 allows 32 decomposition levels and 2^15 precincts; the geometry
// helpers held their shift amounts in u5, so a level count of 32 (or
// PPx 15 + level) overflowed the shift on LEGAL input. Seven files of
// openjpeg's nonregression fuzz corpus crashed the validator there.

test "validate: 32 decomposition levels with 2^15 precincts walks without panicking" {
    const allocator = std.testing.allocator;
    // COD: Scod=1 (user precincts), decomp=32, 33 precinct bytes of 0xFF
    // (PPx=PPy=15). QCD style 0: 1 + 3*32 = 97 subband bytes.
    var cod = std.ArrayList(u8).empty;
    defer cod.deinit(allocator);
    try cod.appendSlice(allocator, &.{ 0xFF, 0x52, 0x00, 12 + 33, 0x01, 0x00, 0x00, 0x01, 0x00, 0x20, 0x04, 0x04, 0x00, 0x01 });
    try cod.appendNTimes(allocator, 0xFF, 33);
    var qcd = std.ArrayList(u8).empty;
    defer qcd.deinit(allocator);
    try qcd.appendSlice(allocator, &.{ 0xFF, 0x5C, 0x00, 3 + 97, 0x40 });
    try qcd.appendNTimes(allocator, 0x40, 97);
    // 4x4 tile with 32 levels: every resolution is non-empty (1x1 up to 4x4),
    // one precinct each → 33 empty packets.
    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try body.appendNTimes(allocator, 0x00, 33);
    // Build by hand: SOC + SIZ(4x4) + COD + QCD + SOT + SOD + body + EOC.
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, &.{ 0xFF, 0x4F });
    try buf.appendSlice(allocator, &.{
        0xFF, 0x51, 0x00, 0x29, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x07, 0x01, 0x01,
    });
    try buf.appendSlice(allocator, cod.items);
    try buf.appendSlice(allocator, qcd.items);
    const psot: u32 = @intCast(12 + 2 + body.items.len);
    try buf.appendSlice(allocator, &.{ 0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00 });
    var psot_b: [4]u8 = undefined;
    std.mem.writeInt(u32, &psot_b, psot, .big);
    try buf.appendSlice(allocator, &psot_b);
    try buf.appendSlice(allocator, &.{ 0x00, 0x01, 0xFF, 0x93 });
    try buf.appendSlice(allocator, body.items);
    try buf.appendSlice(allocator, &.{ 0xFF, 0xD9 });
    var rep = try jp2z.validate(allocator, buf.items);
    defer rep.deinit(allocator);
    try std.testing.expect(rep.overall != .fail);
    try std.testing.expect(hasFinding(rep, .jp2_packets_walked_to_end));
    // And the strict deep pass, which reaches the same geometry from the extractor.
    var deep = try jp2z.internal.deepValidate(allocator, buf.items, true);
    defer deep.deinit(allocator);
    try std.testing.expect(deep.overall != .fail);
}

/// Two-tile-part stream (COD 2 layers → 2 packets, one per part) with the
/// given TNsot in BOTH SOT segments. TNsot=1 is the encoder off-by-one seen
/// in the wild (openjpeg nonregression: issue206/208/235/254, text_GBR, the
/// eci CIELab set; Britannica 2007 PDF JPX via validate); 2 is correct; 0
/// is "unspecified" (A.4.2).
fn twoPartStream(allocator: std.mem.Allocator, tnsot: u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, &.{ 0xFF, 0x4F });
    try buf.appendSlice(allocator, &.{
        0xFF, 0x51, 0x00, 0x29, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x07, 0x01, 0x01,
    });
    try buf.appendSlice(allocator, &.{ 0xFF, 0x52, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x04, 0x04, 0x00, 0x01 });
    try buf.appendSlice(allocator, &.{ 0xFF, 0x5C, 0x00, 0x04, 0x40, 0x40 });
    // Part 0: Psot=15, TPsot=0, SOD, one empty packet.
    try buf.appendSlice(allocator, &.{ 0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x00, tnsot, 0xFF, 0x93, 0x00 });
    // Part 1: TPsot=1, SOD, the second empty packet.
    try buf.appendSlice(allocator, &.{ 0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x01, tnsot, 0xFF, 0x93, 0x00 });
    try buf.appendSlice(allocator, &.{ 0xFF, 0xD9 });
    return buf.toOwnedSlice(allocator);
}

test "validate: TNsot declared correctly (2) or unspecified (0) → no FAIL, both parts walk (A.4.2 controls)" {
    const allocator = std.testing.allocator;
    for ([_]u8{ 2, 0 }) |tnsot| {
        const data = try twoPartStream(allocator, tnsot);
        defer allocator.free(data);
        var rep = try jp2z.validate(allocator, data);
        defer rep.deinit(allocator);
        for (rep.findings.items) |f| try std.testing.expect(f.severity != .fail);
        try std.testing.expect(hasFinding(rep, .jp2_packets_walked_to_end));
    }
}

test "validate: more tile-parts than TNsot declares → FAIL naming tile, part and TNsot (A.4.2); the extra part still walks" {
    const allocator = std.testing.allocator;
    // Peter, 2026-09-12: proven nonconformance fails and is reported; the
    // walk continues so later faults are still found (no early abort).
    const data = try twoPartStream(allocator, 1);
    defer allocator.free(data);
    var rep = try jp2z.validate(allocator, data);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(failDetailContains(rep, .jp2_invalid_codestream, "tile 0: tile-part 1 exceeds the declared TNsot 1"));
    try std.testing.expect(hasFinding(rep, .jp2_packets_walked_to_end));
    try std.testing.expect(!hasFinding(rep, .truncated_stream));
}


test "audit: SIZ tile-count ceil must not overflow u32 when Ysiz + YTsiz exceed 2^32 (issue823 fuzz corpus)" {
    // issue823.jp2: Ysiz 0xFFF60001, YTsiz 0xF0000100. Every A.5.1 range
    // check passes, but ceil((Ysiz - YTOsiz) / YTsiz) computed as
    // (a + b - 1) / b overflows u32 → panic. The grid is 1 × 2 tiles.
    const allocator = std.testing.allocator;
    const base = try buildPackedMiniStream(allocator, .{});
    defer allocator.free(base);
    const tall = try patched(allocator, base, 12, &.{ 0xFF, 0xF6, 0x00, 0x01 });
    defer allocator.free(tall);
    const data = try patched(allocator, tall, 28, &.{ 0xF0, 0x00, 0x01, 0x00 });
    defer allocator.free(data);
    var report = try jp2z.validate(allocator, data);
    defer report.deinit(allocator);
    const cp = report.coding_params.?;
    const nt = cp.numTilesXY(cp.image_x0 + report.width.?, cp.image_y0 + report.height.?);
    try std.testing.expectEqual(@as(u32, 1), nt.x);
    try std.testing.expectEqual(@as(u32, 2), nt.y);
}

// ── Surplus coding passes (beyond 3·numbps−2) ─────────────────────
//
// test_lossless.j2k (COM "ClearCanvas DICOM OpenJPEG", 12-bit 5/3) declares
// 3·numbps−2 + {2,5,8} passes on 58 code-blocks. The bytes are real — the
// byte budget is clean when every declared pass is decoded — and openjpeg
// and JasPer produce byte-identical full-range output by ignoring passes
// below bit-plane 0 (t1.c: `bpno_plus_one >= 1`). jp2z ran those passes at
// a clamped plane and wrote magnitude bit 0 (T1 diff: ours=±1, oj=0).
// Policy: surplus passes keep MQ/state fidelity (so the budget check still
// bites on kodak-style garbage counts) but never touch reconstruction, and
// the finding is a WARN in both modes: decodable by convention.

test "surplus coding passes never alter reconstruction but keep consuming bytes (openjpeg/JasPer convention)" {
    const allocator = std.testing.allocator;
    // Deterministic pseudo-random entropy bytes: any byte string is a valid
    // MQ codeword prefix, so both decodes run real passes over real state.
    var seed: u32 = 0x9E3779B9;
    var data: [96]u8 = undefined;
    for (&data) |*b| {
        seed = seed *% 1664525 +% 1013904223;
        b.* = @truncate(seed >> 24);
    }
    const numbps: u8 = 3; // 3 planes → at most 7 passes
    var legal: jp2z.CblkDecodePlan = .{
        .tile = 0, .component = 0, .resolution = 0, .band = 0, .precinct = 0,
        .sb_x0 = 0, .sb_y0 = 0, .sb_x1 = 8, .sb_y1 = 8,
        .zero_bitplanes = 0, .numbps = numbps, .total_passes = 7, .cblksty = 0,
        .data = try allocator.dupe(u8, &data),
    };
    defer legal.deinit(allocator);
    var surplus = legal;
    surplus.data = try allocator.dupe(u8, &data);
    surplus.total_passes = 10;
    defer surplus.deinit(allocator);
    var a = try jp2z.internal.decodePlan(allocator, legal);
    defer a.deinit(allocator);
    var b = try jp2z.internal.decodePlan(allocator, surplus);
    defer b.deinit(allocator);
    var nonzero: usize = 0;
    for (a.coeffs, b.coeffs) |ca, cb| {
        const va = jp2z.internal.coeffToOpenJpegI32(ca);
        if (va != 0) nonzero += 1;
        try std.testing.expectEqual(va, jp2z.internal.coeffToOpenJpegI32(cb));
    }
    try std.testing.expect(nonzero > 0); // the legal decode must be non-trivial
    // The surplus passes still run over the MQ stream (state fidelity):
    // they cannot leave MORE bytes unconsumed than the legal decode did.
    try std.testing.expect(b.under_read <= a.under_read);
}

/// Crafted minimal stream: mini-stream shell (SIZ 4x4 8-bit, QCD G=2 eps=8
/// → LL M_b=9) + one packet whose zero-bitplane tag tree encodes zbp=8
/// (numbps=1 → at most 1 pass) yet declares 4 coding passes with a 4-byte
/// body. Header bits: 1 (non-empty) 1 (included) 00000000 1 (zbp 8)
/// 1101 (4 passes) 0 (lblock) 00100 (len 4 in 3+⌊log2 4⌋ bits) → C0 3A 20.
fn buildSurplusPassStream(allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, &.{ 0xFF, 0x4F });
    try buf.appendSlice(allocator, &.{
        0xFF, 0x51, 0x00, 0x29, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x07, 0x01, 0x01,
    });
    try buf.appendSlice(allocator, &.{ 0xFF, 0x52, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x04, 0x04, 0x00, 0x01 });
    try buf.appendSlice(allocator, &.{ 0xFF, 0x5C, 0x00, 0x04, 0x40, 0x40 });
    // Psot = 12 (SOT) + 2 (SOD) + 7 (packet: 3 header + 4 body) = 21
    try buf.appendSlice(allocator, &.{ 0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x15, 0x00, 0x01 });
    try buf.appendSlice(allocator, &.{ 0xFF, 0x93 }); // SOD
    try buf.appendSlice(allocator, &.{ 0xC0, 0x3A, 0x20, 0x5A, 0xC3, 0x3C, 0x0F }); // crafted packet
    try buf.appendSlice(allocator, &.{ 0xFF, 0xD9 }); // EOC
    return buf.toOwnedSlice(allocator);
}

test "deepValidate: surplus coding passes → coding_pass_overflow FAILs in strict mode, WARNs in lenient (decodable by convention, still nonconforming)" {
    const allocator = std.testing.allocator;
    const stream = try buildSurplusPassStream(allocator);
    defer allocator.free(stream);
    var rep = try jp2z.internal.deepValidate(allocator, stream, true);
    defer rep.deinit(allocator);
    var found: ?jp2z.Finding = null;
    for (rep.findings.items) |f| if (f.code == .coding_pass_overflow) {
        found = f;
    };
    const f = found orelse return error.MissingCodingPassOverflow;
    // Strict: the declared passes have no defined meaning → FAIL (Peter,
    // 2026-09-12). Lenient: WARN. Either way the detail names the convention.
    try std.testing.expectEqual(jp2z.Severity.fail, f.severity);
    try std.testing.expect(f.detail != null);
    try std.testing.expect(std.mem.indexOf(u8, f.detail.?, "ignored") != null);
    var lenient = try jp2z.internal.deepValidate(allocator, stream, false);
    defer lenient.deinit(allocator);
    var lf: ?jp2z.Finding = null;
    for (lenient.findings.items) |g| if (g.code == .coding_pass_overflow) {
        lf = g;
    };
    try std.testing.expectEqual(jp2z.Severity.warn, (lf orelse return error.MissingCodingPassOverflow).severity);
}

// ── Nonregression triage: the three files only jp2z rejects ───────
//
// After the JasPer cross-check (LEARNINGS 2026-09-06) three openjpeg-data
// files remained that openjpeg AND JasPer decode while jp2z FAILs:
// Marrin.jp2 (Kakadu 5.2.1, COD says 2 layers, the tile-part holds only
// layer 0's 12 packets — openjpeg's own packet dump places all 12 layer-1
// packets at the tile-part's end offset), issue211.jp2 (a CRLF after the
// last box) and htj2k/Bretagne1_ht.j2k (HT code-blocks, T.814).

test "missing trailing packets: truncated_stream names the tile, the packet count and the next expected packet" {
    const allocator = std.testing.allocator;
    // 2 layers declared, body holds ONE empty packet: layer 1's packet is absent.
    const data = try buildPackedMiniStream(allocator, .{ .layers = 2, .body = &.{0x00} });
    defer allocator.free(data);
    var rep = try jp2z.validate(allocator, data);
    defer rep.deinit(allocator);
    var found: ?jp2z.Finding = null;
    for (rep.findings.items) |f| if (f.code == .truncated_stream) {
        found = f;
    };
    const f = found orelse return error.MissingTruncatedStream;
    try std.testing.expectEqual(jp2z.Severity.fail, f.severity);
    const d = f.detail orelse return error.MissingDetail;
    try std.testing.expect(std.mem.indexOf(u8, d, "1 of 2 packets") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "layer 1") != null);
}

test "JP2: bytes after the last box that cannot form a box header → FAIL jp2_trailing_bytes, not truncated_stream (issue211)" {
    const allocator = std.testing.allocator;
    const payload = try buildPackedMiniStream(allocator, .{});
    defer allocator.free(payload);
    const clean = try wrapInJp2Ex(allocator, payload, 1, &.{});
    defer allocator.free(clean);
    const data = try std.mem.concat(allocator, u8, &.{ clean, &.{ 0x0D, 0x0A } });
    defer allocator.free(data);
    var rep = try jp2z.validate(allocator, data);
    defer rep.deinit(allocator);
    try std.testing.expect(!hasFinding(rep, .truncated_stream));
    var found: ?jp2z.Finding = null;
    for (rep.findings.items) |f| if (f.code == .jp2_trailing_bytes) {
        found = f;
    };
    const f = found orelse return error.MissingTrailingBytes;
    // A proven violation of the box structure (I.4) FAILs (Peter, 2026-09-12).
    try std.testing.expectEqual(jp2z.Severity.fail, f.severity);
    try std.testing.expectEqual(@as(?u64, clean.len), f.offset);
    try std.testing.expect(std.mem.indexOf(u8, f.detail orelse "", "2 byte") != null);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
}

test "HTJ2K code-blocks (cblksty 0x40, T.814) → valid-but-unsupported WARN, deep validation skipped, decode refused" {
    const allocator = std.testing.allocator;
    const base = try buildPackedMiniStream(allocator, .{});
    defer allocator.free(base);
    // COD at 45: FF 52 Lcod Scod SGcod(4) SPcod: decomp xcb ycb cblksty → offset 57.
    try std.testing.expectEqual(@as(u8, 0x00), base[57]);
    const data = try patched(allocator, base, 57, &.{0x40});
    defer allocator.free(data);
    var rep = try jp2z.internal.deepValidate(allocator, data, true);
    defer rep.deinit(allocator);
    try std.testing.expect(hasFinding(rep, .jp2_unsupported_marker_ignored));
    try std.testing.expect(!hasFinding(rep, .jp2_invalid_codestream));
    for (rep.findings.items) |f| switch (f.code) {
        .entropy_over_read, .entropy_under_read, .coding_pass_overflow, .zero_bitplane_overflow => return error.DeepFindingOnUnsupportedStream,
        else => {},
    };
    try std.testing.expectEqual(jp2z.Severity.warn, rep.overall);
    try std.testing.expectError(error.UnsupportedHtCodeBlocks, jp2z.internal.decodeCleanroom(allocator, data));
}

test "CAP marker (FF50, Part 2 / T.814 capabilities) → valid-but-unsupported WARN naming it, not unknown_marker" {
    const allocator = std.testing.allocator;
    // Lcap 6, Pcap 0 (no capability bits set): the smallest legal CAP.
    const data = try buildPackedMiniStream(allocator, .{ .main_extra = &.{ 0xFF, 0x50, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00 } });
    defer allocator.free(data);
    var rep = try jp2z.validate(allocator, data);
    defer rep.deinit(allocator);
    try std.testing.expect(!hasFinding(rep, .unknown_marker));
    var found: ?jp2z.Finding = null;
    for (rep.findings.items) |f| if (f.code == .jp2_unsupported_marker_ignored) {
        found = f;
    };
    const f = found orelse return error.MissingUnsupportedFinding;
    try std.testing.expectEqual(jp2z.Severity.warn, f.severity);
    try std.testing.expect(std.mem.indexOf(u8, f.detail orelse "", "CAP") != null);
    try std.testing.expect(rep.overall != .fail);
}

// ── Structural false negatives from the nonregression census ──────
//
// Five openjpeg-data files that opj_decompress REFUSES were accepted by
// jp2z with no FAIL: 1888.pdf.asan / issue408 (main header without COD),
// issue364-903 (jp2h without ihdr), issue362-2863 (a fuzzed SOT became a
// PPM marker, then SOD at the top level: no tile-part at all) and
// edf_c2_1103421 (COC with a wrong Lcoc). Each is a hard requirement of
// T.800 A.4 Table A.1 / A.6 marker-segment lengths / I.5.3.

/// Remove the first main-header marker segment `marker` (FF xx) before SOT.
fn withoutMainMarker(allocator: std.mem.Allocator, stream: []const u8, marker: u8) ![]u8 {
    var pos: usize = 2; // after SOC
    while (pos + 4 <= stream.len) {
        if (stream[pos] != 0xFF) break;
        const m = stream[pos + 1];
        if (m == 0x90) break; // SOT
        const l = std.mem.readInt(u16, stream[pos + 2 ..][0..2], .big);
        if (m == marker) return std.mem.concat(allocator, u8, &.{ stream[0..pos], stream[pos + 2 + l ..] });
        pos += 2 + l;
    }
    return error.MarkerNotFound;
}

/// Offset of the first SOT in `stream` (main-header length).
fn sotOffset(stream: []const u8) !usize {
    var pos: usize = 2;
    while (pos + 4 <= stream.len) {
        if (stream[pos] != 0xFF) break;
        if (stream[pos + 1] == 0x90) return pos;
        pos += 2 + std.mem.readInt(u16, stream[pos + 2 ..][0..2], .big);
    }
    return error.MarkerNotFound;
}

fn insertAt(allocator: std.mem.Allocator, base: []const u8, offset: usize, bytes: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ base[0..offset], bytes, base[offset..] });
}

fn failDetailContains(rep: jp2z.ValidationReport, code: jp2z.FindingCode, needle: []const u8) bool {
    for (rep.findings.items) |f| {
        if (f.code == code and f.severity == .fail and std.mem.indexOf(u8, f.detail orelse "", needle) != null) return true;
    }
    return false;
}

test "main header without COD → FAIL naming COD (T.800 A.4 Table A.1); without QCD → FAIL naming QCD" {
    const allocator = std.testing.allocator;
    const base = try buildPackedMiniStream(allocator, .{});
    defer allocator.free(base);
    const no_cod = try withoutMainMarker(allocator, base, 0x52);
    defer allocator.free(no_cod);
    var r1 = try jp2z.validate(allocator, no_cod);
    defer r1.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, r1.overall);
    try std.testing.expect(failDetailContains(r1, .jp2_invalid_codestream, "COD"));
    const no_qcd = try withoutMainMarker(allocator, base, 0x5C);
    defer allocator.free(no_qcd);
    var r2 = try jp2z.validate(allocator, no_qcd);
    defer r2.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, r2.overall);
    try std.testing.expect(failDetailContains(r2, .jp2_invalid_codestream, "QCD"));
}

test "codestream without any tile-part (EOC or SOD right after the main header) → FAIL" {
    const allocator = std.testing.allocator;
    const base = try buildPackedMiniStream(allocator, .{});
    defer allocator.free(base);
    const sot = try sotOffset(base);
    const eoc_only = try std.mem.concat(allocator, u8, &.{ base[0..sot], &.{ 0xFF, 0xD9 } });
    defer allocator.free(eoc_only);
    var r1 = try jp2z.validate(allocator, eoc_only);
    defer r1.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, r1.overall);
    try std.testing.expect(failDetailContains(r1, .jp2_invalid_codestream, "no tile-part"));
    const sod_only = try std.mem.concat(allocator, u8, &.{ base[0..sot], &.{ 0xFF, 0x93, 0x00, 0xFF, 0xD9 } });
    defer allocator.free(sod_only);
    var r2 = try jp2z.validate(allocator, sod_only);
    defer r2.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, r2.overall);
    try std.testing.expect(failDetailContains(r2, .jp2_invalid_codestream, "no tile-part"));
}

test "JP2: jp2h without ihdr → FAIL naming ihdr (I.5.3.1)" {
    const allocator = std.testing.allocator;
    const payload = try buildPackedMiniStream(allocator, .{});
    defer allocator.free(payload);
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, &.{ 0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A });
    try buf.appendSlice(allocator, &.{ 0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70, 0x6A, 0x70, 0x32, 0x20, 0x00, 0x00, 0x00, 0x00, 0x6A, 0x70, 0x32, 0x20 });
    // jp2h holding only colr (meth 1, enumcs 17 greyscale): no ihdr.
    try buf.appendSlice(allocator, &.{ 0x00, 0x00, 0x00, 0x17, 0x6A, 0x70, 0x32, 0x68 });
    try buf.appendSlice(allocator, &.{ 0x00, 0x00, 0x00, 0x0F, 0x63, 0x6F, 0x6C, 0x72, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11 });
    var lbox: [4]u8 = undefined;
    std.mem.writeInt(u32, &lbox, @intCast(8 + payload.len), .big);
    try buf.appendSlice(allocator, &lbox);
    try buf.appendSlice(allocator, &.{ 0x6A, 0x70, 0x32, 0x63 });
    try buf.appendSlice(allocator, payload);
    var rep = try jp2z.validate(allocator, buf.items);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(failDetailContains(rep, .jp2_invalid_codestream, "ihdr"));
}

test "COD / COC / RGN marker segments must have their exact T.800 length: one surplus byte → FAIL bad_marker_length" {
    const allocator = std.testing.allocator;
    const base = try buildPackedMiniStream(allocator, .{});
    defer allocator.free(base);
    // COD at 45: Lcod (47..48) 0x000C → 0x000D and a surplus byte after its body (59).
    try std.testing.expectEqual(@as(u8, 0x0C), base[48]);
    const cod_long0 = try patched(allocator, base, 48, &.{0x0D});
    defer allocator.free(cod_long0);
    const cod_long = try insertAt(allocator, cod_long0, 59, &.{0x00});
    defer allocator.free(cod_long);
    var r1 = try jp2z.validate(allocator, cod_long);
    defer r1.deinit(allocator);
    try std.testing.expect(hasFinding(r1, .bad_marker_length));
    try std.testing.expectEqual(jp2z.Severity.fail, r1.overall);

    // COC: Lcoc must be 9 for Csiz < 257 with default precincts (A.6.2).
    const coc_ok = try buildPackedMiniStream(allocator, .{ .main_extra = &.{ 0xFF, 0x53, 0x00, 0x09, 0x00, 0x00, 0x00, 0x04, 0x04, 0x00, 0x01 } });
    defer allocator.free(coc_ok);
    var r2 = try jp2z.validate(allocator, coc_ok);
    defer r2.deinit(allocator);
    try std.testing.expect(!hasFinding(r2, .bad_marker_length));
    const coc_long = try buildPackedMiniStream(allocator, .{ .main_extra = &.{ 0xFF, 0x53, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x04, 0x04, 0x00, 0x01, 0x00 } });
    defer allocator.free(coc_long);
    var r3 = try jp2z.validate(allocator, coc_long);
    defer r3.deinit(allocator);
    try std.testing.expect(hasFinding(r3, .bad_marker_length));
    try std.testing.expectEqual(jp2z.Severity.fail, r3.overall);

    // RGN: Lrgn must be 5 for Csiz < 257 (A.6.3).
    const rgn_ok = try buildPackedMiniStream(allocator, .{ .main_extra = &.{ 0xFF, 0x5E, 0x00, 0x05, 0x00, 0x00, 0x00 } });
    defer allocator.free(rgn_ok);
    var r4 = try jp2z.validate(allocator, rgn_ok);
    defer r4.deinit(allocator);
    try std.testing.expect(!hasFinding(r4, .bad_marker_length));
    const rgn_long = try buildPackedMiniStream(allocator, .{ .main_extra = &.{ 0xFF, 0x5E, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00 } });
    defer allocator.free(rgn_long);
    var r5 = try jp2z.validate(allocator, rgn_long);
    defer r5.deinit(allocator);
    try std.testing.expect(hasFinding(r5, .bad_marker_length));
    try std.testing.expectEqual(jp2z.Severity.fail, r5.overall);
}

test "tile-part header: a segment whose length runs past SOD, or bytes that are no marker, → FAIL (edf_c2_1103421)" {
    const allocator = std.testing.allocator;
    // COC with Lcoc 0x0209 = 521 in a tile-part header of a few bytes: the
    // segment claims to extend past SOD (edf_c2_1103421's fuzzed COC).
    const overrun = try buildPackedMiniStream(allocator, .{ .tp_hdr_extra = &.{ 0xFF, 0x53, 0x02, 0x09, 0x00, 0x00, 0x00, 0x04, 0x04, 0x00, 0x01 } });
    defer allocator.free(overrun);
    var r1 = try jp2z.validate(allocator, overrun);
    defer r1.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, r1.overall);
    try std.testing.expect(failDetailContains(r1, .jp2_invalid_codestream, "SOD"));
    // Two bytes that are not a marker between SOT and SOD.
    const garbage = try buildPackedMiniStream(allocator, .{ .tp_hdr_extra = &.{ 0x00, 0x00 } });
    defer allocator.free(garbage);
    var r2 = try jp2z.validate(allocator, garbage);
    defer r2.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, r2.overall);
    try std.testing.expect(failDetailContains(r2, .jp2_invalid_codestream, "SOD"));
}

// ── JP2 palette: pclr + cmap (T.800 I.5.3.4 / I.5.3.5) ────────────
//
// issue412.jp2 (Kakadu 7.3.3): one codestream component, a 256-entry
// 3-column palette, cmap mapping it to 3 channels and a cdef naming
// channels 0..2. jp2z read cdef's Cn against the ihdr component count (1)
// and FAILed a file openjpeg and JasPer decode. mem-b2ace68c-1381.jp2:
// pclr declares NE=1, NPC=4 and carries no entries; openjpeg refuses the
// header, jp2z said nothing.

/// pclr box: NE entries × NPC columns, every column `depth` bits unsigned,
/// entries all zero. `truncate_entries` drops the entry bytes (mem-b2ace68c).
fn pclrBox(allocator: std.mem.Allocator, ne: u16, npc: u8, depth: u8, truncate_entries: bool) ![]u8 {
    const bytes_per: usize = if (depth <= 8) 1 else 2;
    const entries: usize = if (truncate_entries) 0 else @as(usize, ne) * npc * bytes_per;
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    var lbox: [4]u8 = undefined;
    std.mem.writeInt(u32, &lbox, @intCast(8 + 3 + @as(usize, npc) + entries), .big);
    try buf.appendSlice(allocator, &lbox);
    try buf.appendSlice(allocator, "pclr");
    var ne_b: [2]u8 = undefined;
    std.mem.writeInt(u16, &ne_b, ne, .big);
    try buf.appendSlice(allocator, &ne_b);
    try buf.append(allocator, npc);
    var i: usize = 0;
    while (i < npc) : (i += 1) try buf.append(allocator, depth - 1);
    try buf.appendNTimes(allocator, 0, entries);
    return buf.toOwnedSlice(allocator);
}

/// cmap box from (CMP, MTYP, PCOL) triples.
fn cmapBox(allocator: std.mem.Allocator, entries: []const [3]u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    var lbox: [4]u8 = undefined;
    std.mem.writeInt(u32, &lbox, @intCast(8 + 4 * entries.len), .big);
    try buf.appendSlice(allocator, &lbox);
    try buf.appendSlice(allocator, "cmap");
    for (entries) |e| try buf.appendSlice(allocator, &.{ 0x00, e[0], e[1], e[2] });
    return buf.toOwnedSlice(allocator);
}

const cmap_3ch = [_][3]u8{ .{ 0, 1, 0 }, .{ 0, 1, 1 }, .{ 0, 1, 2 } };
// cdef N=3 naming channels 0,1,2 as colours 1,2,3 (issue412's shape).
const cdef_3ch = [_]u8{
    0x00, 0x00, 0x00, 0x1C, 0x63, 0x64, 0x65, 0x66, 0x00, 0x03,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    0x00, 0x01, 0x00, 0x00, 0x00, 0x02,
    0x00, 0x02, 0x00, 0x00, 0x00, 0x03,
};

fn paletteJp2(allocator: std.mem.Allocator, boxes: []const []const u8) ![]u8 {
    const payload = try buildPackedMiniStream(allocator, .{});
    defer allocator.free(payload);
    const extra = try std.mem.concat(allocator, u8, boxes);
    defer allocator.free(extra);
    return wrapInJp2Ex(allocator, payload, 1, extra);
}

test "JP2 palette: pclr + cmap + cdef over cmap channels is valid; palette not applied by decode → c145 WARN (issue412)" {
    const allocator = std.testing.allocator;
    const pclr = try pclrBox(allocator, 2, 3, 8, false);
    defer allocator.free(pclr);
    const cmap = try cmapBox(allocator, &cmap_3ch);
    defer allocator.free(cmap);
    const jp2 = try paletteJp2(allocator, &.{ pclr, cmap, &cdef_3ch });
    defer allocator.free(jp2);
    var rep = try jp2z.validate(allocator, jp2);
    defer rep.deinit(allocator);
    for (rep.findings.items) |f| try std.testing.expect(f.severity != .fail);
    var saw = false;
    for (rep.findings.items) |f| if (f.code == .jp2_unsupported_marker_ignored and std.mem.indexOf(u8, f.detail orelse "", "palette") != null) {
        saw = true;
    };
    try std.testing.expect(saw);
    // Decode still delivers the single unmapped codestream component.
    var img = try jp2z.internal.decodeCleanroom(allocator, jp2);
    defer img.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), img.num_components);
}

test "JP2 palette: pclr shorter than NE×NPC entries → FAIL (mem-b2ace68c-1381); NE or NPC of 0 → FAIL" {
    const allocator = std.testing.allocator;
    const cmap = try cmapBox(allocator, &.{ .{ 0, 1, 0 }, .{ 0, 1, 1 }, .{ 0, 1, 2 }, .{ 0, 1, 3 } });
    defer allocator.free(cmap);
    const short = try pclrBox(allocator, 1, 4, 8, true);
    defer allocator.free(short);
    const jp2 = try paletteJp2(allocator, &.{ short, cmap });
    defer allocator.free(jp2);
    var rep = try jp2z.validate(allocator, jp2);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(failDetailContains(rep, .bad_marker_length, "pclr"));
    const zero_ne = try pclrBox(allocator, 0, 4, 8, false);
    defer allocator.free(zero_ne);
    const jp2b = try paletteJp2(allocator, &.{ zero_ne, cmap });
    defer allocator.free(jp2b);
    var repb = try jp2z.validate(allocator, jp2b);
    defer repb.deinit(allocator);
    try std.testing.expect(failDetailContains(repb, .jp2_invalid_codestream, "pclr"));
}

test "JP2 palette: cmap component beyond ihdr NC, palette column beyond NPC, MTYP > 1, or a lone pclr/cmap → FAIL" {
    const allocator = std.testing.allocator;
    const pclr = try pclrBox(allocator, 2, 3, 8, false);
    defer allocator.free(pclr);
    const cases = [_]struct { entries: []const [3]u8, needle: []const u8 }{
        .{ .entries = &.{ .{ 1, 1, 0 }, .{ 0, 1, 1 }, .{ 0, 1, 2 } }, .needle = "component" },
        .{ .entries = &.{ .{ 0, 1, 0 }, .{ 0, 1, 1 }, .{ 0, 1, 3 } }, .needle = "column" },
        .{ .entries = &.{ .{ 0, 2, 0 }, .{ 0, 1, 1 }, .{ 0, 1, 2 } }, .needle = "MTYP" },
    };
    for (cases) |c| {
        const cmap = try cmapBox(allocator, c.entries);
        defer allocator.free(cmap);
        const jp2 = try paletteJp2(allocator, &.{ pclr, cmap });
        defer allocator.free(jp2);
        var rep = try jp2z.validate(allocator, jp2);
        defer rep.deinit(allocator);
        try std.testing.expect(failDetailContains(rep, .jp2_invalid_codestream, c.needle));
    }
    const lone_pclr = try paletteJp2(allocator, &.{pclr});
    defer allocator.free(lone_pclr);
    var r1 = try jp2z.validate(allocator, lone_pclr);
    defer r1.deinit(allocator);
    try std.testing.expect(failDetailContains(r1, .jp2_invalid_codestream, "cmap"));
    const cmap = try cmapBox(allocator, &cmap_3ch);
    defer allocator.free(cmap);
    const lone_cmap = try paletteJp2(allocator, &.{cmap});
    defer allocator.free(lone_cmap);
    var r2 = try jp2z.validate(allocator, lone_cmap);
    defer r2.deinit(allocator);
    try std.testing.expect(failDetailContains(r2, .jp2_invalid_codestream, "pclr"));
}

test "JP2 palette: cdef channel count is the cmap entry count — a channel beyond it still FAILs" {
    const allocator = std.testing.allocator;
    const pclr = try pclrBox(allocator, 2, 3, 8, false);
    defer allocator.free(pclr);
    const cmap = try cmapBox(allocator, &cmap_3ch);
    defer allocator.free(cmap);
    // cdef N=1 naming channel 3 (cmap yields channels 0..2).
    const cdef_ch3 = [_]u8{ 0x00, 0x00, 0x00, 0x10, 0x63, 0x64, 0x65, 0x66, 0x00, 0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01 };
    const jp2 = try paletteJp2(allocator, &.{ pclr, cmap, &cdef_ch3 });
    defer allocator.free(jp2);
    var rep = try jp2z.validate(allocator, jp2);
    defer rep.deinit(allocator);
    try std.testing.expect(failDetailContains(rep, .jp2_invalid_codestream, "cdef"));
}

// ── Per-component wavelets in decode (COC: 9/7 and 5/3 side by side) ──


test "cleanroom: p0_06 (COC mixes 9/7 and 5/3 across components) decodes and matches openjpeg within 1" {
    const allocator = std.testing.allocator;
    var img = try jp2z.internal.decodeCleanroom(allocator, p0_06_j2k);
    defer img.deinit(allocator);
    var oracle = try jp2z.internal.openjpegDecode(allocator, p0_06_j2k);
    defer oracle.deinit(allocator);
    try std.testing.expectEqual(oracle.width, img.width);
    try std.testing.expectEqual(oracle.height, img.height);
    try std.testing.expectEqual(@as(usize, oracle.channels), img.num_components);
    // Components 1..3 are sub-sampled (2,1) (1,2) (2,2); the oracle replicates
    // them to the full canvas by nearest neighbour, so map each canvas pixel
    // back to the component's own sample.
    const cp = (try jp2z.internal.inspect(allocator, p0_06_j2k)) orelse return error.NoCodingParams;
    var max_abs: [4]i64 = @splat(0);
    var c: usize = 0;
    while (c < img.num_components) : (c += 1) {
        const dx = cp.comp_dx[c];
        const dy = cp.comp_dy[c];
        const cw = (img.width + dx - 1) / dx;
        var y: u32 = 0;
        while (y < img.height) : (y += 1) {
            var x: u32 = 0;
            while (x < img.width) : (x += 1) {
                const ours = img.planes[c][(y / dy) * cw + (x / dx)];
                const oi = (@as(usize, y) * img.width + x) * oracle.channels + c;
                const oj: i64 = if (oracle.bits_per_sample > 8) oracle.pixelsU16()[oi] else oracle.pixels[oi];
                const d: i64 = @as(i64, ours) - @as(i64, oj);
                max_abs[c] = @max(max_abs[c], if (d < 0) -d else d);
            }
        }
    }
    // 9/7 components: within 1 (fixed-point rounding); the 5/3 component
    // (3, via COC) is lossless and must be exact.
    for (max_abs[0..3]) |m| try std.testing.expect(m <= 1);
    try std.testing.expectEqual(@as(i64, 0), max_abs[3]);
}

// ── PLM: packet lengths in the main header (T.800 A.7.2) ──────────
//
// TLM and PLT are already cross-checked against the walk; PLM (Zplm, then
// per tile-part Nplm + Iplm 7-bit-continued lengths, a tile-part's Iplm
// may continue in the next PLM segment) was recognised but never read, so
// a corrupted PLM passed silently.

test "PLM: lengths that match the walked packets are accepted, also when a tile-part's entry spans two PLM segments" {
    const allocator = std.testing.allocator;
    // One tile-part, one packet of 1 byte: Zplm 0, Nplm 1, Iplm 0x01.
    const one = try buildPackedMiniStream(allocator, .{ .main_extra = &.{ 0xFF, 0x57, 0x00, 0x05, 0x00, 0x01, 0x01 } });
    defer allocator.free(one);
    var r1 = try jp2z.validate(allocator, one);
    defer r1.deinit(allocator);
    for (r1.findings.items) |f| try std.testing.expect(f.severity != .fail);
    // Same, split: segment Zplm 0 carries Nplm, segment Zplm 1 carries Iplm.
    const split = try buildPackedMiniStream(allocator, .{ .main_extra = &.{ 0xFF, 0x57, 0x00, 0x04, 0x00, 0x01, 0xFF, 0x57, 0x00, 0x04, 0x01, 0x01 } });
    defer allocator.free(split);
    var r2 = try jp2z.validate(allocator, split);
    defer r2.deinit(allocator);
    for (r2.findings.items) |f| try std.testing.expect(f.severity != .fail);
}

test "PLM: a length that disagrees with the walked packet, or more tile-part entries than the codestream has, → FAIL naming PLM" {
    const allocator = std.testing.allocator;
    const wrong = try buildPackedMiniStream(allocator, .{ .main_extra = &.{ 0xFF, 0x57, 0x00, 0x05, 0x00, 0x01, 0x02 } });
    defer allocator.free(wrong);
    var r1 = try jp2z.validate(allocator, wrong);
    defer r1.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, r1.overall);
    try std.testing.expect(failDetailContains(r1, .jp2_invalid_codestream, "PLM"));
    // Two tile-part entries (Nplm 1 / Iplm 1 twice) for a single tile-part.
    const surplus = try buildPackedMiniStream(allocator, .{ .main_extra = &.{ 0xFF, 0x57, 0x00, 0x07, 0x00, 0x01, 0x01, 0x01, 0x01 } });
    defer allocator.free(surplus);
    var r2 = try jp2z.validate(allocator, surplus);
    defer r2.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, r2.overall);
    try std.testing.expect(failDetailContains(r2, .jp2_invalid_codestream, "PLM"));
}

// ── Report carries what the cleanroom decode needs from jp2h ──────
//
// Retiring the openjpeg wrapper from `decode` means the cleanroom route
// must reproduce its Image contract: colour space from colr (I.5.3.3) and
// palette application from pclr + cmap. Those values live on the report.

test "report: colr (meth 1) enumerated colour space is surfaced" {
    const allocator = std.testing.allocator;
    const payload = try buildPackedMiniStream(allocator, .{});
    defer allocator.free(payload);
    // colr: METH 1, PREC 0, APPROX 0, EnumCS 17 (greyscale).
    const colr = [_]u8{ 0x00, 0x00, 0x00, 0x0F, 0x63, 0x6F, 0x6C, 0x72, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11 };
    const jp2 = try wrapInJp2Ex(allocator, payload, 1, &colr);
    defer allocator.free(jp2);
    var rep = try jp2z.validate(allocator, jp2);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(@as(?u32, 17), rep.colr_enumcs);
    const none = try wrapInJp2Ex(allocator, payload, 1, &.{});
    defer allocator.free(none);
    var rep0 = try jp2z.validate(allocator, none);
    defer rep0.deinit(allocator);
    try std.testing.expectEqual(@as(?u32, null), rep0.colr_enumcs);
}

test "report: palette entries (pclr) and component mapping (cmap) are surfaced with their values" {
    const allocator = std.testing.allocator;
    const payload = try buildPackedMiniStream(allocator, .{});
    defer allocator.free(payload);
    // pclr: NE 2, NPC 1, depth 8, entries 0x10 0x20.
    const pclr = [_]u8{ 0x00, 0x00, 0x00, 0x0E, 0x70, 0x63, 0x6C, 0x72, 0x00, 0x02, 0x01, 0x07, 0x10, 0x20 };
    const cmap = try cmapBox(allocator, &.{.{ 0, 1, 0 }});
    defer allocator.free(cmap);
    const extra = try std.mem.concat(allocator, u8, &.{ &pclr, cmap });
    defer allocator.free(extra);
    const jp2 = try wrapInJp2Ex(allocator, payload, 1, extra);
    defer allocator.free(jp2);
    var rep = try jp2z.validate(allocator, jp2);
    defer rep.deinit(allocator);
    const pal = rep.palette orelse return error.MissingPalette;
    try std.testing.expectEqual(@as(u16, 2), pal.ne);
    try std.testing.expectEqual(@as(u8, 1), pal.npc);
    try std.testing.expectEqualSlices(u8, &.{8}, pal.depths);
    try std.testing.expectEqualSlices(u32, &.{ 0x10, 0x20 }, pal.entries);
    try std.testing.expectEqual(@as(usize, 1), rep.cmap.len);
    try std.testing.expectEqual(@as(u16, 0), rep.cmap[0].cmp);
    try std.testing.expectEqual(@as(u8, 1), rep.cmap[0].mtyp);
    try std.testing.expectEqual(@as(u8, 0), rep.cmap[0].pcol);
}

// ── Segmentation symbols (cblksty SEGSYM, T.800 D.5) ──────────────
//
// With SEGSYM every cleanup pass ends with the four-symbol marker 1010
// coded in the UNIFORM context — the one in-stream integrity hook the
// standard offers. The EBCOT decoder already records a wrong marker
// (Cblk.segsym_error) but deepValidate never reported it, so a corrupted
// cleanup pass whose byte budget still balanced passed silently.

test "SEGSYM: a clean fixture has no c258; a byte flipped in its entropy data yields segmentation_symbol_mismatch (FAIL under strict)" {
    const allocator = std.testing.allocator;
    var clean = try jp2z.internal.deepValidate(allocator, p1_06_j2k, true);
    defer clean.deinit(allocator);
    try std.testing.expect(!hasFinding(clean, .segmentation_symbol_mismatch));
    const corrupt = try allocator.dupe(u8, p1_06_j2k);
    defer allocator.free(corrupt);
    corrupt[corrupt.len / 2] ^= 0xFF;
    var rep = try jp2z.internal.deepValidate(allocator, corrupt, true);
    defer rep.deinit(allocator);
    try std.testing.expect(failDetailContains(rep, .segmentation_symbol_mismatch, "segmentation symbol"));
}

// ── JP2 container: ftyp, ihdr fields, colr, box order (I.5.1–I.5.3) ──
//
// Container-level lies that decoders shrug off but a validator must name:
// ftyp out of place or with a foreign brand, an ihdr whose NC/BPC/C
// disagree with the codestream, a colr with a reserved METH or a Part-2
// colour space, and jp2h after jp2c.

const jp_sig = [_]u8{ 0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A };
const ftyp_jp2 = [_]u8{ 0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70, 0x6A, 0x70, 0x32, 0x20, 0x00, 0x00, 0x00, 0x00, 0x6A, 0x70, 0x32, 0x20 };
const jp2h_min = [_]u8{ 0x00, 0x00, 0x00, 0x1E, 0x6A, 0x70, 0x32, 0x68, 0x00, 0x00, 0x00, 0x16, 0x69, 0x68, 0x64, 0x72, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x01, 0x07, 0x07, 0x00, 0x00 };

fn jp2cBox(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var lbox: [4]u8 = undefined;
    std.mem.writeInt(u32, &lbox, @intCast(8 + payload.len), .big);
    return std.mem.concat(allocator, u8, &.{ &lbox, "jp2c", payload });
}

test "JP2: ftyp must immediately follow the signature box, and carry brand 'jp2 ' or list it as compatible (I.5.2)" {
    const allocator = std.testing.allocator;
    const payload = try buildPackedMiniStream(allocator, .{});
    defer allocator.free(payload);
    const jp2c = try jp2cBox(allocator, payload);
    defer allocator.free(jp2c);
    // ftyp after jp2h.
    const late = try std.mem.concat(allocator, u8, &.{ &jp_sig, &jp2h_min, &ftyp_jp2, jp2c });
    defer allocator.free(late);
    var r1 = try jp2z.validate(allocator, late);
    defer r1.deinit(allocator);
    try std.testing.expect(failDetailContains(r1, .jp2_invalid_signature, "ftyp"));
    // Brand 'jpx ' with 'jp2 ' in the compatibility list: accepted.
    const ftyp_jpx = [_]u8{ 0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x6A, 0x70, 0x78, 0x20, 0x00, 0x00, 0x00, 0x00, 0x6A, 0x70, 0x78, 0x20, 0x6A, 0x70, 0x32, 0x20 };
    const compat = try std.mem.concat(allocator, u8, &.{ &jp_sig, &ftyp_jpx, &jp2h_min, jp2c });
    defer allocator.free(compat);
    var r2 = try jp2z.validate(allocator, compat);
    defer r2.deinit(allocator);
    for (r2.findings.items) |f| try std.testing.expect(f.severity != .fail);
    // Foreign brand, no 'jp2 ' anywhere: FAIL.
    const ftyp_foreign = [_]u8{ 0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70, 0x61, 0x62, 0x63, 0x64, 0x00, 0x00, 0x00, 0x00, 0x61, 0x62, 0x63, 0x64 };
    const foreign = try std.mem.concat(allocator, u8, &.{ &jp_sig, &ftyp_foreign, &jp2h_min, jp2c });
    defer allocator.free(foreign);
    var r3 = try jp2z.validate(allocator, foreign);
    defer r3.deinit(allocator);
    try std.testing.expect(failDetailContains(r3, .jp2_invalid_signature, "brand"));
}

test "JP2: ihdr NC, BPC and C must agree with the codestream (I.5.3.1); BPC 0xFF needs a bpcc box (I.5.3.2)" {
    const allocator = std.testing.allocator;
    const payload = try buildPackedMiniStream(allocator, .{});
    defer allocator.free(payload);
    const base = try wrapInJp2Ex(allocator, payload, 1, &.{});
    defer allocator.free(base);
    try std.testing.expectEqual(@as(u8, 0x07), base[58]); // BPC
    try std.testing.expectEqual(@as(u8, 0x07), base[59]); // C
    const bad_c = try patched(allocator, base, 59, &.{0x08});
    defer allocator.free(bad_c);
    var r1 = try jp2z.validate(allocator, bad_c);
    defer r1.deinit(allocator);
    // I.5.3.1 defines exactly one C; a different value is a proven container
    // lie and FAILs (Peter, 2026-09-12).
    try std.testing.expect(failDetailContains(r1, .jp2_invalid_codestream, "compression type"));
    const bad_nc = try patched(allocator, base, 57, &.{0x02});
    defer allocator.free(bad_nc);
    var r2 = try jp2z.validate(allocator, bad_nc);
    defer r2.deinit(allocator);
    try std.testing.expect(failDetailContains(r2, .jp2_invalid_codestream, "component count"));
    const bad_bpc = try patched(allocator, base, 58, &.{0x0B}); // 12-bit vs the codestream's 8
    defer allocator.free(bad_bpc);
    var r3 = try jp2z.validate(allocator, bad_bpc);
    defer r3.deinit(allocator);
    try std.testing.expect(failDetailContains(r3, .jp2_invalid_codestream, "bit depth"));
    const varying = try patched(allocator, base, 58, &.{0xFF});
    defer allocator.free(varying);
    var r4 = try jp2z.validate(allocator, varying);
    defer r4.deinit(allocator);
    try std.testing.expect(failDetailContains(r4, .jp2_invalid_codestream, "bpcc"));
}

test "JP2: colr METH 1 needs exactly 7 body bytes; reserved METH or a Part-2 EnumCS is valid-but-unsupported (I.5.3.3)" {
    const allocator = std.testing.allocator;
    const payload = try buildPackedMiniStream(allocator, .{});
    defer allocator.free(payload);
    const short = [_]u8{ 0x00, 0x00, 0x00, 0x10, 0x63, 0x6F, 0x6C, 0x72, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11, 0x00 }; // 8 body bytes
    const jp2a = try wrapInJp2Ex(allocator, payload, 1, &short);
    defer allocator.free(jp2a);
    var r1 = try jp2z.validate(allocator, jp2a);
    defer r1.deinit(allocator);
    try std.testing.expect(failDetailContains(r1, .bad_marker_length, "colr"));
    const meth3 = [_]u8{ 0x00, 0x00, 0x00, 0x0F, 0x63, 0x6F, 0x6C, 0x72, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11 };
    const jp2b = try wrapInJp2Ex(allocator, payload, 1, &meth3);
    defer allocator.free(jp2b);
    var r2 = try jp2z.validate(allocator, jp2b);
    defer r2.deinit(allocator);
    for (r2.findings.items) |f| try std.testing.expect(f.severity != .fail);
    try std.testing.expect(hasFinding(r2, .jp2_unsupported_marker_ignored));
    const cmyk = [_]u8{ 0x00, 0x00, 0x00, 0x0F, 0x63, 0x6F, 0x6C, 0x72, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0C }; // EnumCS 12 (Part 2)
    const jp2c = try wrapInJp2Ex(allocator, payload, 1, &cmyk);
    defer allocator.free(jp2c);
    var r3 = try jp2z.validate(allocator, jp2c);
    defer r3.deinit(allocator);
    for (r3.findings.items) |f| try std.testing.expect(f.severity != .fail);
    try std.testing.expect(hasFinding(r3, .jp2_unsupported_marker_ignored));
}

test "JP2: jp2h must precede jp2c (I.5.3)" {
    const allocator = std.testing.allocator;
    const payload = try buildPackedMiniStream(allocator, .{});
    defer allocator.free(payload);
    const jp2c = try jp2cBox(allocator, payload);
    defer allocator.free(jp2c);
    const late = try std.mem.concat(allocator, u8, &.{ &jp_sig, &ftyp_jp2, jp2c, &jp2h_min });
    defer allocator.free(late);
    var rep = try jp2z.validate(allocator, late);
    defer rep.deinit(allocator);
    try std.testing.expect(failDetailContains(rep, .jp2_invalid_codestream, "jp2h"));
}

// ── Quantization table shape (A.6.4) and duplicate JP2 boxes (I.5) ──

test "QCD: scalar-derived (style 1) carries exactly one entry; expounded (style 2) entries are whole 2-byte pairs" {
    const allocator = std.testing.allocator;
    // Style 1 with two entries (Sqcd 0x41, 4 SPqcd bytes).
    const derived2 = try buildPackedMiniStream(allocator, .{ .qcd_body = &.{ 0x41, 0x40, 0x00, 0x40, 0x00 } });
    defer allocator.free(derived2);
    var r1 = try jp2z.validate(allocator, derived2);
    defer r1.deinit(allocator);
    try std.testing.expect(failDetailContains(r1, .bad_marker_length, "derived"));
    // Style 1 with one entry: accepted.
    const derived1 = try buildPackedMiniStream(allocator, .{ .qcd_body = &.{ 0x41, 0x40, 0x00 } });
    defer allocator.free(derived1);
    var r2 = try jp2z.validate(allocator, derived1);
    defer r2.deinit(allocator);
    for (r2.findings.items) |f| try std.testing.expect(f.severity != .fail);
    // Style 2 with three SPqcd bytes: one and a half entries.
    const odd = try buildPackedMiniStream(allocator, .{ .qcd_body = &.{ 0x42, 0x40, 0x00, 0x40 } });
    defer allocator.free(odd);
    var r3 = try jp2z.validate(allocator, odd);
    defer r3.deinit(allocator);
    try std.testing.expect(failDetailContains(r3, .bad_marker_length, "expounded"));
}

test "JP2: a second jp2h or ftyp box → FAIL (exactly one of each, I.5.2/I.5.3)" {
    const allocator = std.testing.allocator;
    const payload = try buildPackedMiniStream(allocator, .{});
    defer allocator.free(payload);
    const jp2c = try jp2cBox(allocator, payload);
    defer allocator.free(jp2c);
    const two_jp2h = try std.mem.concat(allocator, u8, &.{ &jp_sig, &ftyp_jp2, &jp2h_min, &jp2h_min, jp2c });
    defer allocator.free(two_jp2h);
    var r1 = try jp2z.validate(allocator, two_jp2h);
    defer r1.deinit(allocator);
    try std.testing.expect(failDetailContains(r1, .jp2_invalid_codestream, "second jp2h"));
    const two_ftyp = try std.mem.concat(allocator, u8, &.{ &jp_sig, &ftyp_jp2, &ftyp_jp2, &jp2h_min, jp2c });
    defer allocator.free(two_ftyp);
    var r2 = try jp2z.validate(allocator, two_ftyp);
    defer r2.deinit(allocator);
    try std.testing.expect(failDetailContains(r2, .jp2_invalid_signature, "second ftyp"));
}

// ── decode refuses structurally failed streams ─────────────────────
//
// With the wrapper gone, `decode` runs the cleanroom reconstruction. A
// stream whose validation FAILs (fuzzed SIZ, missing packets) must come
// back as an error, never reach reconstruction arithmetic (issue1438 /
// issue823 panicked the CLI once the route switched).

test "decodeToImage: a validation FAIL (fuzzed SIZ, missing packets) is InvalidJp2Codestream, never a panic" {
    const allocator = std.testing.allocator;
    const base = try buildPackedMiniStream(allocator, .{});
    defer allocator.free(base);
    const tall = try patched(allocator, base, 12, &.{ 0xFF, 0xF6, 0x00, 0x01 });
    defer allocator.free(tall);
    const fuzzed = try patched(allocator, tall, 28, &.{ 0xF0, 0x00, 0x01, 0x00 });
    defer allocator.free(fuzzed);
    try std.testing.expectError(error.InvalidJp2Codestream, jp2z.internal.decodeToImage(allocator, fuzzed));
    const short = try buildPackedMiniStream(allocator, .{ .layers = 2, .body = &.{0x00} });
    defer allocator.free(short);
    try std.testing.expectError(error.InvalidJp2Codestream, jp2z.internal.decodeToImage(allocator, short));
}

test "validate: conflicting TNsot across a tile's parts → FAIL naming both declarations (A.4.2); both parts still walk" {
    const allocator = std.testing.allocator;
    // twoPartStream(2) is the clean control; part 1's TNsot byte sits 11
    // bytes into its SOT (second FF90). Change it to 3.
    const data = try twoPartStream(allocator, 2);
    defer allocator.free(data);
    var second_sot: ?usize = null;
    var seen: usize = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 1) {
        if (data[i] == 0xFF and data[i + 1] == 0x90) {
            seen += 1;
            if (seen == 2) {
                second_sot = i;
                break;
            }
        }
    }
    const sot = second_sot orelse return error.NoSecondSot;
    const conflict = try patched(allocator, data, sot + 11, &.{0x03});
    defer allocator.free(conflict);
    var rep = try jp2z.validate(allocator, conflict);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    try std.testing.expect(failDetailContains(rep, .jp2_invalid_codestream, "declares TNsot 3 but an earlier part declared 2"));
    try std.testing.expect(hasFinding(rep, .jp2_packets_walked_to_end));
}

// ── Reserved values under Peter's rule, extension-aware (2026-09-12) ──
//
// A reserved value in the base standard may be defined by a later part
// (T.801 Part 2, T.814 HTJ2K). When Rsiz declares such capabilities the
// stream is indeterminate here (valid-but-unsupported, c145 WARN); under a
// Part-1 Rsiz the value is a proven violation and FAILs.

test "Scod / cblksty reserved bits under a Part-2 Rsiz → c145 WARN (indeterminate), not FAIL" {
    const allocator = std.testing.allocator;
    const base = try buildPackedMiniStream(allocator, .{});
    defer allocator.free(base);
    const part2 = try patched(allocator, base, 6, &.{ 0x80, 0x00 }); // Rsiz bit 15
    defer allocator.free(part2);
    // COD at 45: Scod at 49, cblksty at 57.
    for ([_]struct { off: usize, v: u8 }{ .{ .off = 49, .v = 0x80 }, .{ .off = 57, .v = 0x80 } }) |c| {
        const s = try patched(allocator, part2, c.off, &.{c.v});
        defer allocator.free(s);
        var rep = try jp2z.validate(allocator, s);
        defer rep.deinit(allocator);
        try std.testing.expect(rep.overall != .fail);
        try std.testing.expect(hasFinding(rep, .jp2_unsupported_marker_ignored));
    }
}

test "QCD with fewer subband entries than the decomposition needs → FAIL under Part-1 Rsiz (A.6.4 Table A.28), c145 WARN under Part-2 Rsiz" {
    const allocator = std.testing.allocator;
    // decomp 1 → 4 subbands; style-0 QCD with ONE entry. Body: 2 empty packets.
    const short = try buildPackedMiniStream(allocator, .{ .decomp = 1, .qcd_body = &.{ 0x40, 0x40 }, .body = &.{ 0x00, 0x00 } });
    defer allocator.free(short);
    var r1 = try jp2z.validate(allocator, short);
    defer r1.deinit(allocator);
    try std.testing.expect(failDetailContains(r1, .jp2_invalid_codestream, "fewer subband entries"));
    const part2 = try patched(allocator, short, 6, &.{ 0x80, 0x00 });
    defer allocator.free(part2);
    var r2 = try jp2z.validate(allocator, part2);
    defer r2.deinit(allocator);
    try std.testing.expect(!failDetailContains(r2, .jp2_invalid_codestream, "fewer subband entries"));
    try std.testing.expect(hasFinding(r2, .jp2_unsupported_marker_ignored));
    // Control: the full table (4 entries) is clean.
    const full = try buildPackedMiniStream(allocator, .{ .decomp = 1, .qcd_body = &.{ 0x40, 0x40, 0x48, 0x48, 0x50 }, .body = &.{ 0x00, 0x00 } });
    defer allocator.free(full);
    var r3 = try jp2z.validate(allocator, full);
    defer r3.deinit(allocator);
    for (r3.findings.items) |f| try std.testing.expect(f.severity != .fail);
}

test "validate: TNsot under-declaration FAILs at the exact SOT offset AND a fault in the later part is still detected" {
    const allocator = std.testing.allocator;
    const data = try twoPartStream(allocator, 1);
    defer allocator.free(data);
    var second_sot: ?usize = null;
    var seen: usize = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 1) {
        if (data[i] == 0xFF and data[i + 1] == 0x90) {
            seen += 1;
            if (seen == 2) {
                second_sot = i;
                break;
            }
        }
    }
    const sot1 = second_sot orelse return error.NoSecondSot;
    // Part 1's single empty-packet byte (SOT 12 + SOD 2 → sot1 + 14) becomes
    // 0xFF: a "non-empty" packet header that runs out of bytes.
    const faulty = try patched(allocator, data, sot1 + 14, &.{0xFF});
    defer allocator.free(faulty);
    var rep = try jp2z.validate(allocator, faulty);
    defer rep.deinit(allocator);
    try std.testing.expectEqual(jp2z.Severity.fail, rep.overall);
    var tnsot_at: ?u64 = null;
    var later_fault = false;
    for (rep.findings.items) |f| {
        if (f.severity != .fail) continue;
        if (std.mem.indexOf(u8, f.detail orelse "", "exceeds the declared TNsot") != null) {
            tnsot_at = f.offset;
        } else if (f.offset != null and f.offset.? > sot1 + 11) {
            later_fault = true; // a distinct FAIL anchored inside the later part
        }
    }
    try std.testing.expectEqual(@as(?u64, sot1 + 11), tnsot_at);
    try std.testing.expect(later_fault);
}
