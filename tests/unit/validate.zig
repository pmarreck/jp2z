//! Cleanroom validator tests — M1 codestream walker.
//!
//! Phase 2 M1 implements `validate()` as a cleanroom marker walker
//! (SOC / SIZ / COD / QCD / SOD / EOC). These tests grow as each
//! marker lands.

const std = @import("std");
const jp2z = @import("jp2z");

const c1_mono_j2c = @embedFile("fixtures/conformance/c1_mono.j2c");
const d1_colr_j2c = @embedFile("fixtures/conformance/d1_colr.j2c");

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
    try std.testing.expectEqual(jp2z.Severity.pass, report.overall);
    try std.testing.expectEqual(@as(usize, 0), report.findings.items.len);
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
    // After M1's tile-part walker lands, the walker should consume
    // every tile-part (using Psot from each SOT to skip the
    // entropy-coded body) and confirm the codestream ends with EOC.
    var report = try jp2z.validate(std.testing.allocator, c1_mono_j2c);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(jp2z.Severity.pass, report.overall);

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
