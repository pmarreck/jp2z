//! Cleanroom JPEG 2000 (T.800) codestream marker walker. Phase 2 M1.
//!
//! Walks the J2K main header markers — SOC, SIZ, COD, QCD, ... up to
//! SOT/SOD/EOC — surfacing structural information into a
//! ValidationReport. No entropy decode (that's M3 EBCOT).
//!
//! Marker syntax per T.800 Annex A:
//!   - Marker code: 2 bytes, `FF xx`
//!   - Delimiting markers (SOC, SOD, EOC, EPH) have no length field.
//!   - All other markers are followed by a 2-byte big-endian length
//!     `Lxxx`, where the length value INCLUDES the 2 length bytes
//!     themselves but EXCLUDES the marker code.
//!   - Marker bodies are big-endian.

const std = @import("std");
const Allocator = std.mem.Allocator;
const jp2z = @import("../jp2z.zig");
const errors = @import("../core/errors.zig");

const Severity = errors.Severity;
const Variant = errors.Variant;
const FindingCode = errors.FindingCode;
const Finding = jp2z.Finding;
const ValidationReport = jp2z.ValidationReport;

/// Two-byte marker codes (T.800 Table A.2). Listed here as we wire
/// them; not exhaustive yet.
pub const Marker = enum(u16) {
    soc = 0xFF4F, // Start of Codestream
    sot = 0xFF90, // Start of Tile-part
    sod = 0xFF93, // Start of Data
    eoc = 0xFFD9, // End of Codestream
    siz = 0xFF51, // Image and Tile Size
    cod = 0xFF52, // Coding Style Default
    coc = 0xFF53, // Coding Style Component
    rgn = 0xFF5E, // Region of Interest
    qcd = 0xFF5C, // Quantization Default
    qcc = 0xFF5D, // Quantization Component
    poc = 0xFF5F, // Progression Order Change
    tlm = 0xFF55, // Tile-part Lengths
    plm = 0xFF57, // Packet Length, Main header
    plt = 0xFF58, // Packet Length, Tile-part header
    ppm = 0xFF60, // Packed Packet headers, Main
    ppt = 0xFF61, // Packed Packet headers, Tile-part
    sop = 0xFF91, // Start of Packet
    eph = 0xFF92, // End of Packet Header
    crg = 0xFF63, // Component Registration
    com = 0xFF64, // Comment
    _,
};

/// JP2 box type codes (T.800 Annex I — Table I.2). 4-byte ASCII
/// packed big-endian into a u32 for cheap matching.
const BoxType = struct {
    const sig: u32 = 0x6A502020; // 'jP  '  — JPEG 2000 Signature box
    const ftyp: u32 = 0x66747970; // 'ftyp' — File Type box
    const jp2h: u32 = 0x6A703268; // 'jp2h' — JP2 Header box (container)
    const ihdr: u32 = 0x69686472; // 'ihdr' — Image Header box (in jp2h)
    const colr: u32 = 0x636F6C72; // 'colr' — Colour Specification box
    const jp2c: u32 = 0x6A703263; // 'jp2c' — Contiguous Codestream box
};

/// Validate any JP2 file or J2K raw codestream and return a
/// structured report. Dispatches on magic bytes:
///   - `00 00 00 0C jP  ` → JP2 file format (Annex I box walker)
///   - `FF 4F`            → raw J2K codestream (Annex A marker walker)
///   - anything else      → fail with `missing_soi`
pub fn validate(allocator: Allocator, data: []const u8) Allocator.Error!ValidationReport {
    var report = ValidationReport{
        .overall = .pass,
        .variant = .unknown,
        .width = null,
        .height = null,
        .findings = .empty,
    };
    errdefer report.deinit(allocator);

    // JP2 file format: starts with 12-byte signature box.
    if (looksLikeJp2(data)) {
        try walkJp2(&report, allocator, data);
        return report;
    }

    // J2K raw codestream: SOC magic.
    if (data.len >= 2 and data[0] == 0xFF and data[1] == 0x4F) {
        try walkJ2k(&report, allocator, data);
        return report;
    }

    try emit(&report, allocator, .fail, .missing_soi, 0, null);
    return report;
}

/// Magic-bytes sniff for JP2. T.800 Annex I.5.1: every JP2 file
/// MUST begin with the 12-byte JPEG 2000 Signature box:
///   `00 00 00 0C  jP    0D 0A 87 0A`
/// The trailing 4 bytes are a file-integrity sanity check (CR-LF
/// → DOS-mode mangle → 0xFF byte → LF → 0x0A).
fn looksLikeJp2(data: []const u8) bool {
    if (data.len < 12) return false;
    const lbox = std.mem.readInt(u32, data[0..4], .big);
    const tbox = std.mem.readInt(u32, data[4..8], .big);
    return lbox == 12 and tbox == BoxType.sig;
}

/// Walk a JP2 file's box hierarchy. Validates the required-box set
/// (signature → ftyp → jp2h → jp2c), pulls width/height from the
/// `ihdr` sub-box inside `jp2h`, and recursively validates the
/// embedded codestream inside `jp2c` via the J2K walker.
fn walkJp2(report: *ValidationReport, allocator: Allocator, data: []const u8) Allocator.Error!void {
    report.variant = .jp2_file;

    // Verify the signature box. looksLikeJp2 already checked LBox
    // + TBox; here we also check the 4-byte DBox payload.
    if (data[8] != 0x0D or data[9] != 0x0A or data[10] != 0x87 or data[11] != 0x0A) {
        try emit(report, allocator, .fail, .jp2_invalid_signature, 8, null);
        return;
    }

    var pos: usize = 12;
    var saw_ftyp = false;
    var saw_jp2h = false;
    var saw_jp2c = false;

    while (pos < data.len) {
        if (data.len < pos + 8) {
            try emit(report, allocator, .fail, .truncated_stream, pos, null);
            return;
        }
        const lbox = std.mem.readInt(u32, data[pos..][0..4], .big);
        const tbox = std.mem.readInt(u32, data[pos + 4 ..][0..4], .big);

        var box_total: usize = undefined;
        var body_offset: usize = 8;
        if (lbox == 0) {
            // Box extends to end of file.
            box_total = data.len - pos;
        } else if (lbox == 1) {
            // Extended length: 8-byte XLBox at pos+8.
            if (data.len < pos + 16) {
                try emit(report, allocator, .fail, .truncated_stream, pos, null);
                return;
            }
            const xlbox = std.mem.readInt(u64, data[pos + 8 ..][0..8], .big);
            if (xlbox > std.math.maxInt(usize)) {
                try emit(report, allocator, .fail, .jp2_invalid_codestream, pos + 8, null);
                return;
            }
            box_total = @intCast(xlbox);
            body_offset = 16;
        } else if (lbox >= 8) {
            box_total = lbox;
        } else {
            try emit(report, allocator, .fail, .jp2_invalid_codestream, pos, null);
            return;
        }
        if (box_total < body_offset or @as(u64, pos) + box_total > data.len) {
            try emit(report, allocator, .fail, .truncated_stream, pos, null);
            return;
        }

        const body = data[pos + body_offset .. pos + box_total];

        switch (tbox) {
            BoxType.ftyp => saw_ftyp = true,
            BoxType.jp2h => {
                saw_jp2h = true;
                parseJp2HeaderBox(report, body);
            },
            BoxType.jp2c => {
                saw_jp2c = true;
                try walkJ2k(report, allocator, body);
            },
            else => {}, // unknown / optional boxes — ignore for M1
        }

        pos += box_total;
    }

    if (!saw_ftyp) try emit(report, allocator, .fail, .jp2_invalid_signature, null, null);
    if (!saw_jp2h) try emit(report, allocator, .fail, .jp2_invalid_codestream, null, null);
    if (!saw_jp2c) try emit(report, allocator, .fail, .jp2_invalid_codestream, null, null);
}

/// Walk the sub-boxes inside a `jp2h` container, looking for `ihdr`
/// (Image Header — T.800 Annex I.5.3) to pull width/height. Other
/// sub-boxes (colr, pclr, cmap, cdef, ...) are ignored for M1.
fn parseJp2HeaderBox(report: *ValidationReport, body: []const u8) void {
    var pos: usize = 0;
    while (pos + 8 <= body.len) {
        const lbox = std.mem.readInt(u32, body[pos..][0..4], .big);
        const tbox = std.mem.readInt(u32, body[pos + 4 ..][0..4], .big);
        const box_total: usize = if (lbox == 0)
            body.len - pos
        else if (lbox >= 8)
            lbox
        else
            return; // malformed — caller doesn't enforce here
        if (@as(u64, pos) + box_total > body.len) return;

        if (tbox == BoxType.ihdr and box_total >= 8 + 14) {
            const ihdr_body = body[pos + 8 .. pos + box_total];
            // ihdr layout: HEIGHT(u32) WIDTH(u32) NC(u16) BPC(u8) C(u8) ...
            const height = std.mem.readInt(u32, ihdr_body[0..4], .big);
            const width = std.mem.readInt(u32, ihdr_body[4..8], .big);
            report.height = height;
            report.width = width;
        }

        pos += box_total;
    }
}

/// Walk a J2K raw codestream. M1 scope: walks the main header from
/// SOC through every marker to the first SOT (start of tile-part)
/// or EOC. Parses SIZ for width/height, recognises every known
/// main-header marker (T.800 Table A.2), and emits a `warn`-level
/// finding for any 0xFFxx marker code we don't recognise. Marker
/// *bodies* are skipped (M2+ parses them); we only validate
/// length-field consistency here.
fn walkJ2k(report: *ValidationReport, allocator: Allocator, data: []const u8) Allocator.Error!void {
    // SOC magic check. T.800 A.4.1: every codestream MUST begin with SOC.
    if (data.len < 2 or data[0] != 0xFF or data[1] != 0x4F) {
        try emit(report, allocator, .fail, .missing_soi, 0, null);
        return;
    }
    // Inside a JP2 wrapper this assignment is a no-op (already set
    // to .jp2_file by walkJp2); for raw J2K it's the entry point.
    if (report.variant == .unknown) report.variant = .j2k_codestream;

    // Next marker must be SIZ (T.800 A.4.1). Length-prefixed marker.
    if (data.len < 4) {
        try emit(report, allocator, .fail, .truncated_stream, 2, null);
        return;
    }
    if (data[2] != 0xFF or data[3] != 0x51) {
        try emit(report, allocator, .fail, .bad_marker_length, 2, null);
        return;
    }

    // SIZ length + bounds check, then parse the body.
    if (data.len < 6) {
        try emit(report, allocator, .fail, .truncated_stream, 4, null);
        return;
    }
    const lsiz = std.mem.readInt(u16, data[4..6], .big);
    if (lsiz < 41 or data.len < 4 + lsiz) {
        try emit(report, allocator, .fail, .bad_marker_length, 4, null);
        return;
    }
    parseSizBody(report, data[4 .. 4 + lsiz]);

    // Walk the remaining main-header markers up to SOT/SOD/EOC.
    var pos: usize = 4 + lsiz;
    while (true) {
        if (data.len < pos + 2) {
            try emit(report, allocator, .fail, .truncated_stream, pos, null);
            return;
        }
        if (data[pos] != 0xFF) {
            try emit(report, allocator, .fail, .bad_marker_length, pos, null);
            return;
        }
        const marker: u16 = (@as(u16, 0xFF) << 8) | @as(u16, data[pos + 1]);

        // Delimiting markers — main header ends.
        switch (marker) {
            @intFromEnum(Marker.sot) => {
                // Hand off to the tile-part walker — it consumes
                // every tile-part via Psot and confirms EOC at end.
                try walkTileParts(report, allocator, data, pos);
                return;
            },
            @intFromEnum(Marker.sod), @intFromEnum(Marker.eoc) => {
                // SOD/EOC at the top level (no SOT) — spec-deviant
                // but already structurally validated above.
                return;
            },
            else => {},
        }

        // Every other top-level marker is length-prefixed.
        pos += 2;
        if (data.len < pos + 2) {
            try emit(report, allocator, .fail, .truncated_stream, pos, null);
            return;
        }
        const lxxx = std.mem.readInt(u16, data[pos..][0..2], .big);
        if (lxxx < 2 or data.len < pos + lxxx) {
            try emit(report, allocator, .fail, .truncated_stream, pos, null);
            return;
        }

        if (!isKnownMainHeaderMarker(marker)) {
            try emit(report, allocator, .warn, .unknown_marker, pos - 2, null);
        }

        // Parse body for markers we have field-level validation for.
        // `pos` points to the Lxxx field; body excluding Lxxx starts
        // at pos+2 and ends at pos+lxxx.
        const body = data[pos + 2 .. pos + lxxx];
        switch (marker) {
            @intFromEnum(Marker.cod) => try parseCodBody(report, allocator, body, pos),
            @intFromEnum(Marker.qcd) => try parseQcdBody(report, allocator, body, pos),
            else => {},
        }

        pos += lxxx;
    }
}

/// Walk every tile-part from the given SOT marker offset forward,
/// confirming the codestream terminates with EOC. Uses Psot (from
/// each SOT) to skip the tile-part body without parsing its
/// entropy-coded packet data — that's M3 EBCOT's job.
///
/// T.800 A.4.2 / Table A.5:
///   SOT segment = FF 90 | Lsot(u16=10) | Isot(u16) | Psot(u32) |
///                 TPsot(u8) | TNsot(u8)
///   Psot = byte distance from this SOT to the byte after the last
///          byte of this tile-part (i.e. to the next SOT or EOC).
///          Psot = 0 means "tile-part extends to EOC".
fn walkTileParts(
    report: *ValidationReport,
    allocator: Allocator,
    data: []const u8,
    start: usize,
) Allocator.Error!void {
    var pos: usize = start;
    while (true) {
        // Verify SOT marker at pos.
        if (data.len < pos + 12) {
            try emit(report, allocator, .fail, .truncated_stream, pos, null);
            return;
        }
        if (data[pos] != 0xFF or data[pos + 1] != 0x90) {
            try emit(report, allocator, .fail, .bad_marker_length, pos, null);
            return;
        }
        const lsot = std.mem.readInt(u16, data[pos + 2 ..][0..2], .big);
        if (lsot != 10) {
            try emit(report, allocator, .fail, .bad_marker_length, pos + 2, null);
            return;
        }
        const psot = std.mem.readInt(u32, data[pos + 4 ..][0..4], .big);

        // Determine where this tile-part ends.
        const next_pos: usize = if (psot == 0)
            // Tile-part extends to EOC. We expect EOC as the very
            // last 2 bytes of `data`; the walker doesn't need to
            // scan the entropy-coded packet body for it.
            if (data.len >= 2 and data[data.len - 2] == 0xFF and data[data.len - 1] == 0xD9)
                data.len - 2
            else {
                try emit(report, allocator, .warn, .missing_eoi, pos, null);
                return;
            }
        else if (@as(u64, pos) + psot > data.len) {
            try emit(report, allocator, .fail, .truncated_stream, pos + 4, null);
            return;
        } else pos + psot;

        // What's at next_pos? Should be FF 90 (next tile-part) or
        // FF D9 (EOC). Anything else = warn.
        if (data.len < next_pos + 2) {
            try emit(report, allocator, .warn, .missing_eoi, next_pos, null);
            return;
        }
        if (data[next_pos] == 0xFF and data[next_pos + 1] == 0xD9) {
            // EOC. Tail check: there should be nothing AFTER it.
            if (next_pos + 2 != data.len) {
                try emit(report, allocator, .warn, .truncated_stream, next_pos + 2, null);
            }
            return;
        }
        if (data[next_pos] == 0xFF and data[next_pos + 1] == 0x90) {
            pos = next_pos;
            continue;
        }
        try emit(report, allocator, .warn, .missing_eoi, next_pos, null);
        return;
    }
}

/// Parse a COD (Coding Style Default) marker body. T.800 A.6.1:
///
///   Scod   u8   coding style flags (bit 0 = SOP, bit 1 = EPH, …)
///   SGcod  5 bytes  (progression order, num_layers, MCT)
///   SPcod  ≥5 bytes (decomp, cblkw, cblkh, cblksty, qmfbid, ...)
///
/// Minimum body length (excluding Lcod): 10 bytes.
fn parseCodBody(
    report: *ValidationReport,
    allocator: Allocator,
    body: []const u8,
    offset: usize,
) Allocator.Error!void {
    if (body.len < 10) {
        try emit(report, allocator, .fail, .bad_marker_length, offset, null);
        return;
    }
    // SGcod
    const prog_order = body[1];
    if (prog_order > 4) {
        try emit(report, allocator, .warn, .jp2_bad_progression_order, offset + 1, null);
    }
    const mct = body[4];
    if (mct > 1) {
        try emit(report, allocator, .warn, .jp2_invalid_codestream, offset + 4, null);
    }
    // SPcod
    const decomp_levels = body[5];
    if (decomp_levels > 32) {
        try emit(report, allocator, .warn, .jp2_invalid_codestream, offset + 5, null);
    }
    const cblkw_exp = body[6];
    const cblkh_exp = body[7];
    // Code-block dimension exponent: 0..8 maps to actual size 4..256.
    if (cblkw_exp > 8 or cblkh_exp > 8) {
        try emit(report, allocator, .warn, .jp2_invalid_codestream, offset + 6, null);
    }
    // qmfbid: 0 = 9/7 irreversible (lossy), 1 = 5/3 reversible (lossless).
    const qmfbid = body[9];
    switch (qmfbid) {
        0 => try emit(report, allocator, .info, .jp2_uses_9x7_wavelet, offset + 9, null),
        1 => try emit(report, allocator, .info, .jp2_uses_5x3_wavelet, offset + 9, null),
        else => try emit(report, allocator, .warn, .jp2_invalid_codestream, offset + 9, null),
    }
}

/// Parse a QCD (Quantization Default) marker body. T.800 A.6.4:
///
///   Sqcd   u8   high 3 bits = guard bits (0..7),
///               low 5 bits  = quantization style (0..2 valid)
///   SPqcd  variable per quant style
///
/// Minimum body length (excluding Lqcd): 1 byte (Sqcd alone).
fn parseQcdBody(
    report: *ValidationReport,
    allocator: Allocator,
    body: []const u8,
    offset: usize,
) Allocator.Error!void {
    if (body.len < 1) {
        try emit(report, allocator, .fail, .bad_marker_length, offset, null);
        return;
    }
    const sqcd = body[0];
    const quant_style: u8 = sqcd & 0x1F;
    if (quant_style > 2) {
        try emit(report, allocator, .warn, .jp2_invalid_codestream, offset, null);
    }
}

fn isKnownMainHeaderMarker(marker: u16) bool {
    return switch (marker) {
        @intFromEnum(Marker.siz),
        @intFromEnum(Marker.cod),
        @intFromEnum(Marker.coc),
        @intFromEnum(Marker.qcd),
        @intFromEnum(Marker.qcc),
        @intFromEnum(Marker.rgn),
        @intFromEnum(Marker.poc),
        @intFromEnum(Marker.tlm),
        @intFromEnum(Marker.plm),
        @intFromEnum(Marker.ppm),
        @intFromEnum(Marker.crg),
        @intFromEnum(Marker.com),
        => true,
        else => false,
    };
}

/// Parse the SIZ marker body (the slice from Lsiz through the last
/// per-component descriptor). Caller has already verified
/// `body.len >= Lsiz` and `Lsiz >= 41`.
///
/// T.800 A.5.1 layout (offsets relative to body):
///   0  Lsiz   u16
///   2  Rsiz   u16  capabilities (Part 1 = 0)
///   4  Xsiz   u32  reference grid width
///   8  Ysiz   u32  reference grid height
///   12 XOsiz  u32  image origin X
///   16 YOsiz  u32  image origin Y
///   20 XTsiz  u32  tile width
///   24 YTsiz  u32  tile height
///   28 XTOsiz u32  tile origin X
///   32 YTOsiz u32  tile origin Y
///   36 Csiz   u16  component count
///   38 ...    3·Csiz bytes of component descriptors
fn parseSizBody(report: *ValidationReport, body: []const u8) void {
    const xsiz = std.mem.readInt(u32, body[4..8], .big);
    const ysiz = std.mem.readInt(u32, body[8..12], .big);
    const xosiz = std.mem.readInt(u32, body[12..16], .big);
    const yosiz = std.mem.readInt(u32, body[16..20], .big);

    if (xsiz <= xosiz or ysiz <= yosiz) return; // leave width/height null
    report.width = xsiz - xosiz;
    report.height = ysiz - yosiz;
}

fn emit(
    report: *ValidationReport,
    allocator: Allocator,
    severity: Severity,
    code: FindingCode,
    offset: ?u64,
    detail: ?[]const u8,
) Allocator.Error!void {
    const stored: ?[]const u8 = if (detail) |d| try allocator.dupe(u8, d) else null;
    errdefer if (stored) |s| allocator.free(s);
    try report.findings.append(allocator, .{
        .severity = severity,
        .code = code,
        .offset = offset,
        .detail = stored,
    });
    // Propagate severity upward (fail > warn > info > pass).
    if (@intFromEnum(severity) > @intFromEnum(report.overall)) {
        report.overall = severity;
    }
}

test "parseSizBody: 41-byte minimum SIZ yields width/height" {
    // Hand-built minimal SIZ body (matches c1_mono.j2c bytes 4..45).
    // Lsiz=0x29, Rsiz=0, Xsiz=303, Ysiz=179, all origins 0,
    // tile=303x179 (one tile), Csiz=1, Ssiz=0x07, XRsiz=1, YRsiz=1.
    const body = [_]u8{
        0x00, 0x29, // Lsiz
        0x00, 0x00, // Rsiz
        0x00, 0x00, 0x01, 0x2F, // Xsiz = 303
        0x00, 0x00, 0x00, 0xB3, // Ysiz = 179
        0x00, 0x00, 0x00, 0x00, // XOsiz
        0x00, 0x00, 0x00, 0x00, // YOsiz
        0x00, 0x00, 0x01, 0x2F, // XTsiz
        0x00, 0x00, 0x00, 0xB3, // YTsiz
        0x00, 0x00, 0x00, 0x00, // XTOsiz
        0x00, 0x00, 0x00, 0x00, // YTOsiz
        0x00, 0x01, // Csiz
        0x07, 0x01, 0x01, // Ssiz/XRsiz/YRsiz for component 0
    };
    var report = ValidationReport{
        .overall = .pass,
        .variant = .j2k_codestream,
        .width = null,
        .height = null,
        .findings = .empty,
    };
    defer report.deinit(std.testing.allocator);
    parseSizBody(&report, &body);
    try std.testing.expectEqual(@as(?u32, 303), report.width);
    try std.testing.expectEqual(@as(?u32, 179), report.height);
}
