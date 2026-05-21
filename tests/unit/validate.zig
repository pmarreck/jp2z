//! Cleanroom validator tests — M1 codestream walker.
//!
//! Phase 2 M1 implements `validate()` as a cleanroom marker walker
//! (SOC / SIZ / COD / QCD / SOD / EOC). These tests grow as each
//! marker lands.

const std = @import("std");
const jp2z = @import("jp2z");

const c1_mono_j2c = @embedFile("fixtures/conformance/c1_mono.j2c");
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
