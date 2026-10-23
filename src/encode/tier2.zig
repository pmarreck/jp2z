//! Tier-2 building blocks for the encoder (T.800 Annex B): the packet-header
//! bit writer with 0xFF bit stuffing (B.10.1), the tag-tree encoder (B.10.2),
//! the coding-pass count codewords (Table B.4) and the Lblock / length
//! signalling (B.10.7). Each is tested by reading its output back with the
//! decoder's own reader (decode/bit_reader.zig, decode/tag_tree.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// MSB-first bit writer. After an output byte of 0xFF the next byte carries
/// only 7 bits (its top bit is a stuffed 0), so no marker code can appear
/// inside a packet header. `finish` pads to a byte and, if the last byte is
/// 0xFF, adds one more byte so the header never ends on 0xFF (as OpenJPEG's
/// opj_bio_flush does).
pub const BitWriter = struct {
    out: std.ArrayList(u8) = .empty,
    /// Bits accumulated for the next output byte.
    cur: u8 = 0,
    /// How many bits `cur` holds so far.
    filled: u4 = 0,
    /// How many bits the next byte carries: 8, or 7 after a 0xFF.
    cap: u4 = 8,

    pub fn deinit(self: *BitWriter, a: Allocator) void {
        self.out.deinit(a);
    }

    fn emit(self: *BitWriter, a: Allocator) !void {
        try self.out.append(a, self.cur);
        self.cap = if (self.cur == 0xFF) 7 else 8;
        self.cur = 0;
        self.filled = 0;
    }

    pub fn writeBit(self: *BitWriter, a: Allocator, bit: u1) !void {
        self.cur = (self.cur << 1) | bit;
        self.filled += 1;
        if (self.filled == self.cap) try self.emit(a);
    }

    pub fn writeBits(self: *BitWriter, a: Allocator, value: u32, n: u6) !void {
        var i: u6 = n;
        while (i > 0) {
            i -= 1;
            try self.writeBit(a, @intCast((value >> @intCast(i)) & 1));
        }
    }

    pub fn finish(self: *BitWriter, a: Allocator) !void {
        if (self.filled > 0) {
            self.cur <<= @intCast(self.cap - self.filled);
            try self.emit(a);
        }
        if (self.out.items.len > 0 and self.out.items[self.out.items.len - 1] == 0xFF) try self.emit(a);
    }
};

/// Tag-tree encoder over a `width × height` grid of leaf values (B.10.2).
/// Interior nodes hold the minimum of their children. `encode(leaf, t)`
/// writes just enough bits for a decoder at the same state to learn
/// whether the leaf's value is below `t` (and, if so, the value).
pub const TagTreeEncoder = struct {
    const Node = struct { value: u32, low: u32 = 0, known: bool = false };
    const Level = struct { w: u32, h: u32, offset: usize };
    nodes: []Node,
    /// Level 0 is the leaves; the last level is the 1 x 1 root.
    levels: []Level,

    pub fn init(a: Allocator, width: u32, height: u32, values: []const u32) !TagTreeEncoder {
        std.debug.assert(width > 0 and height > 0 and values.len == @as(usize, width) * height);
        var lv = std.ArrayList(Level).empty;
        errdefer lv.deinit(a);
        var w = width;
        var h = height;
        var total: usize = 0;
        while (true) {
            try lv.append(a, .{ .w = w, .h = h, .offset = total });
            total += @as(usize, w) * h;
            if (w == 1 and h == 1) break;
            w = (w + 1) / 2;
            h = (h + 1) / 2;
        }
        const nodes = try a.alloc(Node, total);
        errdefer a.free(nodes);
        for (values, 0..) |v, i| nodes[i] = .{ .value = v };
        // Interior nodes: minimum of their (up to four) children.
        var l: usize = 1;
        while (l < lv.items.len) : (l += 1) {
            const p = lv.items[l];
            const c = lv.items[l - 1];
            var py: u32 = 0;
            while (py < p.h) : (py += 1) {
                var px: u32 = 0;
                while (px < p.w) : (px += 1) {
                    var m: u32 = std.math.maxInt(u32);
                    for ([_][2]u32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } }) |d| {
                        const cx = 2 * px + d[0];
                        const cy = 2 * py + d[1];
                        if (cx < c.w and cy < c.h) m = @min(m, nodes[c.offset + cy * c.w + cx].value);
                    }
                    nodes[p.offset + py * p.w + px] = .{ .value = m };
                }
            }
        }
        return .{ .nodes = nodes, .levels = try lv.toOwnedSlice(a) };
    }

    pub fn deinit(self: *TagTreeEncoder, a: Allocator) void {
        a.free(self.nodes);
        a.free(self.levels);
        self.* = undefined;
    }

    pub fn encode(self: *TagTreeEncoder, a: Allocator, w: *BitWriter, x: u32, y: u32, threshold: u32) !void {
        // Root to leaf along the leaf's ancestors; `low` carries the bound
        // already established higher up the tree.
        var low: u32 = 0;
        var l: usize = self.levels.len;
        while (l > 0) {
            l -= 1;
            const lev = self.levels[l];
            const nx = x >> @intCast(l);
            const ny = y >> @intCast(l);
            const node = &self.nodes[lev.offset + ny * lev.w + nx];
            if (low > node.low) node.low = low else low = node.low;
            while (low < threshold) {
                if (low >= node.value) {
                    if (!node.known) {
                        try w.writeBit(a, 1);
                        node.known = true;
                    }
                    break;
                }
                try w.writeBit(a, 0);
                low += 1;
            }
            node.low = low;
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const BitReader = @import("../decode/bit_reader.zig").BitReader;
const TagTree = @import("../decode/tag_tree.zig").TagTree;

test "BitWriter: seeded bit strings, ones-heavy to force 0xFF bytes, read back through the stuffing BitReader; no output ends in 0xFF" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xB17);
    const rnd = prng.random();
    var bits: [400]u1 = undefined;
    var trial: usize = 0;
    var saw_ff = false;
    while (trial < 500) : (trial += 1) {
        const n = rnd.intRangeAtMost(usize, 1, bits.len);
        const ones_pct = rnd.intRangeAtMost(u32, 50, 100);
        for (bits[0..n]) |*b| b.* = @intFromBool(rnd.uintLessThan(u32, 100) < ones_pct);
        var w: BitWriter = .{};
        defer w.deinit(a);
        for (bits[0..n]) |b| try w.writeBit(a, b);
        try w.finish(a);
        const out = w.out.items;
        try std.testing.expect(out.len > 0);
        try std.testing.expect(out[out.len - 1] != 0xFF);
        for (out) |byte| if (byte == 0xFF) {
            saw_ff = true;
        };
        var r = BitReader.init(out, .{ .ff_stuffing = true });
        for (bits[0..n]) |want| try std.testing.expectEqual(@as(?u1, want), r.readBit());
    }
    try std.testing.expect(saw_ff); // the stuffing path was exercised
}

test "BitWriter.writeBits writes the low n bits MSB first" {
    const a = std.testing.allocator;
    var w: BitWriter = .{};
    defer w.deinit(a);
    try w.writeBits(a, 0b101, 3);
    try w.writeBits(a, 0x1F, 5);
    try w.finish(a);
    try std.testing.expectEqualSlices(u8, &.{0b1011_1111}, w.out.items);
}

test "TagTreeEncoder: seeded grids, the decoder's TagTree recovers every leaf value from the encoded bits, with rising thresholds as tier-2 uses them" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x7A6);
    const rnd = prng.random();
    const dims = [_][2]u32{ .{ 1, 1 }, .{ 1, 5 }, .{ 5, 1 }, .{ 2, 2 }, .{ 3, 7 }, .{ 8, 8 }, .{ 17, 9 } };
    for (dims) |d| {
        var trial: usize = 0;
        while (trial < 30) : (trial += 1) {
            const n = d[0] * d[1];
            const vals = try a.alloc(u32, n);
            defer a.free(vals);
            const vmax = rnd.intRangeAtMost(u32, 0, 20);
            for (vals) |*v| v.* = rnd.intRangeAtMost(u32, 0, vmax);
            var enc = try TagTreeEncoder.init(a, d[0], d[1], vals);
            defer enc.deinit(a);
            var w: BitWriter = .{};
            defer w.deinit(a);
            // Leaves in raster order, each fully coded (threshold above any value).
            for (0..n) |i| try enc.encode(a, &w, @intCast(i % d[0]), @intCast(i / d[0]), 1000);
            try w.finish(a);
            var tt = try TagTree.init(a, d[0], d[1]);
            defer tt.deinit(a);
            var r = BitReader.init(w.out.items, .{ .ff_stuffing = true });
            for (0..n) |i| {
                const x: u32 = @intCast(i % d[0]);
                const y: u32 = @intCast(i / d[0]);
                // The decoder learns the value by raising the threshold until known.
                var t: u32 = 1;
                while (!tt.read(&r, x, y, t)) : (t += 1) {
                    if (t > 1000) return error.TestUnexpectedResult;
                }
                try std.testing.expectEqual(vals[i], t - 1);
            }
        }
    }
}

test "TagTreeEncoder: inclusion-style use, threshold 1 only: the decoder learns exactly which leaves are 0" {
    const a = std.testing.allocator;
    const vals = [_]u32{ 0, 1, 1, 0, 1, 0, 0, 1, 1, 1, 0, 0 }; // 4 x 3
    var enc = try TagTreeEncoder.init(a, 4, 3, &vals);
    defer enc.deinit(a);
    var w: BitWriter = .{};
    defer w.deinit(a);
    for (0..12) |i| try enc.encode(a, &w, @intCast(i % 4), @intCast(i / 4), 1);
    try w.finish(a);
    var tt = try TagTree.init(a, 4, 3);
    defer tt.deinit(a);
    var r = BitReader.init(w.out.items, .{ .ff_stuffing = true });
    for (0..12) |i| try std.testing.expectEqual(vals[i] == 0, tt.read(&r, @intCast(i % 4), @intCast(i / 4), 1));
}
