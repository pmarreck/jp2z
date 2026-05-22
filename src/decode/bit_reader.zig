//! MSB-first bit reader over an immutable byte slice. Used by the
//! tier-2 packet-header decoder (M2) and eventually by tier-1 EBCOT
//! (M3). Optional T.800 0xFF-stuffing handling:
//!
//! Within packet headers and entropy-coded segments, the encoder
//! must not let the byte stream contain a literal 0xFF followed by
//! a byte with the high bit set. So whenever a complete byte equal
//! to 0xFF has just been consumed, the high bit of the *next* byte
//! is a stuff bit (always 0) and must be skipped from the
//! meaningful bit stream. Enable with `.ff_stuffing = true`.

const std = @import("std");

pub const Options = struct {
    /// When true, after consuming a 0xFF byte the high bit of the
    /// next byte is treated as a stuff bit and skipped.
    ff_stuffing: bool = false,
};

pub const BitReader = struct {
    data: []const u8,
    byte_pos: usize = 0,
    /// 0..7. 0 means "next bit to read is the MSB of data[byte_pos]";
    /// 8 means "current byte is fully consumed, advance on next read".
    bit_pos: u4 = 0,
    prev_was_ff: bool = false,
    options: Options,

    pub fn init(data: []const u8, options: Options) BitReader {
        return .{ .data = data, .options = options };
    }

    /// Read the next MSB-first bit. Returns null on EOF.
    pub fn readBit(self: *BitReader) ?u1 {
        // Advance past a fully-consumed byte (and apply stuffing
        // if the byte we just finished was 0xFF and ff_stuffing is on).
        if (self.bit_pos == 8) {
            self.byte_pos += 1;
            self.bit_pos = if (self.options.ff_stuffing and self.prev_was_ff) 1 else 0;
            self.prev_was_ff = false;
        }
        if (self.byte_pos >= self.data.len) return null;

        const byte = self.data[self.byte_pos];
        const shift: u3 = @intCast(7 - @as(u3, @intCast(self.bit_pos)));
        const bit: u1 = @intCast((byte >> shift) & 1);

        self.bit_pos += 1;
        if (self.bit_pos == 8) {
            self.prev_was_ff = byte == 0xFF;
        }
        return bit;
    }

    /// Read `n` MSB-first bits as an unsigned integer (`n` ≤ 32).
    /// Returns null if EOF is hit before all `n` bits are gathered.
    pub fn readBits(self: *BitReader, n: u5) ?u32 {
        var v: u32 = 0;
        var i: u5 = 0;
        while (i < n) : (i += 1) {
            const b = self.readBit() orelse return null;
            v = (v << 1) | @as(u32, b);
        }
        return v;
    }

    /// Discard any bits remaining in the current byte so the next
    /// read starts on a byte boundary. Honors 0xFF-stuffing on the
    /// boundary it lands on (the next byte's high bit will be the
    /// stuff bit if the byte we just left was 0xFF).
    pub fn alignToByte(self: *BitReader) void {
        if (self.bit_pos == 0 or self.bit_pos == 8) return;
        // Mark the current byte as consumed; the next readBit() will
        // advance to data[byte_pos+1] and honor stuffing.
        self.prev_was_ff = self.data[self.byte_pos] == 0xFF;
        self.bit_pos = 8;
    }

    /// Bytes that have been fully consumed (i.e. excluding the
    /// currently-in-progress byte if any bits remain in it).
    pub fn bytesConsumed(self: BitReader) usize {
        return self.byte_pos + @as(usize, if (self.bit_pos == 8) 1 else 0);
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "BitReader: reads single bits MSB-first from a single byte" {
    var r = BitReader.init(&.{0b10110100}, .{});
    try std.testing.expectEqual(@as(?u1, 1), r.readBit());
    try std.testing.expectEqual(@as(?u1, 0), r.readBit());
    try std.testing.expectEqual(@as(?u1, 1), r.readBit());
    try std.testing.expectEqual(@as(?u1, 1), r.readBit());
    try std.testing.expectEqual(@as(?u1, 0), r.readBit());
    try std.testing.expectEqual(@as(?u1, 1), r.readBit());
    try std.testing.expectEqual(@as(?u1, 0), r.readBit());
    try std.testing.expectEqual(@as(?u1, 0), r.readBit());
    try std.testing.expectEqual(@as(?u1, null), r.readBit());
}

test "BitReader: readBits assembles MSB-first" {
    var r = BitReader.init(&.{ 0xAB, 0xCD }, .{});
    try std.testing.expectEqual(@as(?u32, 0xA), r.readBits(4));
    try std.testing.expectEqual(@as(?u32, 0xB), r.readBits(4));
    try std.testing.expectEqual(@as(?u32, 0xCD), r.readBits(8));
    try std.testing.expectEqual(@as(?u1, null), r.readBit());
}

test "BitReader: readBits straddles byte boundaries" {
    // 0xF0 = 1111_0000, 0x0F = 0000_1111.
    // Reading 12 bits = 1111_0000_0000 = 0xF00.
    var r = BitReader.init(&.{ 0xF0, 0x0F }, .{});
    try std.testing.expectEqual(@as(?u32, 0xF00), r.readBits(12));
    try std.testing.expectEqual(@as(?u32, 0xF), r.readBits(4));
}

test "BitReader: alignToByte skips remainder of current byte" {
    var r = BitReader.init(&.{ 0xAB, 0xCD }, .{});
    _ = r.readBits(3); // consume MSBs of 0xAB
    r.alignToByte();
    try std.testing.expectEqual(@as(?u32, 0xCD), r.readBits(8));
}

test "BitReader: 0xFF-stuffing skips the high bit of the next byte" {
    // [0xFF, 0x40]: encoded as { 0xFF, then high bit must be 0
    // (stuff), then 7 data bits 1000000 }. After consuming the 0xFF
    // and skipping the stuff bit, the next 7 readable bits are
    // those 7 data bits = 0b1000000 = 64.
    var r = BitReader.init(&.{ 0xFF, 0x40 }, .{ .ff_stuffing = true });
    try std.testing.expectEqual(@as(?u32, 0xFF), r.readBits(8));
    try std.testing.expectEqual(@as(?u32, 0b1000000), r.readBits(7));
    try std.testing.expectEqual(@as(?u1, null), r.readBit());
}

test "BitReader: stuffing disabled by default — same input reads naturally" {
    var r = BitReader.init(&.{ 0xFF, 0x40 }, .{});
    try std.testing.expectEqual(@as(?u32, 0xFF), r.readBits(8));
    try std.testing.expectEqual(@as(?u32, 0x40), r.readBits(8));
}
