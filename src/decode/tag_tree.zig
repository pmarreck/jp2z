//! Quadtree-based "tag tree" decoder used in T.800 B.10 packet
//! headers for:
//!   - the **inclusion** tag tree: leaf value = layer index at which
//!     a given code-block (i,j) first becomes included in a packet
//!   - the **zero-bitplane** tag tree: leaf value = number of
//!     most-significant bitplanes that are zero for that code-block
//!
//! Each interior node's "value" is the minimum of its children's
//! values. The bit-coded representation lets the decoder pin down
//! a leaf's value relative to any threshold T using only as many
//! bits as needed; the tree state persists across reads so
//! successive queries (with monotonically increasing thresholds)
//! amortise the work.
//!
//! For a w×h grid of leaves we build levels above it, each
//! ceil(w/2) × ceil(h/2) of the previous, up to a 1×1 root. The
//! "current best" lower bound for each node lives in `nodes[]`.
//! When walking root → leaf for a query with threshold T:
//!   while node.value < T:
//!     read 1 bit
//!     if 0: node.value += 1; stop refining this node
//!     if 1: node.value = T; descend
//!
//! After the walk:
//!   - if leaf.value <  T  → leaf value is known to be exactly
//!                            leaf.value, *return true*
//!   - if leaf.value >= T  → leaf value is at least T (could be
//!                            larger; later reads with larger T
//!                            will continue refining), *return false*

const std = @import("std");
const Allocator = std.mem.Allocator;
const BitReader = @import("bit_reader.zig").BitReader;

pub const TagTree = struct {
    width: u32,
    height: u32,
    /// Per-level dimensions, level 0 = leaves; len = num_levels.
    levels: []Level,
    /// Concatenation of all level node arrays. nodes[levels[L].offset..]
    /// holds level L's nodes in row-major order (width = levels[L].w).
    nodes: []Node,

    pub const Level = struct {
        w: u32,
        h: u32,
        offset: usize,
    };

    pub const Node = struct {
        /// Current known lower bound for this node's value.
        value: u32 = 0,
        /// True once we've stopped refining this node (i.e. for the
        /// active threshold, decoder read a 0 bit here). Reset to
        /// false when a new threshold supersedes the previous.
        decoded: bool = false,
    };

    pub fn init(allocator: Allocator, width: u32, height: u32) Allocator.Error!TagTree {
        std.debug.assert(width > 0 and height > 0);

        // Determine level count: at least one level for the leaves,
        // plus one more each time we halve dimensions (rounded up)
        // until both reach 1.
        var w = width;
        var h = height;
        var num_levels: usize = 1;
        while (w > 1 or h > 1) {
            w = (w + 1) / 2;
            h = (h + 1) / 2;
            num_levels += 1;
        }

        const levels = try allocator.alloc(Level, num_levels);
        errdefer allocator.free(levels);

        var total_nodes: usize = 0;
        w = width;
        h = height;
        for (levels) |*lv| {
            lv.* = .{ .w = w, .h = h, .offset = total_nodes };
            total_nodes += @as(usize, w) * @as(usize, h);
            w = (w + 1) / 2;
            h = (h + 1) / 2;
        }

        const nodes = try allocator.alloc(Node, total_nodes);
        @memset(nodes, .{});

        return .{
            .width = width,
            .height = height,
            .levels = levels,
            .nodes = nodes,
        };
    }

    pub fn deinit(self: *TagTree, allocator: Allocator) void {
        allocator.free(self.nodes);
        allocator.free(self.levels);
        self.* = undefined;
    }

    /// Refine the tag tree for the leaf at (`x`,`y`) against
    /// `threshold`. Returns true iff the leaf's true value is
    /// strictly less than `threshold` (i.e. the value has been
    /// fully decoded). Returns false if the bit stream indicates
    /// the value is ≥ threshold OR if the reader hits EOF mid-walk.
    pub fn read(self: *TagTree, reader: *BitReader, x: u32, y: u32, threshold: u32) bool {
        std.debug.assert(x < self.width and y < self.height);

        // Walk root → leaf, collecting the path of node indices.
        // Path length == num_levels.
        var path_xy: [32]struct { x: u32, y: u32 } = undefined;
        const num_levels = self.levels.len;
        std.debug.assert(num_levels <= path_xy.len);

        var cur_x = x;
        var cur_y = y;
        // Level 0 = leaves, the highest level index = root.
        // Build path bottom-up first, then traverse top-down.
        var i: usize = 0;
        while (i < num_levels) : (i += 1) {
            path_xy[i] = .{ .x = cur_x, .y = cur_y };
            cur_x /= 2;
            cur_y /= 2;
        }

        // Propagate the parent's current `value` downward into any
        // descendant whose `value` is still lower (interior nodes
        // are running minima of their children, so a child's value
        // can never be less than its ancestor's). This ensures the
        // refinement bits we read at each level move the value
        // monotonically upward without skipping ancestor floors.
        var lvl_iter = num_levels;
        while (lvl_iter > 1) {
            lvl_iter -= 1;
            const parent = &self.nodes[self.levels[lvl_iter].offset +
                path_xy[lvl_iter].y * self.levels[lvl_iter].w + path_xy[lvl_iter].x];
            const child = &self.nodes[self.levels[lvl_iter - 1].offset +
                path_xy[lvl_iter - 1].y * self.levels[lvl_iter - 1].w + path_xy[lvl_iter - 1].x];
            if (child.value < parent.value) child.value = parent.value;
        }

        // Top-down refinement from root toward the leaf.
        var lvl: usize = num_levels;
        while (lvl > 0) {
            lvl -= 1;
            const lv = self.levels[lvl];
            const node = &self.nodes[lv.offset + path_xy[lvl].y * lv.w + path_xy[lvl].x];

            while (!node.decoded and node.value < threshold) {
                const b = reader.readBit() orelse return false;
                if (b == 0) {
                    node.value += 1;
                } else {
                    node.decoded = true;
                }
            }
            if (node.value < threshold) {
                // node was already decoded at a lower value — propagate
                // to its descendants on this path on the next iter,
                // but for the threshold check that's enough.
            }
            // If the node's value is still < threshold and we've
            // decided to descend (decoded=true), push the parent
            // value to the next child as a floor.
            if (lvl > 0) {
                const child = &self.nodes[self.levels[lvl - 1].offset +
                    path_xy[lvl - 1].y * self.levels[lvl - 1].w + path_xy[lvl - 1].x];
                if (child.value < node.value) child.value = node.value;
            }

            if (node.value >= threshold) {
                // We've established the value is ≥ threshold at this
                // node, so the leaf's value is also ≥ threshold.
                return false;
            }
        }

        // We descended all the way down; the leaf's value is < threshold.
        return true;
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "TagTree: 1x1 trivial — single leaf, value coded by N zero bits + 1 one bit" {
    const allocator = std.testing.allocator;
    var tt = try TagTree.init(allocator, 1, 1);
    defer tt.deinit(allocator);

    // Encode leaf value = 3 against threshold = 4: read three 0
    // bits (each bumps value 0→1→2→3) then one 1 bit (decoded at
    // value = 3 < 4). With ff_stuffing off.
    var reader = BitReader.init(&.{0b00010000}, .{});
    const got = tt.read(&reader, 0, 0, 4);
    try std.testing.expectEqual(true, got); // value < 4
}

test "TagTree: 1x1 — threshold met by value reaches threshold (return false)" {
    const allocator = std.testing.allocator;
    var tt = try TagTree.init(allocator, 1, 1);
    defer tt.deinit(allocator);

    // Read three 0 bits → value advances 0→1→2→3 == threshold. Stop;
    // value >= threshold → return false. Only 3 bits consumed.
    var reader = BitReader.init(&.{0b00000000}, .{});
    const got = tt.read(&reader, 0, 0, 3);
    try std.testing.expectEqual(false, got);
    try std.testing.expectEqual(@as(usize, 3), tt.nodes[0].value);
}

test "TagTree: 2x2 — independent leaves with persistent state across calls" {
    const allocator = std.testing.allocator;
    var tt = try TagTree.init(allocator, 2, 2);
    defer tt.deinit(allocator);

    // Encode: root=0, all interior nodes propagate trivially.
    // Stream describes: for leaf (0,0) with threshold=1, value
    // coded as "1" (single 1 bit means value < 1). Root's first
    // refinement is the "1" bit: root.value = 1 = threshold → recurse.
    // Then leaf gets 1 bit too. So 2 bits per leaf check at thr=1.
    //
    // Encode leaf (0,0) = 0 with threshold = 1. Walk needs:
    //   - root: read "1" → decoded at value=0 < 1 → descend
    //   - leaf (0,0): read "1" → decoded at value=0 < 1 → return true
    // That's 2 bits. Then query leaf (1,1) with threshold = 1:
    //   - root: already decoded at value=0, no bits — descend
    //   - leaf (1,1): fresh node, read "1" → decoded at value=0 → true
    // That's 1 more bit, for a total of 3 → 0b11100000.
    var reader = BitReader.init(&.{0b11100000}, .{});
    const got_00 = tt.read(&reader, 0, 0, 1);
    try std.testing.expectEqual(true, got_00);
    const got_11 = tt.read(&reader, 1, 1, 1);
    try std.testing.expectEqual(true, got_11);
    try std.testing.expectEqual(@as(usize, 3), reader.byte_pos * 8 + reader.bit_pos);
}

test "TagTree: level count + node count for various sizes" {
    const allocator = std.testing.allocator;

    // 1×1 → 1 level, 1 node total.
    var tt1 = try TagTree.init(allocator, 1, 1);
    defer tt1.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), tt1.levels.len);
    try std.testing.expectEqual(@as(usize, 1), tt1.nodes.len);

    // 2×2 → 2 levels: 4 leaves + 1 root = 5 nodes.
    var tt2 = try TagTree.init(allocator, 2, 2);
    defer tt2.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), tt2.levels.len);
    try std.testing.expectEqual(@as(usize, 5), tt2.nodes.len);

    // 3×3 → 3 levels: 9 + ceil(3/2)*ceil(3/2)=4 + 1 = 14.
    var tt3 = try TagTree.init(allocator, 3, 3);
    defer tt3.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), tt3.levels.len);
    try std.testing.expectEqual(@as(usize, 14), tt3.nodes.len);

    // 4×4 → 3 levels: 16 + 4 + 1 = 21.
    var tt4 = try TagTree.init(allocator, 4, 4);
    defer tt4.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), tt4.levels.len);
    try std.testing.expectEqual(@as(usize, 21), tt4.nodes.len);
}

test "TagTree: read returns false on bit-stream EOF mid-walk" {
    const allocator = std.testing.allocator;
    var tt = try TagTree.init(allocator, 1, 1);
    defer tt.deinit(allocator);

    // Empty stream — readBit returns null immediately, read returns false.
    var reader = BitReader.init(&.{}, .{});
    try std.testing.expectEqual(false, tt.read(&reader, 0, 0, 5));
}
