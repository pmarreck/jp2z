//! Tier-2 packet header parsing primitives, T.800 B.10.
//!
//! A packet header (when non-empty) carries, *per code-block*:
//!   1. Inclusion bit (via the precinct's inclusion tag tree)
//!   2. On first inclusion: zero-bitplane count (via the
//!      zero-bitplane tag tree)
//!   3. Number of new coding passes (variable-length prefix-coded
//!      per Table B.4)
//!   4. Lblock update (zero-or-more "1" bits terminated by "0";
//!      each "1" bumps the per-code-block Lblock state by 1)
//!   5. Length value: (Lblock + floor(log2(coding_passes))) bits,
//!      giving the byte length of this code-block's compressed
//!      contribution to the packet body
//! Then the header byte-aligns to the next byte boundary.
//!
//! This module currently implements pieces 3, 4, and 5 as
//! reader-level primitives — the per-code-block loop that calls
//! them in sequence lands in a follow-on once code-block geometry
//! per (resolution, component, precinct) is wired up.

const std = @import("std");
const BitReader = @import("bit_reader.zig").BitReader;

/// T.800 Table B.4 — variable-length coding-pass count.
///
///   "0"                              → 1 pass
///   "10"                             → 2 passes
///   "1100"/"1101"/"1110"             → 3 / 4 / 5 passes
///   "1111" + 5 bits (0..30)          → 6..36 passes
///   "1111" + "11111" + 7 bits (0..127) → 37..164 passes
///
/// Returns null on EOF mid-decode.
pub fn readCodingPasses(reader: *BitReader) ?u8 {
    const b0 = reader.readBit() orelse return null;
    if (b0 == 0) return 1;
    const b1 = reader.readBit() orelse return null;
    if (b1 == 0) return 2;
    // We've now read "11"; need 2 more bits.
    const b2 = reader.readBit() orelse return null;
    const b3 = reader.readBit() orelse return null;
    // "1100"/"1101"/"1110" cover 3/4/5; "1111" is the tier-3 prefix.
    const tail2: u2 = (@as(u2, b2) << 1) | @as(u2, b3);
    if (tail2 != 0b11) return @as(u8, 3) + @as(u8, tail2);
    // Tier 3: read 5 more bits. v < 31 → 6+v passes; v == 31 → tier 4.
    const v5 = reader.readBits(5) orelse return null;
    if (v5 < 31) return @intCast(6 + v5);
    // Tier 4: read 7 more bits → 37 + v.
    const v7 = reader.readBits(7) orelse return null;
    return @intCast(37 + v7);
}

/// T.800 B.10.7 — Lblock update. Reads zero-or-more "1" bits
/// terminated by a "0" bit and adds the count of "1"s to the
/// caller's `lblock` state. Returns the new Lblock value, or null
/// on EOF.
pub fn updateLblock(reader: *BitReader, current_lblock: u8) ?u8 {
    var lblock = current_lblock;
    while (true) {
        const b = reader.readBit() orelse return null;
        if (b == 0) return lblock;
        lblock += 1;
    }
}

/// T.800 B.10.7 — length value. The number of bits to read is
/// `lblock + floor(log2(coding_passes))`. Returns null on EOF.
pub fn readLengthValue(reader: *BitReader, lblock: u8, coding_passes: u8) ?u32 {
    std.debug.assert(coding_passes >= 1);
    const log2_passes: u8 = if (coding_passes == 1) 0 else @intCast(31 - @clz(@as(u32, coding_passes)));
    const bit_count: u8 = lblock + log2_passes;
    return reader.readBits(@intCast(bit_count));
}

// ── Tests ──────────────────────────────────────────────────────────

test "readCodingPasses: single-bit '0' encodes 1 pass" {
    var r = BitReader.init(&.{0b00000000}, .{});
    try std.testing.expectEqual(@as(?u8, 1), readCodingPasses(&r));
}

test "readCodingPasses: '10' encodes 2 passes" {
    var r = BitReader.init(&.{0b10000000}, .{});
    try std.testing.expectEqual(@as(?u8, 2), readCodingPasses(&r));
}

test "readCodingPasses: '1100' = 3, '1101' = 4, '1110' = 5" {
    var r3 = BitReader.init(&.{0b11000000}, .{});
    try std.testing.expectEqual(@as(?u8, 3), readCodingPasses(&r3));
    var r4 = BitReader.init(&.{0b11010000}, .{});
    try std.testing.expectEqual(@as(?u8, 4), readCodingPasses(&r4));
    var r5 = BitReader.init(&.{0b11100000}, .{});
    try std.testing.expectEqual(@as(?u8, 5), readCodingPasses(&r5));
}

test "readCodingPasses: '1111 00000' = 6, '1111 11110' = 36" {
    // 1111 00000 = 0xF0 0x00 (9 bits, but we only read 9)
    var r6 = BitReader.init(&.{ 0b11110000, 0b00000000 }, .{});
    try std.testing.expectEqual(@as(?u8, 6), readCodingPasses(&r6));
    // 1111 11110 → 9 bits = 0xFF 0x80? Let's bit-pack: bits 1,1,1,1,1,1,1,1,0 starting from MSB.
    // Byte 0 = 11111111 = 0xFF, byte 1's bit 7 (MSB) = 0 → 0x00.
    var r36 = BitReader.init(&.{ 0xFF, 0x00 }, .{});
    try std.testing.expectEqual(@as(?u8, 36), readCodingPasses(&r36));
}

test "readCodingPasses: '1111 11111 0000000' = 37, max '... 1111111' = 164" {
    // 1111 11111 0000000 — 16 bits. Byte 0=11111111=0xFF, byte 1=11000000=0xC0
    // Wait: bits 1,1,1,1, 1,1,1,1, 1,0,0,0, 0,0,0,0 → 0xFF 0x80.
    // No wait: 4 prefix bits (1111) + 5 (11111) + 7 (0000000) = 16 bits total.
    // Pack MSB-first: 1111_1111 1_0000000 → 0xFF, 0x80.
    var r37 = BitReader.init(&.{ 0xFF, 0x80 }, .{});
    try std.testing.expectEqual(@as(?u8, 37), readCodingPasses(&r37));
    // 1111_1111 1_1111111 → 0xFF, 0xFF
    var r164 = BitReader.init(&.{ 0xFF, 0xFF }, .{});
    try std.testing.expectEqual(@as(?u8, 164), readCodingPasses(&r164));
}

test "updateLblock: no '1's → returned value unchanged" {
    var r = BitReader.init(&.{0b00000000}, .{});
    try std.testing.expectEqual(@as(?u8, 3), updateLblock(&r, 3));
}

test "updateLblock: three '1's then '0' → +3" {
    // bits 1,1,1,0 = 0b1110 high nibble = 0xE0
    var r = BitReader.init(&.{0xE0}, .{});
    try std.testing.expectEqual(@as(?u8, 6), updateLblock(&r, 3));
}

test "readLengthValue: lblock + log2(passes) bits read MSB-first" {
    // lblock = 4, passes = 8 → log2 = 3 → 7 bits total.
    // Stream: 0b1010101 = 85 (decimal). Pack as high bits of one byte: 0xAA.
    var r = BitReader.init(&.{0xAA}, .{});
    try std.testing.expectEqual(@as(?u32, 0b1010101), readLengthValue(&r, 4, 8));
}

test "readLengthValue: 1 coding pass → log2 = 0" {
    // lblock = 5, passes = 1 → 5 bits. 0b10101 = 21, packed as 0xA8.
    var r = BitReader.init(&.{0b10101000}, .{});
    try std.testing.expectEqual(@as(?u32, 0b10101), readLengthValue(&r, 5, 1));
}
