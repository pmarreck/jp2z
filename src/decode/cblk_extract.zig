//! Top-level tier-2 → tier-1 bridge: walk a JP2/J2K codestream and
//! produce a `CblkDecodePlanList` ready for `ebcot.decodeCblkPasses`.
//!
//! Internally this reuses the existing codestream walker
//! (`codestream.validate`'s machinery) but plumbs a `CblkExtractor`
//! through `walkPackets` so per-cblk byte slices are captured as the
//! walker advances through each tile-part body. After the walk, the
//! extractor is finalised into a `CblkDecodePlanList`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const cblk_plan = @import("cblk_plan.zig");
const subbands = @import("subbands.zig");
const packet_header = @import("packet_header.zig");

pub const CblkDecodePlan = cblk_plan.CblkDecodePlan;
pub const CblkDecodePlanList = cblk_plan.CblkDecodePlanList;

/// Identifier for one cblk in the codestream — composite key used as
/// the lookup into the extractor's per-cblk byte buffer map.
pub const CblkKey = struct {
    tile: u32,
    component: u16,
    resolution: u8,
    band: u8,
    precinct: u32,
    grid_x: u32,
    grid_y: u32,
};

/// Per-cblk accumulation state. The walker calls `appendContribution`
/// once per packet contribution (skipping zero-length contributions).
/// After the walk, `finalize` produces the owned plan list.
pub const CblkExtractor = struct {
    allocator: Allocator,
    /// Per-cblk byte buffer + metadata captured on first sight.
    map: std.AutoHashMap(CblkKey, Entry),

    pub const Entry = struct {
        buffer: std.ArrayList(u8) = .empty,
        sb_x0: i32 = 0,
        sb_y0: i32 = 0,
        sb_x1: i32 = 0,
        sb_y1: i32 = 0,
        zero_bitplanes: u8 = 0,
        /// Per-subband M_b from QCD (= G_b + epsilon_b - 1). Combined
        /// with `zero_bitplanes` in `finalize` to yield plan.numbps.
        m_b: u8 = 0,
        cblksty: u8 = 0,
        total_passes: u32 = 0,
        /// Per-segment {passes, byte_len} (LAZY/TERMALL). Heap-owned
        /// copy of the latest CodeBlockState snapshot; freed in deinit
        /// or transferred to the plan in finalize.
        segments: []cblk_plan.SegInfo = &.{},
    };

    pub fn init(allocator: Allocator) CblkExtractor {
        return .{
            .allocator = allocator,
            .map = std.AutoHashMap(CblkKey, Entry).init(allocator),
        };
    }

    pub fn deinit(self: *CblkExtractor) void {
        var it = self.map.valueIterator();
        while (it.next()) |entry| {
            entry.buffer.deinit(self.allocator);
            if (entry.segments.len > 0) self.allocator.free(entry.segments);
        }
        self.map.deinit();
        self.* = undefined;
    }

    /// Record a per-packet contribution: appends `bytes` to the
    /// (tile, comp, ...) cblk's buffer, stamping subband rect /
    /// zero_bitplanes / cblksty on first sight. Updates total_passes
    /// to the running accumulated count (read from CodeBlockState
    /// after readPacketHeader returns).
    pub fn appendContribution(
        self: *CblkExtractor,
        key: CblkKey,
        bytes: []const u8,
        meta: struct {
            sb_x0: i32,
            sb_y0: i32,
            sb_x1: i32,
            sb_y1: i32,
            zero_bitplanes: u8,
            m_b: u8,
            cblksty: u8,
            total_passes: u32,
            segments: []const cblk_plan.SegInfo,
        },
    ) Allocator.Error!void {
        const gop = try self.map.getOrPut(key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .sb_x0 = meta.sb_x0,
                .sb_y0 = meta.sb_y0,
                .sb_x1 = meta.sb_x1,
                .sb_y1 = meta.sb_y1,
                .zero_bitplanes = meta.zero_bitplanes,
                .m_b = meta.m_b,
                .cblksty = meta.cblksty,
            };
        }
        gop.value_ptr.total_passes = meta.total_passes;
        try gop.value_ptr.buffer.appendSlice(self.allocator, bytes);
        // Store the latest per-segment snapshot (CodeBlockState grows it
        // across packets; the final call carries the complete list).
        if (gop.value_ptr.segments.len > 0) self.allocator.free(gop.value_ptr.segments);
        gop.value_ptr.segments = try self.allocator.dupe(cblk_plan.SegInfo, meta.segments);
    }

    /// Drain the accumulator into a CblkDecodePlanList. Caller owns
    /// the returned list and must deinit it.
    pub fn finalize(self: *CblkExtractor) Allocator.Error!CblkDecodePlanList {
        const count = self.map.count();
        const plans = try self.allocator.alloc(CblkDecodePlan, count);
        errdefer self.allocator.free(plans);

        var idx: usize = 0;
        var it = self.map.iterator();
        while (it.next()) |kv| {
            const key = kv.key_ptr.*;
            const entry = kv.value_ptr;
            // Take ownership of the buffer by toOwnedSlice — leaves an
            // empty ArrayList in the map, safe for the subsequent deinit.
            const data = try entry.buffer.toOwnedSlice(self.allocator);
            plans[idx] = .{
                .tile = key.tile,
                .component = key.component,
                .resolution = key.resolution,
                .band = key.band,
                .precinct = key.precinct,
                .sb_x0 = entry.sb_x0,
                .sb_y0 = entry.sb_y0,
                .sb_x1 = entry.sb_x1,
                .sb_y1 = entry.sb_y1,
                .zero_bitplanes = entry.zero_bitplanes,
                .numbps = if (entry.m_b > entry.zero_bitplanes) entry.m_b - entry.zero_bitplanes else 0,
                .total_passes = entry.total_passes,
                .cblksty = entry.cblksty,
                .data = data,
                .segments = entry.segments,
            };
            entry.segments = &.{}; // ownership moved to the plan
            idx += 1;
        }
        return .{ .plans = plans };
    }
};

test "CblkExtractor: init/deinit on empty extractor" {
    var ex = CblkExtractor.init(std.testing.allocator);
    defer ex.deinit();
    try std.testing.expectEqual(@as(u32, 0), ex.map.count());
}

test "CblkExtractor: append single contribution, finalize → 1 plan" {
    const allocator = std.testing.allocator;
    var ex = CblkExtractor.init(allocator);
    defer ex.deinit();
    const key: CblkKey = .{
        .tile = 0, .component = 0, .resolution = 5, .band = 1,
        .precinct = 0, .grid_x = 0, .grid_y = 0,
    };
    try ex.appendContribution(key, &.{ 0x12, 0x34, 0x56 }, .{
        .sb_x0 = 0, .sb_y0 = 0, .sb_x1 = 64, .sb_y1 = 64,
        .zero_bitplanes = 2, .m_b = 11, .cblksty = 0, .total_passes = 4,
        .segments = &.{},
    });
    var list = try ex.finalize();
    defer list.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), list.plans.len);
    const p = list.plans[0];
    try std.testing.expectEqual(@as(u8, 5), p.resolution);
    try std.testing.expectEqual(@as(u8, 1), p.band);
    try std.testing.expectEqual(@as(i32, 64), p.sb_x1);
    try std.testing.expectEqual(@as(u32, 4), p.total_passes);
    // numbps = m_b - zero_bitplanes = 11 - 2 = 9.
    try std.testing.expectEqual(@as(u8, 9), p.numbps);
    try std.testing.expectEqual(@as(usize, 3), p.data.len);
    try std.testing.expectEqual(@as(u8, 0x34), p.data[1]);
}

test "CblkExtractor: multiple appends to same key concatenate; metadata captured on first sight" {
    const allocator = std.testing.allocator;
    var ex = CblkExtractor.init(allocator);
    defer ex.deinit();
    const key: CblkKey = .{
        .tile = 0, .component = 0, .resolution = 0, .band = 0,
        .precinct = 0, .grid_x = 0, .grid_y = 0,
    };
    // First contribution sets metadata.
    try ex.appendContribution(key, &.{ 0xAA, 0xBB }, .{
        .sb_x0 = 0, .sb_y0 = 0, .sb_x1 = 16, .sb_y1 = 16,
        .zero_bitplanes = 1, .m_b = 9, .cblksty = 0, .total_passes = 1,
        .segments = &.{},
    });
    // Second contribution — different "meta", but only buffer + total_passes
    // should update. Subband rect / zero_bitplanes / cblksty must STAY the
    // values from the first sight (those are codestream-invariants, not
    // per-packet quantities).
    try ex.appendContribution(key, &.{ 0xCC, 0xDD, 0xEE }, .{
        .sb_x0 = 99, .sb_y0 = 99, .sb_x1 = 0, .sb_y1 = 0, // bogus
        .zero_bitplanes = 99, .m_b = 99, .cblksty = 99, .total_passes = 5,
        .segments = &.{},
    });
    var list = try ex.finalize();
    defer list.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), list.plans.len);
    const p = list.plans[0];
    // Buffer concatenates: 2 + 3 = 5 bytes.
    try std.testing.expectEqual(@as(usize, 5), p.data.len);
    try std.testing.expectEqual(@as(u8, 0xAA), p.data[0]);
    try std.testing.expectEqual(@as(u8, 0xEE), p.data[4]);
    // Metadata frozen on first sight.
    try std.testing.expectEqual(@as(i32, 16), p.sb_x1);
    try std.testing.expectEqual(@as(u8, 1), p.zero_bitplanes);
    try std.testing.expectEqual(@as(u8, 0), p.cblksty);
    // total_passes monotonically updated.
    try std.testing.expectEqual(@as(u32, 5), p.total_passes);
}

test "CblkExtractor: multiple distinct keys produce multiple plans" {
    const allocator = std.testing.allocator;
    var ex = CblkExtractor.init(allocator);
    defer ex.deinit();
    const k0: CblkKey = .{ .tile = 0, .component = 0, .resolution = 0, .band = 0, .precinct = 0, .grid_x = 0, .grid_y = 0 };
    const k1: CblkKey = .{ .tile = 0, .component = 0, .resolution = 1, .band = 1, .precinct = 0, .grid_x = 0, .grid_y = 0 };
    try ex.appendContribution(k0, &.{0x01}, .{ .sb_x0 = 0, .sb_y0 = 0, .sb_x1 = 4, .sb_y1 = 4, .zero_bitplanes = 0, .m_b = 8, .cblksty = 0, .total_passes = 1, .segments = &.{} });
    try ex.appendContribution(k1, &.{0x02}, .{ .sb_x0 = 0, .sb_y0 = 0, .sb_x1 = 8, .sb_y1 = 8, .zero_bitplanes = 0, .m_b = 9, .cblksty = 0, .total_passes = 1, .segments = &.{} });
    var list = try ex.finalize();
    defer list.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), list.plans.len);
}
