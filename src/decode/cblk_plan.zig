//! Per-code-block decode plan — the output of the tier-2 walker, the
//! input to the tier-1 EBCOT dispatcher.
//!
//! As `codestream.walkPackets` parses each packet header, it
//! accumulates two things per code-block: (a) the total number of
//! EBCOT coding passes that have been contributed across every layer,
//! and (b) the concatenated compressed bytes for those passes (sliced
//! out of the tile-part body in packet iteration order). The
//! `CblkDecodePlan` captures everything `ebcot.decodeCblkPasses` needs
//! to actually decode the cblk to a coefficient array.
//!
//! Each plan also carries enough identifying context (tile, component,
//! resolution, band, cblk position) to be matched against an external
//! oracle (e.g. the JP2Z_DUMP_T1 records produced by our patched
//! OpenJPEG — see `patches/openjpeg-cblk-dump.patch`).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One codeword segment of a code-block (T.800 selective arithmetic
/// coding bypass / termination). For cblksty=0 a code-block is a single
/// MQ segment; LAZY (cblksty bit 0) and TERMALL (bit 2) split the
/// passes into multiple terminated segments, each with its own byte
/// length and (re-initialised) decoder. `passes` is how many EBCOT
/// coding passes this segment covers; `byte_len` is its slice length
/// inside `CblkDecodePlan.data` (segments are laid out in pass order).
pub const SegInfo = struct {
    passes: u32,
    byte_len: u32,
};

/// One code-block's worth of data ready for tier-1 decode. Owns the
/// `data` byte slice — caller must call `deinit` to release it (or
/// hand the plan to a `CblkDecodePlanList` which deinits in bulk).
pub const CblkDecodePlan = struct {
    /// Tile index within the codestream (0 for single-tile fixtures).
    tile: u32,
    /// Component index (0..num_components-1).
    component: u16,
    /// Resolution level (0 = LL band only; 1.. = HL / LH / HH triples).
    resolution: u8,
    /// Band orientation per T.800 — same value OpenJPEG calls `bandno`:
    /// 0 = LL @ r=0 OR HL @ r>=1, 1 = LH, 2 = HH.
    band: u8,
    /// Precinct index within (component, resolution). 0..num_precincts-1.
    precinct: u32,

    /// Subband-internal cblk bounds — matches the rect OpenJPEG's
    /// `opj_t1_decode_cblk` writes for `cblk->x0..y1`. Half the
    /// resolution-r scale for r>=1 high-frequency subbands.
    sb_x0: i32,
    sb_y0: i32,
    sb_x1: i32,
    sb_y1: i32,

    /// Number of zero bit-planes at the top of the magnitude range,
    /// from the per-cblk zero-bitplane tag tree.
    zero_bitplanes: u8,
    /// Number of magnitude bit-planes actually coded for this cblk:
    /// numbps = M_b - zero_bitplanes (T.800 E.1 + tag-tree result).
    /// Drives `msb_bp = numbps - 1` in the EBCOT dispatcher.
    numbps: u8,
    /// Per-subband quantization (expn, mant) for irreversible dequant,
    /// from the OWNING TILE's params — a tile-part-header QCD overrides
    /// the main header per tile (p1_04 carries one on 63 of 64 tiles),
    /// so the render path must not reach for a global QCD table.
    qcd_expn: u8 = 0,
    qcd_mant: u16 = 0,
    /// RGN ROI up-shift of the owning component (T.800 A.6.3). Already
    /// folded into `numbps` (coded planes = M_b + roishift - zero_bitplanes);
    /// reconstruction scales magnitudes >= 2^roishift back down (H.2).
    roishift: u8 = 0,
    /// Byte offset in the codestream of this cblk's FIRST contribution —
    /// the anchor a diagnostic finding points a consumer at (aggregate
    /// deep findings name their first offender; hunting an unanchored
    /// c253 across 64 tiles once needed a throwaway trace build).
    src_offset: usize = 0,
    /// Total EBCOT coding passes contributed to this cblk across all
    /// packets. Becomes the `total_passes` arg to `decodeCblkPasses`.
    total_passes: u32,
    /// Passes / bytes delivered by the cblk's FIRST packet contribution
    /// (its layer-0 share). Diagnostic: lets a tool decode the first layer
    /// alone and attribute a byte-budget anomaly to a later layer.
    first_passes: u32 = 0,
    first_len: u32 = 0,
    /// Code-block style flags (COD's `cblksty`). Drives segment
    /// boundaries inside the byte stream and a handful of other
    /// per-pass behaviours.
    cblksty: u8,

    /// Concatenated compressed bytes for every pass in `total_passes`.
    /// Owned by this plan — `deinit` frees it.
    data: []u8,

    /// Per-segment breakdown of `data` (pass order). Empty means
    /// "treat the whole cblk as one MQ segment" (the default for
    /// synthetic test plans). Real extracted plans always populate it.
    /// Heap-owned when non-empty; `deinit` frees it.
    segments: []const SegInfo = &.{},

    pub fn deinit(self: *CblkDecodePlan, allocator: Allocator) void {
        allocator.free(self.data);
        if (self.segments.len > 0) allocator.free(self.segments);
        self.* = undefined;
    }

    /// Cblk width in subband coordinates.
    pub fn width(self: CblkDecodePlan) u32 {
        return @intCast(self.sb_x1 - self.sb_x0);
    }
    /// Cblk height in subband coordinates.
    pub fn height(self: CblkDecodePlan) u32 {
        return @intCast(self.sb_y1 - self.sb_y0);
    }
};

/// Owns a slice of `CblkDecodePlan`s + their data buffers. Returned
/// by the walker; consumed by the tier-1 dispatcher.
pub const CblkDecodePlanList = struct {
    plans: []CblkDecodePlan,
    /// A tile-part COD changed decomposition/wavelet/MCT for some tile —
    /// see CblkExtractor.tile_override_unsupported.
    tile_override_unsupported: bool = false,

    pub fn deinit(self: *CblkDecodePlanList, allocator: Allocator) void {
        for (self.plans) |*p| p.deinit(allocator);
        allocator.free(self.plans);
        self.* = undefined;
    }
};

test "CblkDecodePlan: width/height derive from subband rect" {
    const buf = try std.testing.allocator.alloc(u8, 16);
    var plan: CblkDecodePlan = .{
        .tile = 0,
        .component = 0,
        .resolution = 5,
        .band = 1,
        .precinct = 0,
        .sb_x0 = 64,
        .sb_y0 = 0,
        .sb_x1 = 128,
        .sb_y1 = 64,
        .zero_bitplanes = 2,
        .numbps = 5,
        .total_passes = 7,
        .cblksty = 0,
        .data = buf,
    };
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 64), plan.width());
    try std.testing.expectEqual(@as(u32, 64), plan.height());
}

test "CblkDecodePlanList: deinit frees every plan + its data buffer" {
    const allocator = std.testing.allocator;
    const plans_buf = try allocator.alloc(CblkDecodePlan, 2);
    plans_buf[0] = .{
        .tile = 0, .component = 0, .resolution = 0, .band = 0, .precinct = 0,
        .sb_x0 = 0, .sb_y0 = 0, .sb_x1 = 4, .sb_y1 = 4,
        .zero_bitplanes = 0, .numbps = 8, .total_passes = 1, .cblksty = 0,
        .data = try allocator.alloc(u8, 8),
    };
    plans_buf[1] = .{
        .tile = 0, .component = 1, .resolution = 0, .band = 0, .precinct = 0,
        .sb_x0 = 0, .sb_y0 = 0, .sb_x1 = 4, .sb_y1 = 4,
        .zero_bitplanes = 0, .numbps = 8, .total_passes = 4, .cblksty = 0,
        .data = try allocator.alloc(u8, 16),
    };
    var list = CblkDecodePlanList{ .plans = plans_buf };
    list.deinit(allocator);
    // testing.allocator panics on leak; reaching this line means clean.
}
