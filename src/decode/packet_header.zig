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
const TagTree = @import("tag_tree.zig").TagTree;
const CodingParams = @import("codestream.zig").CodingParams;
const subbands = @import("subbands.zig");

/// Per-code-block decoder state that persists across packet headers
/// (across every layer for the same code-block). T.800 B.10.4–B.10.7
/// fields. Initialise to zero/defaults; the walker updates as it
/// processes successive packets.
pub const CodeBlockState = struct {
    /// True once the code-block has appeared in at least one
    /// packet (i.e. inclusion tag tree resolved). After this point
    /// the inclusion bit is a literal 1/0 in each layer's packet
    /// header, not a tag-tree-coded value.
    included: bool = false,

    /// Layer at which `included` first became true. Undefined when
    /// `included == false`.
    inclusion_layer: u16 = 0,

    /// Number of most-significant bitplanes that are zero for
    /// this code-block. Read once, on first inclusion, via the
    /// zero-bitplane tag tree.
    zero_bitplanes: u8 = 0,

    /// T.800 B.10.7: Lblock state. Initialised to 3; bumped by 1
    /// for every "1" prefix bit in subsequent packet headers.
    lblock: u8 = 3,
};

/// One code-block's contribution to a single packet's body.
pub const CodeBlockContribution = struct {
    /// false → this code-block contributes zero bytes to this packet
    included: bool,
    /// Newly added coding passes contributed by this packet
    /// (1..164). Only meaningful when included == true.
    new_coding_passes: u8 = 0,
    /// Compressed byte length of this code-block's contribution to
    /// the packet body. Only meaningful when included == true.
    contribution_length: u32 = 0,
};

/// Walk one code-block's entry in a packet header. Caller has
/// already advanced past the zero-length packet flag and is
/// positioned at this code-block's first bit. Reads:
///   1. Inclusion (literal bit if `state.included`; else inclusion
///      tag tree query against threshold = current_layer + 1)
///   2. On first inclusion: zero-bitplane count via tag tree with
///      ascending thresholds
///   3. Number of new coding passes (T.800 Table B.4)
///   4. Lblock update (zero-or-more "1" bits, then "0")
///   5. Length value (lblock + floor(log2(passes)) bits)
///
/// Returns null on bit-stream EOF mid-walk.
pub fn readCodeBlockContribution(
    reader: *BitReader,
    inclusion_tree: *TagTree,
    zero_bitplane_tree: *TagTree,
    state: *CodeBlockState,
    cblk_x: u32,
    cblk_y: u32,
    current_layer: u16,
) ?CodeBlockContribution {
    // 1. Inclusion.
    if (state.included) {
        const b = reader.readBit() orelse return null;
        if (b == 0) return .{ .included = false };
    } else {
        const becomes_included = inclusion_tree.read(reader, cblk_x, cblk_y, @as(u32, current_layer) + 1);
        if (!becomes_included) return .{ .included = false };
        state.included = true;
        state.inclusion_layer = current_layer;

        // 2. Zero-bitplane count, via successive threshold raises.
        var thr: u32 = 1;
        while (true) {
            const decoded = zero_bitplane_tree.read(reader, cblk_x, cblk_y, thr);
            if (decoded) break;
            thr += 1;
            // Sanity: bit depth ceiling. 64 is comfortably above any
            // realistic value (max bit depth in T.800 Part 1 is 38).
            if (thr > 64) return null;
        }
        state.zero_bitplanes = @intCast(thr - 1);
    }

    // 3. Coding-pass count.
    const passes = readCodingPasses(reader) orelse return null;

    // 4. Lblock update.
    const new_lblock = updateLblock(reader, state.lblock) orelse return null;
    state.lblock = new_lblock;

    // 5. Length value.
    const length = readLengthValue(reader, state.lblock, passes) orelse return null;

    return .{
        .included = true,
        .new_coding_passes = passes,
        .contribution_length = length,
    };
}

/// A single subband's per-precinct decode state — the persistent
/// tag trees for inclusion + zero-bitplane signaling, plus the
/// flat array of code-block states (row-major, grid.height ×
/// grid.width). Owner of the heap memory; deinit frees it all.
pub const SubbandState = struct {
    inclusion_tree: TagTree,
    zero_bitplane_tree: TagTree,
    blocks: []CodeBlockState, // flat, row-major
    grid_w: u32,
    grid_h: u32,

    pub fn init(
        allocator: std.mem.Allocator,
        sb: subbands.SubbandInfo,
        cblk_w_exp: u8,
        cblk_h_exp: u8,
    ) std.mem.Allocator.Error!SubbandState {
        const grid = subbands.codeBlockGrid(sb, cblk_w_exp, cblk_h_exp);
        const blocks = try allocator.alloc(CodeBlockState, @as(usize, grid.width) * @as(usize, grid.height));
        @memset(blocks, .{});
        errdefer allocator.free(blocks);

        // Tag tree dims = code-block grid dims (one leaf per cblk).
        var incl = try TagTree.init(allocator, grid.width, grid.height);
        errdefer incl.deinit(allocator);
        const zb = try TagTree.init(allocator, grid.width, grid.height);
        return .{
            .inclusion_tree = incl,
            .zero_bitplane_tree = zb,
            .blocks = blocks,
            .grid_w = grid.width,
            .grid_h = grid.height,
        };
    }

    pub fn deinit(self: *SubbandState, allocator: std.mem.Allocator) void {
        self.inclusion_tree.deinit(allocator);
        self.zero_bitplane_tree.deinit(allocator);
        allocator.free(self.blocks);
        self.* = undefined;
    }
};

/// Walk one full packet header. Caller has positioned the reader
/// at the byte-aligned start of the header. Reads:
///   1. Zero-length-packet flag (1 bit). If 0, byte-align and return 0.
///   2. For each subband at this resolution (1 LL at r=0; or 3
///      HL/LH/HH at r>=1): iterate the precinct's code-block grid
///      in row-major order, calling readCodeBlockContribution.
///   3. Byte-align to next byte boundary.
///
/// `subband_states` must have length subbandCount(resolution) and
/// the entries must match the subband order (HL=0, LH=1, HH=2 at
/// resolutions >= 1).
///
/// Returns the total body byte count this packet contributes
/// (sum of per-code-block contribution_length), or null on EOF.
pub fn readPacketHeader(
    reader: *BitReader,
    subband_states: []SubbandState,
    current_layer: u16,
) ?u32 {
    const flag = reader.readBit() orelse return null;
    if (flag == 0) {
        reader.alignToByte();
        return 0;
    }

    var total_length: u32 = 0;
    for (subband_states) |*sbs| {
        var y: u32 = 0;
        while (y < sbs.grid_h) : (y += 1) {
            var x: u32 = 0;
            while (x < sbs.grid_w) : (x += 1) {
                const idx = @as(usize, y) * @as(usize, sbs.grid_w) + @as(usize, x);
                const c = readCodeBlockContribution(
                    reader,
                    &sbs.inclusion_tree,
                    &sbs.zero_bitplane_tree,
                    &sbs.blocks[idx],
                    x,
                    y,
                    current_layer,
                ) orelse return null;
                if (c.included) total_length += c.contribution_length;
            }
        }
    }
    reader.alignToByte();
    return total_length;
}

test "readPacketHeader: empty packet flag '0' followed by alignment" {
    const allocator = std.testing.allocator;
    var sb_state = try SubbandState.init(
        allocator,
        .{ .kind = .ll, .width = 10, .height = 6 },
        4,
        4,
    );
    defer sb_state.deinit(allocator);

    // Single bit '0' for empty packet, then 7 padding bits.
    var reader = BitReader.init(&.{0x00}, .{});
    var states = [_]SubbandState{sb_state};
    const len = readPacketHeader(&reader, &states, 0).?;
    try std.testing.expectEqual(@as(u32, 0), len);
    // After byte-align, full byte consumed.
    try std.testing.expectEqual(@as(usize, 1), reader.bytesConsumed());
}

test "readPacketHeader: r=0, 1×1 cblk, first inclusion at layer 0" {
    const allocator = std.testing.allocator;
    var sb_state = try SubbandState.init(
        allocator,
        .{ .kind = .ll, .width = 10, .height = 6 },
        4,
        4,
    );
    defer sb_state.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 1), sb_state.grid_w);
    try std.testing.expectEqual(@as(u32, 1), sb_state.grid_h);

    // Header stream: zero-length flag '1' + code-block contribution
    // bits from the earlier per-cblk test. Bits in order:
    //   '1' (non-empty)
    //   '1' (inclusion tag tree decoded)
    //   '1' (zero-bitplane tag tree at threshold 1)
    //   '0' (coding passes = 1)
    //   '0' (Lblock unchanged)
    //   '010' (3-bit length = 2)
    // Total 8 bits → 0b11100010 = 0xE2. byte-align is a no-op
    // since we land exactly on the boundary.
    var states = [_]SubbandState{sb_state};
    var reader = BitReader.init(&.{0xE2}, .{});
    const len = readPacketHeader(&reader, &states, 0).?;
    try std.testing.expectEqual(@as(u32, 2), len);
    try std.testing.expectEqual(true, states[0].blocks[0].included);
    try std.testing.expectEqual(@as(u8, 0), states[0].blocks[0].zero_bitplanes);
}

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

test "readCodeBlockContribution: first inclusion, 1 pass, default lblock" {
    // Hand-crafted stream for layer-0 first inclusion of a single
    // code-block at (0,0) in 1×1 tag trees:
    //   1. inclusion tag tree: "1" → leaf decoded at value 0 < 1 (included at layer 0)
    //   2. zero-bitplane tag tree: "1" → leaf at value 0 < 1 (zero-bitplanes = 0)
    //   3. coding passes: "0" → 1 pass
    //   4. Lblock update: "0" → no change (lblock stays at 3)
    //   5. length value: 3 + floor(log2(1)) = 3 bits, "010" = 2
    // Total 7 bits, packed MSB-first: 11_0_0_010 0 = 0b11000100 = 0xC4.
    const allocator = std.testing.allocator;
    var incl = try TagTree.init(allocator, 1, 1);
    defer incl.deinit(allocator);
    var zb = try TagTree.init(allocator, 1, 1);
    defer zb.deinit(allocator);

    var state: CodeBlockState = .{};
    var reader = BitReader.init(&.{0xC4}, .{});
    const c = readCodeBlockContribution(&reader, &incl, &zb, &state, 0, 0, 0).?;
    try std.testing.expectEqual(true, c.included);
    try std.testing.expectEqual(@as(u8, 1), c.new_coding_passes);
    try std.testing.expectEqual(@as(u32, 2), c.contribution_length);
    try std.testing.expectEqual(@as(u8, 0), state.zero_bitplanes);
    try std.testing.expectEqual(@as(u8, 3), state.lblock);
    try std.testing.expectEqual(true, state.included);
    try std.testing.expectEqual(@as(u16, 0), state.inclusion_layer);
}

test "readCodeBlockContribution: previously-included, 0-pass packet (skip bit '0')" {
    // State already shows inclusion; the inclusion bit is a literal
    // 0/1 not a tag-tree query. "0" → no contribution this packet.
    const allocator = std.testing.allocator;
    var incl = try TagTree.init(allocator, 1, 1);
    defer incl.deinit(allocator);
    var zb = try TagTree.init(allocator, 1, 1);
    defer zb.deinit(allocator);

    var state: CodeBlockState = .{ .included = true, .inclusion_layer = 0, .zero_bitplanes = 2, .lblock = 4 };
    var reader = BitReader.init(&.{0x00}, .{});
    const c = readCodeBlockContribution(&reader, &incl, &zb, &state, 0, 0, 3).?;
    try std.testing.expectEqual(false, c.included);
    // State must NOT mutate when the code-block is skipped this packet.
    try std.testing.expectEqual(@as(u8, 4), state.lblock);
    try std.testing.expectEqual(@as(u8, 2), state.zero_bitplanes);
}

test "readCodeBlockContribution: previously-included, Lblock grows by 2" {
    // Per-cblk state: already included, lblock = 3.
    // Bits: "1" inclusion. "10" = 2 passes. "110" = Lblock += 2 → 5.
    // Length = lblock + log2(2) = 5 + 1 = 6 bits, "101010" = 0x2A = 42.
    // Total 1+2+3+6 = 12 bits.
    // MSB-first pack:
    //   bit 0 (incl): 1
    //   bits 1-2 (passes): 10
    //   bits 3-5 (lblock): 110
    //   bits 6-11 (length): 101010
    // → 1_10_110_101010 = 0xDB 0xA0 (first byte 11011011 = 0xDB? let me redo)
    // bits in order: 1,1,0,1,1,0,1,0,1,0,1,0
    // First byte (bits 7..0): 11011010 = 0xDA
    // Second byte: bits 4 more, then 4 padding: 10100000 = 0xA0
    const allocator = std.testing.allocator;
    var incl = try TagTree.init(allocator, 1, 1);
    defer incl.deinit(allocator);
    var zb = try TagTree.init(allocator, 1, 1);
    defer zb.deinit(allocator);

    var state: CodeBlockState = .{ .included = true, .inclusion_layer = 0, .lblock = 3 };
    var reader = BitReader.init(&.{ 0xDA, 0xA0 }, .{});
    const c = readCodeBlockContribution(&reader, &incl, &zb, &state, 0, 0, 1).?;
    try std.testing.expectEqual(true, c.included);
    try std.testing.expectEqual(@as(u8, 2), c.new_coding_passes);
    try std.testing.expectEqual(@as(u32, 42), c.contribution_length);
    try std.testing.expectEqual(@as(u8, 5), state.lblock);
}

test "readCodeBlockContribution: non-included via inclusion tag tree (high threshold)" {
    // Layer 0, inclusion tag tree returns false because the leaf
    // value is at least 1 (we don't yet know how much more). Bits:
    // "0" → value=1 ≥ threshold=1 → return false. 1 bit consumed.
    const allocator = std.testing.allocator;
    var incl = try TagTree.init(allocator, 1, 1);
    defer incl.deinit(allocator);
    var zb = try TagTree.init(allocator, 1, 1);
    defer zb.deinit(allocator);

    var state: CodeBlockState = .{};
    var reader = BitReader.init(&.{0x00}, .{});
    const c = readCodeBlockContribution(&reader, &incl, &zb, &state, 0, 0, 0).?;
    try std.testing.expectEqual(false, c.included);
    try std.testing.expectEqual(false, state.included);
}
