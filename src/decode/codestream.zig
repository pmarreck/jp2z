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
const BitReader = @import("bit_reader.zig").BitReader;
const subbands = @import("subbands.zig");
const packet_header = @import("packet_header.zig");
const cblk_extract = @import("cblk_extract.zig");
pub const Severity = errors.Severity;
const Variant = errors.Variant;
pub const FindingCode = errors.FindingCode;
const Finding = jp2z.Finding;
pub const ValidationReport = jp2z.ValidationReport;

/// Tier-2 progression order (T.800 A.6.1, byte 1 of SGcod).
pub const ProgressionOrder = enum(u8) {
    lrcp = 0, // Layer-Resolution-Component-Precinct
    rlcp = 1, // Resolution-Layer-Component-Precinct
    rpcl = 2, // Resolution-Precinct-Component-Layer
    pcrl = 3, // Precinct-Component-Resolution-Layer
    cprl = 4, // Component-Precinct-Resolution-Layer
};

/// Wavelet transform (T.800 A.6.1, SPcod qmfbid byte).
pub const WaveletFilter = enum(u8) {
    irreversible_9x7 = 0, // lossy
    reversible_5x3 = 1, // lossless
};

/// One POC (progression order change, T.800 A.6.6) entry: a "progression
/// volume" bounding the layers/resolutions/components whose packets are
/// sequenced in `order`. Marker values are stored RAW (unclamped); the
/// packet sequencer clamps against the tile's actual geometry at iteration
/// time — mirroring openjpeg, which stores raw pocs and clamps in pi.c
/// (T.800 lets REpoc/CEpoc legally exceed the stream's counts, e.g. the
/// common "255 = all components").
pub const PocEntry = struct {
    rs: u8, // RSpoc — first resolution (inclusive)
    cs: u16, // CSpoc — first component (inclusive)
    lye: u16, // LYEpoc — layer end (exclusive; every volume starts at layer 0)
    re: u8, // REpoc — resolution end (exclusive)
    ce: u16, // CEpoc — component end (exclusive)
    order: ProgressionOrder, // Ppoc
};

/// openjpeg caps a tile's accumulated POC list at 32 entries
/// (`opj_poc_t pocs[32]`); we mirror the cap and FAIL past it rather than
/// silently truncate the progression description.
pub const max_pocs = 32;

/// Snapshot of the codec parameters needed to drive tier-2 packet
/// walking. Populated during the main-header walk:
///   - `num_components` from SIZ (Csiz)
///   - everything else from COD (SGcod + SPcod)
///
/// `null` on the report means "not enough of the main header was
/// parsed for these to be meaningful." Once the walker reaches
/// parseSizBody it's populated with defaults that parseCodBody
/// then overwrites.
/// Precinct partition exponents at one resolution level.
/// Real precinct dims = 2^x × 2^y on the resolution-r reference
/// grid (or in the subband space for r ≥ 1, dimensions are
/// 2^(x-1) × 2^(y-1) after the wavelet-induced halving).
pub const PrecinctSize = packed struct(u8) {
    x_exp: u4 = 15, // PPx — default 2^15 covers any practical image
    y_exp: u4 = 15, // PPy
};

pub const CodingParams = struct {
    progression_order: ProgressionOrder = .lrcp,
    num_layers: u16 = 0,
    num_components: u16 = 0,
    num_decomp_levels: u8 = 0,
    /// Actual code-block width  = 2^(cblk_width_exp + 2).
    cblk_width_exp: u8 = 0,
    cblk_height_exp: u8 = 0,
    wavelet: WaveletFilter = .reversible_5x3,
    mct: bool = false,
    /// T.800 A.6.1 Table A.19. Bitfield:
    ///   bit 0 LAZY    — selective arithmetic-coding bypass
    ///   bit 1 RESET   — reset MQ context probabilities
    ///   bit 2 TERMALL — terminate after each coding pass
    ///   bit 3 VSC     — vertically-caused contexts
    ///   bit 4 PTERM   — predictable termination
    ///   bit 5 SEGSYM  — segmentation symbols
    /// Affects packet-header per-cblk segment splitting: with
    /// LAZY, the first 10 coding passes form segment 0; raw and
    /// arithmetic passes thereafter alternate into 1- and 2-pass
    /// segments, each with its own length value.
    cblksty: u8 = 0,
    /// Scod (COD body byte 0). Bit 0 = user-defined precincts;
    /// bit 1 = SOP markers; bit 2 = EPH markers. The other bits
    /// are reserved per T.800.
    scod: u8 = 0,
    /// Precinct exponents per resolution (index = resolution r,
    /// r ∈ [0, num_decomp_levels]). When Scod bit 0 = 0 (default
    /// precincts), every slot stays at (15, 15) = 2^15 × 2^15
    /// (effectively infinity vs any practical image, giving one
    /// precinct per resolution per subband). When Scod bit 0 = 1
    /// the values come from the COD body trailing bytes (one byte
    /// per resolution: low nibble = PPx, high nibble = PPy).
    precinct_sizes: [33]PrecinctSize = @splat(.{}),
    /// Guard bits G_b from Sqcd high 3 bits (0..7). Applies to every
    /// subband.
    guard_bits: u8 = 0,
    /// Quantization style from Sqcd low 5 bits: 0 = no-quant
    /// (reversible / 5/3), 1 = scalar derived, 2 = scalar expounded.
    quant_style: u8 = 0,
    /// Per-subband number of magnitude bit-planes
    /// M_b = G_b + epsilon_b - 1 (T.800 E.1). Indexed by subband index:
    ///   r = 0:          subband_idx = 0   (only LL exists)
    ///   r >= 1, band b: subband_idx = 3*(r-1) + b  (b in {1,2,3} for HL/LH/HH)
    /// Length 1 + 3*32 = 97 covers num_decomp_levels up to 32.
    mb_per_subband: [97]u8 = @splat(0),
    /// Per-component precision (bit depth) from SIZ Ssiz low 7 bits + 1.
    /// Indexed by component; up to 16 captured (enough for our fixtures).
    comp_prec: [16]u8 = @splat(8),
    /// Per-component signedness (SIZ Ssiz bit 7) as a bitmask by component.
    comp_signed: u16 = 0,
    /// Per-component horizontal/vertical sub-sampling (SIZ XRsiz/YRsiz).
    /// Component samples live on a grid 1/dx × 1/dy of the reference grid
    /// (T.800 B.2). Default 1 (no sub-sampling). Index = component.
    comp_dx: [16]u8 = @splat(1),
    comp_dy: [16]u8 = @splat(1),
    /// Per-subband quantization exponent (irreversible). Index matches
    /// mb_per_subband / stepsizes order: [0]=LL@r0, then 3 per resolution.
    qcd_expn: [97]u8 = @splat(0),
    /// Per-subband quantization mantissa (11-bit) for irreversible dequant.
    qcd_mant: [97]u16 = @splat(0),
    /// SIZ tile-grid geometry (for multi-tile, M6 cont.). Single-tile
    /// files have tile_w/h >= image and origins 0 (whole image = one tile).
    image_x0: u32 = 0, // XOsiz
    image_y0: u32 = 0, // YOsiz
    tile_x0: u32 = 0, // XTOsiz
    tile_y0: u32 = 0, // YTOsiz
    tile_w: u32 = 0, // XTsiz (0 until SIZ parsed)
    tile_h: u32 = 0, // YTsiz
    /// Progression order changes (T.800 A.6.6). Main-header POC entries
    /// land here and seed every tile's packet-walk sequencer; tile-part
    /// POC entries then ACCUMULATE onto the owning tile's walk, mirroring
    /// openjpeg's opj_j2k_read_poc (which appends across tile-parts).
    pocs: [max_pocs]PocEntry = @splat(.{ .rs = 0, .cs = 0, .lye = 0, .re = 0, .ce = 0, .order = .lrcp }),
    num_pocs: u8 = 0,

    /// Look up M_b for a (resolution, band) pair. `band` follows the
    /// OpenJPEG convention: 0=LL@r=0, 1=HL, 2=LH, 3=HH.
    pub fn mbForSubband(self: CodingParams, r: u8, band: u8) u8 {
        if (r == 0) return self.mb_per_subband[0];
        return self.mb_per_subband[@as(usize, 3) * (@as(usize, r) - 1) + @as(usize, band)];
    }

    /// Subband index in QCD/stepsizes order for (resolution, bandno).
    pub fn subbandIndex(r: u8, band: u8) usize {
        if (r == 0) return 0;
        return @as(usize, 3) * (@as(usize, r) - 1) + @as(usize, band);
    }

    pub const TileRect = struct { x0: u32, y0: u32, x1: u32, y1: u32 };

    /// Number of tiles across (x) and down (y). 1x1 for single-tile.
    pub fn numTilesXY(self: CodingParams, xsiz: u32, ysiz: u32) struct { x: u32, y: u32 } {
        if (self.tile_w == 0 or self.tile_h == 0) return .{ .x = 1, .y = 1 };
        const nx = (xsiz - self.tile_x0 + self.tile_w - 1) / self.tile_w;
        const ny = (ysiz - self.tile_y0 + self.tile_h - 1) / self.tile_h;
        return .{ .x = @max(1, nx), .y = @max(1, ny) };
    }

    /// Component-coordinate rect of tile `isot` (T.800 B.3). xsiz/ysiz are
    /// the absolute SIZ image extents (image_x0+width, image_y0+height).
    pub fn tileRect(self: CodingParams, xsiz: u32, ysiz: u32, isot: u32) TileRect {
        const nt = self.numTilesXY(xsiz, ysiz);
        const p = isot % nt.x; // tile column
        const q = isot / nt.x; // tile row
        const x0 = @max(self.tile_x0 + p * self.tile_w, self.image_x0);
        const y0 = @max(self.tile_y0 + q * self.tile_h, self.image_y0);
        const x1 = @min(self.tile_x0 + (p + 1) * self.tile_w, xsiz);
        const y1 = @min(self.tile_y0 + (q + 1) * self.tile_h, ysiz);
        return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
    }
};

/// One emission of the tier-2 packet iterator. Identifies which
/// (layer, resolution, component, precinct) tuple's packet should
/// be processed next, in the order dictated by the progression-order
/// field of `CodingParams`. T.800 B.12 specifies the iteration
/// semantics; we materialise it here as a pull-based iterator so
/// the validator (and eventually the decoder) can stream through
/// packets without allocating an enumeration up-front.
pub const PacketIndex = struct {
    layer: u16,
    resolution: u8,
    component: u16,
    precinct: u32,
};

/// Cursor over the Cartesian product (layers × resolutions ×
/// components × precincts) plus per-resolution variable precinct
/// counts, traversed in the nesting order specified by
/// `progression_order`. Per T.800 B.12.1:
///
///   - LRCP / RLCP: indexed iteration. At each resolution r the
///     precinct dim cycles over P(r) = numPrecincts(image, r).
///   - RPCL: per-resolution reference-grid iteration. Each r uses
///     its OWN stride 2^(PPx_r + R - r) on the reference grid.
///   - PCRL / CPRL: reference-grid iteration with the MIN stride
///     across all resolutions. At each (x, y) we emit packets only
///     for those (r, c) where (x, y) lies on r's precinct boundary.
pub const PacketIterator = struct {
    params: CodingParams,
    /// Tile-component ORIGIN (tcx0, tcy0). Non-zero for interior tiles of a
    /// multi-tile image. CRITICAL: the per-resolution precinct geometry
    /// depends on the ABSOLUTE origin, not just the size — a small interior
    /// tile whose coarse resolutions collapse to zero extent has FEWER
    /// packets than the same-size tile at origin 0 would. Getting this wrong
    /// makes the iterator emit phantom packets for empty resolutions and
    /// desync the whole tile's byte stream (the b1_mono image-origin bug).
    tile_x0: u32,
    tile_y0: u32,
    image_w: u32,
    image_h: u32,

    /// Cached per-resolution geometry. Index r ∈ [0, num_decomp_levels].
    precincts_at_r: [33]u32 = @splat(0),
    pcw_at_r: [33]u32 = @splat(0),
    pch_at_r: [33]u32 = @splat(0),
    ref_stride_x_at_r: [33]u32 = @splat(1),
    ref_stride_y_at_r: [33]u32 = @splat(1),
    /// Reference-grid step for PCRL / CPRL outer iteration.
    min_stride_x: u32 = 1,
    min_stride_y: u32 = 1,

    /// Cursor state. Semantics depend on `progression_order`:
    ///   - LRCP / RLCP: (layer, resolution, component, precinct).
    ///   - RPCL: (resolution, y, x, component, layer). Precinct is
    ///     derived from (r, x, y) at emit time.
    ///   - PCRL / CPRL: (y, x, component-or-not, resolution, layer)
    ///     with (r) filtered on-boundary at (x, y).
    layer: u16 = 0,
    resolution: u8 = 0,
    component: u16 = 0,
    precinct: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,

    done: bool = false,

    pub fn init(params: CodingParams, tile_x0: u32, tile_y0: u32, image_w: u32, image_h: u32) PacketIterator {
        var iter: PacketIterator = .{
            .params = params,
            .tile_x0 = tile_x0,
            .tile_y0 = tile_y0,
            .image_w = image_w,
            .image_h = image_h,
            // Positional orders (RPCL/PCRL/CPRL) iterate the ABSOLUTE
            // reference-grid span [tx0, tx0+w) × [ty0, ty0+h) — openjpeg
            // pi.c's poc.tx0..tx1 — so the cursor starts at the tile
            // origin, not 0. LRCP/RLCP ignore (x, y).
            .x = tile_x0,
            .y = tile_y0,
        };
        const num_resolutions: u8 = params.num_decomp_levels + 1;
        var min_sx: u32 = std.math.maxInt(u32);
        var min_sy: u32 = std.math.maxInt(u32);
        var any_precincts: bool = false;
        var r: u8 = 0;
        while (r < num_resolutions) : (r += 1) {
            const ppx: u4 = @intCast(params.precinct_sizes[r].x_exp);
            const ppy: u4 = @intCast(params.precinct_sizes[r].y_exp);
            const grid = subbands.numPrecincts(
                tile_x0, tile_y0, image_w, image_h, params.num_decomp_levels, r, ppx, ppy);
            iter.pcw_at_r[r] = grid.width;
            iter.pch_at_r[r] = grid.height;
            iter.precincts_at_r[r] = grid.width * grid.height;
            if (iter.precincts_at_r[r] > 0) any_precincts = true;
            const stride = subbands.referenceGridStride(
                params.num_decomp_levels, r, ppx, ppy);
            iter.ref_stride_x_at_r[r] = stride.width;
            iter.ref_stride_y_at_r[r] = stride.height;
            if (stride.width < min_sx) min_sx = stride.width;
            if (stride.height < min_sy) min_sy = stride.height;
        }
        iter.min_stride_x = if (num_resolutions > 0) min_sx else 1;
        iter.min_stride_y = if (num_resolutions > 0) min_sy else 1;

        iter.done = params.num_layers == 0 or
            num_resolutions == 0 or
            params.num_components == 0 or
            image_w == 0 or image_h == 0 or
            !any_precincts;
        return iter;
    }

    pub fn total(self: PacketIterator) usize {
        const num_resolutions: u8 = self.params.num_decomp_levels + 1;
        var total_p: usize = 0;
        var r: u8 = 0;
        while (r < num_resolutions) : (r += 1) {
            total_p += @as(usize, self.precincts_at_r[r]);
        }
        return @as(usize, self.params.num_layers) *
            total_p *
            @as(usize, self.params.num_components);
    }

    pub fn next(self: *PacketIterator) ?PacketIndex {
        if (self.done) return null;
        return switch (self.params.progression_order) {
            .lrcp, .rlcp => self.nextIndexed(),
            .rpcl => self.nextRpcl(),
            .pcrl, .cprl => self.nextPositional(),
        };
    }

    // ── LRCP / RLCP — indexed iteration with per-r precinct count ──

    fn nextIndexed(self: *PacketIterator) ?PacketIndex {
        // Skip any resolution with zero precincts. A resolution collapses to
        // zero extent (⇒ zero precincts) when the tile-component's absolute
        // origin pushes its coarse levels below one reference-grid cell — a
        // small interior tile of a multi-tile image. Such a resolution
        // contributes NO packets (that is exactly what `total()` counts, and
        // what openjpeg emits). Without this skip the iterator emits a phantom
        // packet per empty resolution and desyncs the whole tile's byte stream
        // (the b1_mono narrow-tile bug).
        while (self.precincts_at_r[self.resolution] == 0) {
            self.advanceIndexed();
            if (self.done) return null;
        }
        const result: PacketIndex = .{
            .layer = self.layer,
            .resolution = self.resolution,
            .component = self.component,
            .precinct = self.precinct,
        };
        self.advanceIndexed();
        return result;
    }

    fn advanceIndexed(self: *PacketIterator) void {
        const num_resolutions: u8 = self.params.num_decomp_levels + 1;
        const dims: [4]Dim = switch (self.params.progression_order) {
            .lrcp => .{ .layer, .resolution, .component, .precinct },
            .rlcp => .{ .resolution, .layer, .component, .precinct },
            else => unreachable,
        };
        // dims is outer→inner; we carry inner→outer.
        var i: usize = dims.len;
        while (i > 0) {
            i -= 1;
            switch (dims[i]) {
                .layer => {
                    self.layer += 1;
                    if (self.layer < self.params.num_layers) return;
                    self.layer = 0;
                },
                .resolution => {
                    self.resolution += 1;
                    if (self.resolution < num_resolutions) {
                        // New resolution → reset precinct (precinct
                        // count is per-r). Component is untouched.
                        self.precinct = 0;
                        return;
                    }
                    self.resolution = 0;
                    self.precinct = 0;
                },
                .component => {
                    self.component += 1;
                    if (self.component < self.params.num_components) return;
                    self.component = 0;
                },
                .precinct => {
                    self.precinct += 1;
                    if (self.precinct < self.precincts_at_r[self.resolution]) return;
                    self.precinct = 0;
                },
            }
        }
        self.done = true;
    }

    // ── RPCL — resolution outer; each r uses its OWN stride ──

    fn nextRpcl(self: *PacketIterator) ?PacketIndex {
        // A visited position can be a non-emitter only at the tile-origin
        // row/col when the tile's r-level origin IS precinct-aligned (the
        // partial-precinct edge case doesn't apply) yet the origin itself
        // isn't a stride multiple — skip such positions without emitting.
        // Zero-precinct (collapsed) resolutions contribute no packets.
        while (!self.done) {
            const r = self.resolution;
            const ppx: u4 = @intCast(self.params.precinct_sizes[r].x_exp);
            const ppy: u4 = @intCast(self.params.precinct_sizes[r].y_exp);
            if (self.precincts_at_r[r] == 0 or
                !subbands.isOnPrecinctBoundary(
                    self.tile_x0, self.tile_y0, self.params.num_decomp_levels,
                    r, ppx, ppy, self.x, self.y))
            {
                self.advanceRpclPosition();
                continue;
            }
            const p_idx = subbands.precinctIndexAt(
                self.tile_x0, self.tile_y0, self.image_w, self.image_h, self.params.num_decomp_levels,
                r, ppx, ppy, self.x, self.y);
            const result: PacketIndex = .{
                .layer = self.layer,
                .resolution = r,
                .component = self.component,
                .precinct = p_idx,
            };
            self.advanceRpcl();
            return result;
        }
        return null;
    }

    fn advanceRpcl(self: *PacketIterator) void {
        // Nesting (inner→outer): l, c, x, y, r.
        self.layer += 1;
        if (self.layer < self.params.num_layers) return;
        self.layer = 0;
        self.component += 1;
        if (self.component < self.params.num_components) return;
        self.component = 0;
        self.advanceRpclPosition();
    }

    /// Advance the RPCL position cursor (x → y → r) by the CURRENT
    /// resolution's own stride, stepping to the next stride MULTIPLE on
    /// the absolute reference grid (openjpeg's `x += dx - (x % dx)` — an
    /// unaligned tile origin steps to the grid, not by a fixed offset)
    /// and resetting carries to the tile origin, not 0.
    fn advanceRpclPosition(self: *PacketIterator) void {
        const sx = self.ref_stride_x_at_r[self.resolution];
        const sy = self.ref_stride_y_at_r[self.resolution];
        self.x += sx - (self.x % sx);
        if (self.x < self.tile_x0 + self.image_w) return;
        self.x = self.tile_x0;
        self.y += sy - (self.y % sy);
        if (self.y < self.tile_y0 + self.image_h) return;
        self.y = self.tile_y0;
        self.resolution += 1;
        if (self.resolution < self.params.num_decomp_levels + 1) return;
        self.done = true;
    }

    // ── PCRL / CPRL — reference-grid outer; (r) filtered on-boundary ──

    fn nextPositional(self: *PacketIterator) ?PacketIndex {
        const num_resolutions: u8 = self.params.num_decomp_levels + 1;
        // At entry, (x, y, c, r, l) is the *candidate* state. The
        // outer loop skips past invalid r (not on its own precinct
        // boundary at (x, y)) and advances the outer dims when
        // necessary. Emits when current r is on boundary.
        while (!self.done) {
            // Find the next r ≥ self.resolution that is on boundary
            // at (x, y) for the current precinct exponents. Collapsed
            // (zero-precinct) resolutions contribute no packets.
            while (self.resolution < num_resolutions) {
                const ppx: u4 = @intCast(self.params.precinct_sizes[self.resolution].x_exp);
                const ppy: u4 = @intCast(self.params.precinct_sizes[self.resolution].y_exp);
                if (self.precincts_at_r[self.resolution] != 0 and
                    subbands.isOnPrecinctBoundary(
                        self.tile_x0, self.tile_y0,
                        self.params.num_decomp_levels, self.resolution,
                        ppx, ppy, self.x, self.y))
                {
                    break;
                }
                self.resolution += 1;
            }
            if (self.resolution < num_resolutions) {
                const r = self.resolution;
                const ppx: u4 = @intCast(self.params.precinct_sizes[r].x_exp);
                const ppy: u4 = @intCast(self.params.precinct_sizes[r].y_exp);
                const p_idx = subbands.precinctIndexAt(
                    self.tile_x0, self.tile_y0, self.image_w, self.image_h, self.params.num_decomp_levels,
                    r, ppx, ppy, self.x, self.y);
                const result: PacketIndex = .{
                    .layer = self.layer,
                    .resolution = r,
                    .component = self.component,
                    .precinct = p_idx,
                };
                // Advance: l → r → (carry to next-outer dim per order)
                self.layer += 1;
                if (self.layer < self.params.num_layers) return result;
                self.layer = 0;
                self.resolution += 1; // next candidate r
                return result;
            }
            // No more valid r at current (x, y, c). Reset r and carry
            // to the next outer dim per progression order.
            self.resolution = 0;
            // Position stepping is to the next stride MULTIPLE on the
            // absolute reference grid (openjpeg's `x += dx - (x % dx)`):
            // from an unaligned tile origin (e1_colr tile 1: x0=80,
            // stride 32) the next positions are 96, 128 — NOT 112, 144.
            // Carries reset to the tile origin, not 0.
            switch (self.params.progression_order) {
                .pcrl => {
                    // Inner→outer past r: c, x, y.
                    self.component += 1;
                    if (self.component < self.params.num_components) continue;
                    self.component = 0;
                    self.x += self.min_stride_x - (self.x % self.min_stride_x);
                    if (self.x < self.tile_x0 + self.image_w) continue;
                    self.x = self.tile_x0;
                    self.y += self.min_stride_y - (self.y % self.min_stride_y);
                    if (self.y < self.tile_y0 + self.image_h) continue;
                    self.done = true;
                },
                .cprl => {
                    // Inner→outer past r: x, y, c.
                    self.x += self.min_stride_x - (self.x % self.min_stride_x);
                    if (self.x < self.tile_x0 + self.image_w) continue;
                    self.x = self.tile_x0;
                    self.y += self.min_stride_y - (self.y % self.min_stride_y);
                    if (self.y < self.tile_y0 + self.image_h) continue;
                    self.y = self.tile_y0;
                    self.component += 1;
                    if (self.component < self.params.num_components) continue;
                    self.done = true;
                },
                else => unreachable,
            }
        }
        return null;
    }

    const Dim = enum { layer, resolution, component, precinct };
};

/// Sequences a tile's packets through its POC progression volumes
/// (T.800 A.6.6 / B.12.1): each volume is walked in ITS OWN progression
/// order, filtered to the volume's (layer, resolution, component) box, and
/// a shared inclusion set guarantees a packet emitted by an earlier volume
/// is never emitted again (B.12.1's "shall not be included again" —
/// openjpeg pi.c shares one `include` map across its per-POC iterators the
/// same way). Filtering a FULL-range iterator preserves within-volume order
/// and matches openjpeg, whose positional strides (dx/dy) are likewise
/// derived from all resolutions, not the POC box. Volumes may be appended
/// mid-walk (a later tile-part header carrying another POC — e1_colr's
/// tile 1); an exhausted sequencer revives when that happens. With no POC
/// entries this degrades to the bare PacketIterator: zero allocation,
/// byte-identical behavior.
pub const PocSequencer = struct {
    inner: PacketIterator,
    volumes: [max_pocs]PocEntry = @splat(.{ .rs = 0, .cs = 0, .lye = 0, .re = 0, .ce = 0, .order = .lrcp }),
    num_volumes: u8 = 0,
    /// Index of the volume `inner` is currently iterating. == num_volumes
    /// when every declared volume is exhausted.
    cur: u8 = 0,
    /// Shared already-emitted set, lazily allocated on the first appended
    /// volume. Index = canonical (l, r, c, p) packet index (layer-major).
    include: ?[]bool = null,
    /// rc_offset[r] = Σ_{r'<r} precincts(r')·Csiz — the within-layer base
    /// of resolution r in the canonical index. rc_total = one layer's span.
    rc_offset: [33]usize = @splat(0),
    rc_total: usize = 0,
    /// Packets already emitted in NO-VOLUME passthrough mode. If a POC
    /// arrives after passthrough packets were pulled (a late tile-part POC
    /// on a tile whose earlier parts had none), the first appendVolumes
    /// replays this many packets of the COD-order iteration into `include`
    /// so the volumes don't re-emit them.
    passthrough_pulled: usize = 0,

    pub fn init(params: CodingParams, tile_x0: u32, tile_y0: u32, image_w: u32, image_h: u32) PocSequencer {
        var seq: PocSequencer = .{
            .inner = PacketIterator.init(params, tile_x0, tile_y0, image_w, image_h),
        };
        const num_resolutions: u8 = params.num_decomp_levels + 1;
        var acc: usize = 0;
        var r: u8 = 0;
        while (r < num_resolutions) : (r += 1) {
            seq.rc_offset[r] = acc;
            acc += @as(usize, seq.inner.precincts_at_r[r]) * @as(usize, params.num_components);
        }
        seq.rc_total = acc;
        return seq;
    }

    pub fn deinit(self: *PocSequencer, allocator: Allocator) void {
        if (self.include) |inc| allocator.free(inc);
        self.include = null;
    }

    /// Total distinct packets of the tile's full (l, r, c, p) box —
    /// unchanged by POC (a conforming POC list covers exactly this set;
    /// the shared include set caps emission at it).
    pub fn total(self: PocSequencer) usize {
        return self.inner.total();
    }

    /// Append POC volumes: main-header defaults at TileWalk init, then
    /// tile-part-header POCs as each part's header is scanned (accumulating
    /// per tile, as openjpeg's opj_j2k_read_poc does). Revives an exhausted
    /// sequencer so the next tile-part's body walks the new volumes.
    pub fn appendVolumes(self: *PocSequencer, allocator: Allocator, entries: []const PocEntry) Allocator.Error!void {
        if (entries.len == 0) return;
        if (self.include == null) {
            const inc = try allocator.alloc(bool, self.inner.total());
            @memset(inc, false);
            self.include = inc;
            if (self.passthrough_pulled > 0) {
                // Late first POC: mark the passthrough-emitted prefix (the
                // first N packets of the COD-order iteration) as included.
                var replay = PacketIterator.init(self.inner.params, self.inner.tile_x0, self.inner.tile_y0, self.inner.image_w, self.inner.image_h);
                var n: usize = 0;
                while (n < self.passthrough_pulled) : (n += 1) {
                    const pi = replay.next() orelse break;
                    self.include.?[self.indexOf(pi)] = true;
                }
            }
        }
        const was_idle = self.cur >= self.num_volumes;
        for (entries) |e| {
            // Past the cap the parser already emitted a FAIL finding;
            // dropping the excess here keeps the walk deterministic.
            if (self.num_volumes >= max_pocs) break;
            self.volumes[self.num_volumes] = e;
            self.num_volumes += 1;
        }
        if (was_idle and self.cur < self.num_volumes) self.rebuildInner();
    }

    /// Point `inner` at the current volume: a fresh FULL-range iterator in
    /// the volume's progression order (emission is filtered in next()).
    fn rebuildInner(self: *PocSequencer) void {
        var p = self.inner.params;
        p.progression_order = self.volumes[self.cur].order;
        self.inner = PacketIterator.init(p, self.inner.tile_x0, self.inner.tile_y0, self.inner.image_w, self.inner.image_h);
    }

    /// Canonical layer-major packet index for the include set.
    fn indexOf(self: *const PocSequencer, pi: PacketIndex) usize {
        return @as(usize, pi.layer) * self.rc_total +
            self.rc_offset[pi.resolution] +
            @as(usize, pi.component) * @as(usize, self.inner.precincts_at_r[pi.resolution]) +
            @as(usize, pi.precinct);
    }

    pub fn next(self: *PocSequencer) ?PacketIndex {
        if (self.num_volumes == 0) {
            const pi = self.inner.next() orelse return null;
            self.passthrough_pulled += 1;
            return pi;
        }
        const inc = self.include.?;
        while (true) {
            if (self.cur >= self.num_volumes) return null;
            const vol = self.volumes[self.cur];
            if (self.inner.next()) |pi| {
                // Volume box filter. RAW POC bounds; the iterator already
                // confines emission to the tile's real geometry, so an
                // oversized re/ce (e.g. "255 = all") clamps naturally.
                if (pi.resolution < vol.rs or pi.resolution >= vol.re) continue;
                if (pi.component < vol.cs or pi.component >= vol.ce) continue;
                if (pi.layer >= vol.lye) continue;
                const idx = self.indexOf(pi);
                if (inc[idx]) continue;
                inc[idx] = true;
                return pi;
            }
            // Current volume exhausted — advance to the next declared one.
            self.cur += 1;
            if (self.cur < self.num_volumes) self.rebuildInner();
        }
    }
};

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
        try walkJp2(&report, allocator, data, null);
        return report;
    }

    // J2K raw codestream: SOC magic.
    if (data.len >= 2 and data[0] == 0xFF and data[1] == 0x4F) {
        try walkJ2k(&report, allocator, data, null);
        return report;
    }

    try emit(&report, allocator, .fail, .missing_soi, 0, null);
    return report;
}

/// Walk a JP2/J2K codestream like `validate` does, but also collect a
/// `CblkDecodePlanList` containing every code-block's accumulated byte
/// slice + total coding pass count + subband-internal rect. Hands the
/// list off to the tier-1 EBCOT dispatcher (M3 brick 9d → 9e).
///
/// Errors only on allocator failure; structurally-broken codestreams
/// return whatever plans were extracted before the walker hit trouble
/// (the parallel `validate()` call surfaces the failure as a Finding).
pub fn extractCblkPlans(
    allocator: Allocator,
    data: []const u8,
) Allocator.Error!cblk_extract.CblkDecodePlanList {
    var report = ValidationReport{
        .overall = .pass,
        .variant = .unknown,
        .width = null,
        .height = null,
        .findings = .empty,
    };
    defer report.deinit(allocator);

    var extractor = cblk_extract.CblkExtractor.init(allocator);
    errdefer extractor.deinit();

    if (looksLikeJp2(data)) {
        try walkJp2(&report, allocator, data, &extractor);
    } else if (data.len >= 2 and data[0] == 0xFF and data[1] == 0x4F) {
        try walkJ2k(&report, allocator, data, &extractor);
    }

    const list = try extractor.finalize();
    extractor.deinit();
    return list;
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
fn walkJp2(report: *ValidationReport, allocator: Allocator, data: []const u8, extractor: ?*cblk_extract.CblkExtractor) Allocator.Error!void {
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
                try walkJ2k(report, allocator, body, extractor);
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
fn walkJ2k(report: *ValidationReport, allocator: Allocator, data: []const u8, extractor: ?*cblk_extract.CblkExtractor) Allocator.Error!void {
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
    try parseSizBody(report, allocator, data[4 .. 4 + lsiz], 2);

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
                try walkTileParts(report, allocator, data, pos, extractor);
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
            // Reviewer I1: COC/QCC/RGN override per-component coding,
            // quantization, or ROI up-shift. jp2z does not yet apply them,
            // so decode silently falls back to COD/QCD defaults — surface a
            // finding so a consumer is told (validate's stricter-than-
            // openjpeg contract). pos-2 is the marker offset.
            @intFromEnum(Marker.coc),
            @intFromEnum(Marker.qcc),
            @intFromEnum(Marker.rgn),
            => try emit(report, allocator, .warn, .jp2_unsupported_marker_ignored, pos - 2, null),
            // POC is APPLIED, not ignored: entries parsed here become the
            // default progression-volume list for every tile's packet walk.
            // SIZ precedes POC in a conforming main header (T.800 A.5.1),
            // so coding_params is already seeded; if SIZ was malformed the
            // walk is dead anyway and the POC body is skipped.
            @intFromEnum(Marker.poc) => if (report.coding_params) |*cp| {
                try parsePocBody(report, allocator, body, pos + 2, cp.num_components, &cp.pocs, &cp.num_pocs);
            },
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
    extractor: ?*cblk_extract.CblkExtractor,
) Allocator.Error!void {
    var pos: usize = start;
    // Persistent per-tile walk state, keyed by Isot (SOT tile index).
    // A tile with TNsot>1 tile-parts shares ONE TileWalk across them so
    // the packet iterator + tag-tree states resume rather than restart.
    // Completed/broken tiles are deinit'd and removed as they finish; the
    // defer reaps any tile left incomplete by a truncated codestream.
    var tiles = std.AutoHashMap(u16, TileWalk).init(allocator);
    defer {
        var tw_it = tiles.valueIterator();
        while (tw_it.next()) |tw| tw.deinit(allocator);
        tiles.deinit();
    }
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
        // SOT layout: marker(2) | Lsot(2) | Isot(2) | Psot(4) | TPsot(1) | TNsot(1)
        // Psot sits at pos+6, NOT pos+4 (Isot is in between).
        const psot = std.mem.readInt(u32, data[pos + 6 ..][0..4], .big);

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


        // Locate SOD once (reused for the marker scan and the packet walk).
        const sod = findSod(data, pos, next_pos);
        // Scan the tile-part header: flags override markers jp2z doesn't
        // apply per-tile (COD/COC/QCC/RGN) — the tile-part analogue of the
        // main-header I1 scan — and captures the overrides it DOES apply
        // (POC entries for this tile's sequencer; a QCD body span for the
        // tile's params). Independent of CodingParams; runs even when the
        // packet walk below is skipped. The SOT segment is 12 bytes.
        var tp_ov: TileOverrides = .{};
        if (sod) |sod_pos| {
            tp_ov = try scanTilePartHeaderMarkers(report, allocator, data, pos + 12, sod_pos);
        }
        // Walk this tile-part's packet headers, if we have enough
        // CodingParams to drive the iterator and width/height.
        if (report.coding_params) |params| {
            if (report.width != null and report.height != null) {
                if (sod) |sod_pos| {
                    const tp_body = data[sod_pos + 2 .. next_pos];
                    // Per-tile, per-component geometry (T.800 B.2/B.3): drive
                    // the packet walk from THIS tile's COMPONENT extent, not the
                    // whole reference grid. Isot (SOT tile index) is at pos+4;
                    // component tile dims = ceil(tx1/dx) − ceil(tx0/dx) (all our
                    // fixtures share dx/dy across components, so use comp 0).
                    // Single-tile, non-sub-sampled files reduce to image dims.
                    const isot16: u16 = std.mem.readInt(u16, data[pos + 4 ..][0..2], .big);
                    const gop = try tiles.getOrPut(isot16);
                    if (!gop.found_existing) {
                        const isot: u32 = isot16;
                        const xsiz: u32 = params.image_x0 + report.width.?;
                        const ysiz: u32 = params.image_y0 + report.height.?;
                        const tr = params.tileRect(xsiz, ysiz, isot);
                        const dx: u32 = params.comp_dx[0];
                        const dy: u32 = params.comp_dy[0];
                        const tcx0: u32 = (tr.x0 + dx - 1) / dx;
                        const tcy0: u32 = (tr.y0 + dy - 1) / dy;
                        const tcw: u32 = (tr.x1 + dx - 1) / dx - tcx0;
                        const tch: u32 = (tr.y1 + dy - 1) / dy - tcy0;
                        // A first-tile-part QCD overrides the main header's
                        // quantization FOR THIS TILE (T.800 A.6.4): Mb per
                        // subband (pass budgets, tier-1 bitplanes) and the
                        // dequant stepsizes both change. p1_04 carries one
                        // on 63 of its 64 tiles.
                        var tile_params = params;
                        if (tp_ov.has_qcd) {
                            try parseQcdInto(report, allocator, &tile_params, data[tp_ov.qcd_start..tp_ov.qcd_end], tp_ov.qcd_start);
                        }
                        gop.value_ptr.* = TileWalk.init(allocator, tile_params, tcw, tch, tcx0, tcy0, isot) catch |e| {
                            // Don't leave a half-built entry in the map.
                            _ = tiles.remove(isot16);
                            return e;
                        };
                    } else if (tp_ov.has_qcd) {
                        // QCD is only honored in a tile's FIRST tile-part
                        // header (T.800 A.6.4 placement); a later one is
                        // ignored — surface it rather than silently drop.
                        try emit(report, allocator, .warn, .jp2_unsupported_marker_ignored, tp_ov.qcd_start - 4, null);
                    }
                    // POC entries from THIS tile-part's header accumulate
                    // onto the tile's sequencer before its body is walked
                    // (e1_colr: tile 1's two parts each contribute one).
                    try gop.value_ptr.iter.appendVolumes(allocator, tp_ov.entries[0..tp_ov.n]);
                    // A tile-part body is a whole number of packets; resume
                    // this tile's iterator across its tile-parts (TNsot>1).
                    const res = try walkTilePartBody(report, allocator, gop.value_ptr, tp_body, sod_pos + 2, extractor);
                    if (res != .incomplete) {
                        gop.value_ptr.deinit(allocator);
                        _ = tiles.remove(isot16);
                    }
                }
                // Missing SOD inside a tile-part is already caught
                // structurally by the main-header walker; no extra
                // finding needed here.
            }
        }

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
            // I1: a valid EOC doesn't excuse a tile that delivered fewer whole
            // packets than its COD geometry requires — flag those before exit.
            try flagIncompleteTiles(report, allocator, &tiles, next_pos);
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

/// At codestream end, flag any tile still in the walk map whose packet
/// iterator never reached `total` — the stream delivered fewer whole packets
/// than the COD geometry requires. The persistent per-tile-part walk returns
/// `.incomplete` for both "more tile-parts coming" (TNsot>1, legit) and "stream
/// ended short" (truncation); the difference only resolves at stream end, so
/// the truncation finding lives here. Sorted by Isot so finding order is
/// deterministic (AutoHashMap iteration order is unspecified).
fn flagIncompleteTiles(
    report: *ValidationReport,
    allocator: Allocator,
    tiles: *std.AutoHashMap(u16, TileWalk),
    offset: usize,
) Allocator.Error!void {
    const n = tiles.count();
    if (n == 0) return;
    const keys = try allocator.alloc(u16, n);
    defer allocator.free(keys);
    var ki: usize = 0;
    var it = tiles.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.packets_seen < kv.value_ptr.total) {
            keys[ki] = kv.key_ptr.*;
            ki += 1;
        }
    }
    std.mem.sort(u16, keys[0..ki], {}, std.sort.asc(u16));
    for (keys[0..ki]) |_| {
        try emit(report, allocator, .fail, .truncated_stream, offset, null);
    }
}

/// Overrides collected from one tile-part header, applied to the owning
/// tile by the caller: POC entries (appended to the packet-walk
/// sequencer) and an optional QCD body span (parsed into the tile's
/// params copy before its walk starts).
const TileOverrides = struct {
    entries: [max_pocs]PocEntry = @splat(.{ .rs = 0, .cs = 0, .lye = 0, .re = 0, .ce = 0, .order = .lrcp }),
    n: u8 = 0,
    /// Byte span of the LAST QCD body seen in this header (marker at
    /// qcd_start-4), or null. Last-wins matches openjpeg's sequential
    /// overwrite on the spec-degenerate multiple-QCD case.
    qcd_start: usize = 0,
    qcd_end: usize = 0,
    has_qcd: bool = false,
};

/// Scan a tile-part header — the marker segments between the SOT segment
/// and SOD. Per-tile override markers jp2z does not yet apply (COC/QCC/RGN)
/// surface jp2_unsupported_marker_ignored, the tile-part analogue of the
/// main-header I1 scan: a consumer is told decode fell back to the
/// main-header COD/QCD defaults instead of silently ignoring the override
/// (validate's stricter-than-openjpeg contract). POC, by contrast, is
/// APPLIED: its entries are parsed and returned for the caller to append to
/// the owning tile's sequencer (tile-part POCs accumulate per tile across
/// its parts, mirroring openjpeg's opj_j2k_read_poc). `hdr_start` is the
/// first byte after the SOT segment; `hdr_end` is the SOD offset.
fn scanTilePartHeaderMarkers(
    report: *ValidationReport,
    allocator: Allocator,
    data: []const u8,
    hdr_start: usize,
    hdr_end: usize,
) Allocator.Error!TileOverrides {
    var out: TileOverrides = .{};
    var p = hdr_start;
    while (p + 4 <= hdr_end) {
        if (data[p] != 0xFF) return out; // not a marker boundary — stop
        const marker: u16 = (@as(u16, 0xFF) << 8) | @as(u16, data[p + 1]);
        if (marker == @intFromEnum(Marker.sod)) return out;
        const lseg = std.mem.readInt(u16, data[p + 2 ..][0..2], .big);
        if (lseg < 2 or p + 2 + lseg > hdr_end) return out; // malformed length — bail
        switch (marker) {
            // COD in a tile-part header is a per-tile coding-style
            // override jp2z does not yet apply — same flag as COC/QCC/RGN.
            @intFromEnum(Marker.cod),
            @intFromEnum(Marker.coc),
            @intFromEnum(Marker.qcc),
            @intFromEnum(Marker.rgn),
            => try emit(report, allocator, .warn, .jp2_unsupported_marker_ignored, p, null),
            @intFromEnum(Marker.poc) => if (report.coding_params) |cp| {
                const body = data[p + 4 .. p + 2 + lseg];
                try parsePocBody(report, allocator, body, p + 4, cp.num_components, &out.entries, &out.n);
            },
            // Tile-part QCD is APPLIED (per-tile quantization override,
            // T.800 A.6.4): return its body span; the caller parses it
            // into the owning tile's params before walking.
            @intFromEnum(Marker.qcd) => {
                out.qcd_start = p + 4;
                out.qcd_end = p + 2 + @as(usize, lseg);
                out.has_qcd = true;
            },
            else => {},
        }
        p += 2 + @as(usize, lseg);
    }
    return out;
}

/// Parse a POC (Progression Order Change) marker body (T.800 A.6.6) and
/// append its entries to `entries`/`num`. Entry width depends on Csiz:
/// component fields are u8 below 257 components, u16 at or above, so an
/// entry is 7 or 9 bytes. Emits bad_marker_length for a body that is not a
/// positive whole number of entries, and jp2_bad_progression_order for a
/// degenerate entry (Ppoc > 4, RSpoc >= REpoc, CSpoc >= CEpoc, LYEpoc = 0
/// — T.800 Table A.32's value ranges); a degenerate entry is skipped but
/// the rest of the body is still parsed so one bad entry can't hide the
/// others. `offset` is the byte offset of the body within the codestream.
fn parsePocBody(
    report: *ValidationReport,
    allocator: Allocator,
    body: []const u8,
    offset: usize,
    num_components: u16,
    entries: *[max_pocs]PocEntry,
    num: *u8,
) Allocator.Error!void {
    const wide = num_components >= 257;
    const entry_len: usize = if (wide) 9 else 7;
    if (body.len == 0 or body.len % entry_len != 0) {
        try emit(report, allocator, .fail, .bad_marker_length, offset, null);
        return;
    }
    var i: usize = 0;
    while (i < body.len) : (i += entry_len) {
        const rs = body[i];
        var k = i + 1;
        const cs: u16 = if (wide) std.mem.readInt(u16, body[k..][0..2], .big) else body[k];
        k += if (wide) 2 else @as(usize, 1);
        const lye = std.mem.readInt(u16, body[k..][0..2], .big);
        k += 2;
        const re = body[k];
        k += 1;
        const ce: u16 = if (wide) std.mem.readInt(u16, body[k..][0..2], .big) else body[k];
        k += if (wide) 2 else @as(usize, 1);
        const ppoc = body[k];
        if (ppoc > 4 or rs >= re or cs >= ce or lye == 0) {
            try emit(report, allocator, .fail, .jp2_bad_progression_order, offset + i, null);
            continue;
        }
        if (num.* >= max_pocs) {
            try emit(report, allocator, .fail, .jp2_invalid_codestream, offset + i, null);
            return;
        }
        entries.*[num.*] = .{
            .rs = rs,
            .cs = cs,
            .lye = lye,
            .re = re,
            .ce = ce,
            .order = @enumFromInt(ppoc),
        };
        num.* += 1;
    }
}

/// Parse a COD (Coding Style Default) marker body. T.800 A.6.1:
///
///   Scod   u8   coding style (bit 0 = user precincts, bit 1 = SOP, bit 2 = EPH)
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
    const prog_order_raw = body[1];
    if (prog_order_raw > 4) {
        try emit(report, allocator, .warn, .jp2_bad_progression_order, offset + 1, null);
    }
    const num_layers = std.mem.readInt(u16, body[2..4], .big);
    const mct_raw = body[4];
    if (mct_raw > 1) {
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
    const cblksty = body[8];
    // qmfbid: 0 = 9/7 irreversible (lossy), 1 = 5/3 reversible (lossless).
    const qmfbid = body[9];
    switch (qmfbid) {
        0 => try emit(report, allocator, .info, .jp2_uses_9x7_wavelet, offset + 9, null),
        1 => try emit(report, allocator, .info, .jp2_uses_5x3_wavelet, offset + 9, null),
        else => try emit(report, allocator, .warn, .jp2_invalid_codestream, offset + 9, null),
    }

    const scod = body[0]; // Scod is COD body offset 0 — handy here too
    // Precinct sizes (Scod bit 0 = 1 → user-defined; else default 2^15).
    const num_resolutions: u8 = decomp_levels + 1;
    const expects_user_precincts = (scod & 0x01) != 0;
    const precinct_byte_offset: usize = 10; // Scod(1) + SGcod(5) + SPcod-fixed(4) = 10
    const needed_precinct_bytes: usize = if (expects_user_precincts) @as(usize, num_resolutions) else 0;
    if (body.len < precinct_byte_offset + needed_precinct_bytes) {
        try emit(report, allocator, .warn, .jp2_invalid_codestream, offset + body.len, null);
    }

    // Update CodingParams (which parseSizBody seeded with num_components).
    var invalid_precinct = false;
    if (report.coding_params) |*cp| {
        if (prog_order_raw <= 4) cp.progression_order = @enumFromInt(prog_order_raw);
        cp.num_layers = num_layers;
        cp.num_decomp_levels = decomp_levels;
        cp.cblk_width_exp = cblkw_exp;
        cp.cblk_height_exp = cblkh_exp;
        if (qmfbid <= 1) cp.wavelet = @enumFromInt(qmfbid);
        cp.mct = mct_raw == 1;
        cp.cblksty = cblksty;
        cp.scod = scod;
        if (expects_user_precincts and body.len >= precinct_byte_offset + needed_precinct_bytes) {
            var r: usize = 0;
            while (r < @as(usize, num_resolutions) and r < cp.precinct_sizes.len) : (r += 1) {
                const byte = body[precinct_byte_offset + r];
                const x_exp: u4 = @intCast(byte & 0x0F);
                const y_exp: u4 = @intCast((byte >> 4) & 0x0F);
                // T.800 B.6: PPx/PPy must be >= 1 for every resolution ABOVE the
                // lowest (r>0) — the HF precinct partition halves the exponent, so a
                // 0 there is non-conformant and would underflow the u6 code-block
                // geometry (crash in TileWalk.init while sizing the pool).
                if (r > 0 and (x_exp == 0 or y_exp == 0)) invalid_precinct = true;
                cp.precinct_sizes[r] = .{ .x_exp = x_exp, .y_exp = y_exp };
            }
        }
    }
    if (invalid_precinct) {
        try emit(report, allocator, .fail, .jp2_invalid_codestream, offset + precinct_byte_offset, null);
        // Reject: a non-conformant precinct partition cannot be safely walked. Un-publish
        // coding_params so the packet walk + decodeCleanroom stop cleanly
        // (error.NoCodingParams) instead of crashing on the malformed geometry.
        report.coding_params = null;
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
    if (report.coding_params) |*cp| return parseQcdInto(report, allocator, cp, body, offset);
    // No params (malformed SIZ): still surface structural QCD problems.
    if (body.len < 1) {
        try emit(report, allocator, .fail, .bad_marker_length, offset, null);
        return;
    }
    if ((body[0] & 0x1F) > 2) {
        try emit(report, allocator, .warn, .jp2_invalid_codestream, offset, null);
    }
}

/// Parse a QCD body into `cp` — used for BOTH the main-header QCD
/// (cp = report.coding_params) and a TILE-PART-HEADER QCD override
/// (cp = the owning tile's params copy; T.800 A.6.4 allows QCD in the
/// first tile-part header of a tile, and p1_04 carries one on 63 of its
/// 64 tiles — ignoring them mis-computes Mb AND the dequant stepsizes
/// for every overridden tile).
fn parseQcdInto(
    report: *ValidationReport,
    allocator: Allocator,
    cp: *CodingParams,
    body: []const u8,
    offset: usize,
) Allocator.Error!void {
    if (body.len < 1) {
        try emit(report, allocator, .fail, .bad_marker_length, offset, null);
        return;
    }
    const sqcd = body[0];
    const quant_style: u8 = sqcd & 0x1F;
    const guard_bits: u8 = sqcd >> 5;
    if (quant_style > 2) {
        try emit(report, allocator, .warn, .jp2_invalid_codestream, offset, null);
    }

    // Populate per-subband M_b (T.800 A.6.4 Table A.30 + E.1). SIZ/COD
    // parsing seeded num_components / num_decomp_levels; we lay M_b
    // across subband index space here so the tier-1 dispatcher can pick
    // it up per (resolution, band).
    {
        cp.guard_bits = guard_bits;
        cp.quant_style = quant_style;
        const num_subbands: u8 = 1 + 3 * cp.num_decomp_levels;
        switch (quant_style) {
            // Style 0: no quantization (reversible / 5/3). Each subband
            // gets one SPqcd byte — eps_b in bits 7..3, low 3 reserved.
            0 => {
                const needed: usize = 1 + @as(usize, num_subbands);
                if (body.len < needed) {
                    try emit(report, allocator, .warn, .jp2_invalid_codestream, offset, null);
                    return;
                }
                var sb: u8 = 0;
                while (sb < num_subbands and sb < cp.mb_per_subband.len) : (sb += 1) {
                    const eps: u8 = body[1 + @as(usize, sb)] >> 3;
                    // M_b = G_b + eps_b - 1; clamp at 0 if the sum is 0.
                    const sum: u16 = @as(u16, guard_bits) + @as(u16, eps);
                    cp.mb_per_subband[sb] = if (sum >= 1) @intCast(sum - 1) else 0;
                }
            },
            // Style 2: scalar expounded (irreversible / 9/7). Two bytes
            // per subband: eps_b in bits 15..11, mantissa mu_b in 10..0.
            // We only need eps_b for M_b; mantissa belongs to dequant.
            2 => {
                const needed: usize = 1 + 2 * @as(usize, num_subbands);
                if (body.len < needed) {
                    try emit(report, allocator, .warn, .jp2_invalid_codestream, offset, null);
                    return;
                }
                var sb: u8 = 0;
                while (sb < num_subbands and sb < cp.mb_per_subband.len) : (sb += 1) {
                    const off2: usize = 1 + 2 * @as(usize, sb);
                    const eps: u8 = body[off2] >> 3;
                    const sum: u16 = @as(u16, guard_bits) + @as(u16, eps);
                    cp.mb_per_subband[sb] = if (sum >= 1) @intCast(sum - 1) else 0;
                    cp.qcd_expn[sb] = eps;
                    cp.qcd_mant[sb] = ((@as(u16, body[off2]) & 0x07) << 8) | @as(u16, body[off2 + 1]);
                }
            },
            // Style 1: scalar derived (irreversible). Only LL's (expn,mant)
            // is encoded (2 bytes); siblings derive per T.800 E.5:
            //   expn_b = max(0, expn_0 - floor((b-1)/3)); mant_b = mant_0.
            1 => {
                if (body.len < 3) {
                    try emit(report, allocator, .warn, .jp2_invalid_codestream, offset, null);
                    return;
                }
                const expn0: u8 = body[1] >> 3;
                const mant0: u16 = ((@as(u16, body[1]) & 0x07) << 8) | @as(u16, body[2]);
                var sb: u8 = 0;
                while (sb < num_subbands and sb < cp.mb_per_subband.len) : (sb += 1) {
                    const dec_levels: u8 = if (sb == 0) 0 else @intCast((@as(u16, sb) - 1) / 3);
                    const e: u8 = if (expn0 > dec_levels) expn0 - dec_levels else 0;
                    cp.qcd_expn[sb] = e;
                    cp.qcd_mant[sb] = mant0;
                    const sum: u16 = @as(u16, guard_bits) + @as(u16, e);
                    cp.mb_per_subband[sb] = if (sum >= 1) @intCast(sum - 1) else 0;
                }
            },
            else => {},
        }
    }
}

/// Locate the SOD marker (FF 93) inside a tile-part. `tp_start`
/// points at the SOT marker code; the SOT segment itself is 12
/// bytes. Returns the offset of SOD (relative to `data`) or null
/// if no SOD is found before `tp_end` (Psot boundary). Scans
/// length-prefixed markers between SOT and SOD; bails on the
/// first non-FF byte or any length-field inconsistency.
fn findSod(data: []const u8, tp_start: usize, tp_end: usize) ?usize {
    // SOT segment is always 12 bytes; SOD or another marker
    // follows.
    var pos = tp_start + 12;
    while (pos + 2 <= tp_end and pos + 2 <= data.len) {
        if (data[pos] != 0xFF) return null;
        const marker: u16 = (@as(u16, 0xFF) << 8) | @as(u16, data[pos + 1]);
        if (marker == @intFromEnum(Marker.sod)) return pos;
        // Length-prefixed marker — skip it.
        if (pos + 4 > tp_end or pos + 4 > data.len) return null;
        const lxxx = std.mem.readInt(u16, data[pos + 2 ..][0..2], .big);
        if (lxxx < 2) return null;
        pos += 2 + @as(usize, lxxx);
    }
    return null;
}

/// Walk every (l, r, c, p) packet in a tile-part body, reading
/// each packet header and skipping its body bytes via the
/// contribution_length sum. Verifies the cumulative byte offset
/// matches the tile-part body extent on exit.
///
/// `tp_body` = the slice of the codestream between SOD+2 and the
/// byte after the last packet body (i.e. just before the next SOT
/// or EOC).
/// Persistent per-tile packet-walk state, carried ACROSS a tile's
/// tile-parts (TNsot>1). Holds the LRCP/PCRL packet iterator and the
/// per-(component,resolution,subband,precinct) tag-tree SubbandStates so
/// a tile whose quality layers straddle tile-part boundaries resumes
/// where the prior tile-part stopped instead of restarting the packet
/// set (T.800 B.10 / Annex B). For single-tile-part tiles this is just a
/// one-shot container — init, walk once, deinit.
const TileWalk = struct {
    params: jp2z.CodingParams,
    image_w: u32,
    image_h: u32,
    tile_x0: u32,
    tile_y0: u32,
    tile_index: u32,
    precincts_at_r: [33]u32,
    resolution_offset: [33]usize,
    slots_per_component: usize,
    states: []packet_header.SubbandState,
    initialised: usize,
    iter: PocSequencer,
    /// Total packets this tile's iterator will yield, and how many have
    /// been consumed across its tile-parts so far. `packets_seen == total`
    /// is the progression-order-INDEPENDENT tile-complete signal — unlike
    /// `iter.done`, which flips on different calls for LRCP vs PCRL/RPCL.
    total: usize,
    packets_seen: usize,

    /// Build the per-component slot pool (one SubbandState per
    /// (component, resolution, subband, precinct)) and seed the packet
    /// iterator. `image_w`/`image_h` are this tile's COMPONENT extent
    /// (sub-sampled), not the reference grid.
    fn init(
        allocator: Allocator,
        params: jp2z.CodingParams,
        image_w: u32,
        image_h: u32,
        tile_x0: u32,
        tile_y0: u32,
        tile_index: u32,
    ) Allocator.Error!TileWalk {
        const num_resolutions: u8 = params.num_decomp_levels + 1;

        var precincts_at_r: [33]u32 = @splat(0);
        var resolution_offset: [33]usize = @splat(0);
        var slots_per_component: usize = 0;
        {
            var r: u8 = 0;
            while (r < num_resolutions) : (r += 1) {
                resolution_offset[r] = slots_per_component;
                const ppx: u4 = @intCast(params.precinct_sizes[r].x_exp);
                const ppy: u4 = @intCast(params.precinct_sizes[r].y_exp);
                const grid = subbands.numPrecincts(tile_x0, tile_y0, image_w, image_h, params.num_decomp_levels, r, ppx, ppy);
                precincts_at_r[r] = grid.width * grid.height;
                slots_per_component += @as(usize, subbands.subbandCount(r)) * @as(usize, precincts_at_r[r]);
            }
        }

        const total_slots: usize = slots_per_component * @as(usize, params.num_components);
        const states = try allocator.alloc(packet_header.SubbandState, total_slots);
        errdefer allocator.free(states);

        // slotIndex is monotonic in the (c,r,sb,p) nesting below, so on
        // OOM mid-loop every slot < `initialised` is live — a single
        // prefix free covers partial init.
        var initialised: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < initialised) : (i += 1) states[i].deinit(allocator);
        }
        {
            var c: u16 = 0;
            while (c < params.num_components) : (c += 1) {
                var r: u8 = 0;
                while (r < num_resolutions) : (r += 1) {
                    const sb_count = subbands.subbandCount(r);
                    const pcount = precincts_at_r[r];
                    const ppx: u4 = @intCast(params.precinct_sizes[r].x_exp);
                    const ppy: u4 = @intCast(params.precinct_sizes[r].y_exp);
                    const grid = subbands.numPrecincts(tile_x0, tile_y0, image_w, image_h, params.num_decomp_levels, r, ppx, ppy);
                    var sb: u8 = 0;
                    while (sb < sb_count) : (sb += 1) {
                        var p: u32 = 0;
                        while (p < pcount) : (p += 1) {
                            const prc_x = p % grid.width;
                            const prc_y = p / grid.width;
                            const cblks = subbands.cblksInPrecinctSubband(
                                tile_x0, tile_y0, image_w, image_h, params.num_decomp_levels,
                                r, sb, prc_x, prc_y, ppx, ppy,
                                params.cblk_width_exp, params.cblk_height_exp,
                            );
                            const slot = slotIndex(@intCast(c), r, sb, p, resolution_offset, precincts_at_r, slots_per_component);
                            states[slot] = try packet_header.SubbandState.initFromGrid(
                                allocator,
                                cblks.width,
                                cblks.height,
                            );
                            initialised = slot + 1;
                        }
                    }
                }
            }
        }

        var iter = PocSequencer.init(params, tile_x0, tile_y0, image_w, image_h);
        // Main-header POC entries are the tile's default progression
        // volumes (tile-part-header POCs get appended as parts arrive).
        try iter.appendVolumes(allocator, params.pocs[0..params.num_pocs]);
        return .{
            .params = params,
            .image_w = image_w,
            .image_h = image_h,
            .tile_index = tile_index,
            .tile_x0 = tile_x0,
            .tile_y0 = tile_y0,
            .precincts_at_r = precincts_at_r,
            .resolution_offset = resolution_offset,
            .slots_per_component = slots_per_component,
            .states = states,
            .initialised = initialised,
            .iter = iter,
            .total = iter.total(),
            .packets_seen = 0,
        };
    }

    fn deinit(self: *TileWalk, allocator: Allocator) void {
        var i: usize = 0;
        while (i < self.initialised) : (i += 1) self.states[i].deinit(allocator);
        allocator.free(self.states);
        self.iter.deinit(allocator);
    }
};

/// Outcome of walking one tile-part body.
const TilePartResult = enum {
    /// The tile's packet iterator exhausted — the tile is fully decoded.
    complete,
    /// This tile-part's body was exactly consumed but more tile-parts of
    /// this tile remain (TNsot>1); keep the TileWalk for the next part.
    incomplete,
    /// A structural error (truncated/over-running packet) was found and a
    /// finding emitted; the tile is abandoned.
    broken,
};

/// Walk ONE tile-part's packet bodies, resuming `tw`'s persistent packet
/// iterator and tag-tree states. Stops when this tile-part's body is
/// exactly consumed (more parts to come → `.incomplete`) or the iterator
/// exhausts (`.complete`). The byte-perfect walk findings
/// (jp2_packets_walked_to_end / _under_read) fire once per TILE, when it
/// completes — not once per tile-part.
fn walkTilePartBody(
    report: *ValidationReport,
    allocator: Allocator,
    tw: *TileWalk,
    tp_body: []const u8,
    body_offset_in_data: usize,
    extractor: ?*cblk_extract.CblkExtractor,
) Allocator.Error!TilePartResult {
    const params = tw.params;
    const image_w = tw.image_w;
    const image_h = tw.image_h;
    const tile_x0 = tw.tile_x0;
    const tile_y0 = tw.tile_y0;
    const states = tw.states;
    const resolution_offset = tw.resolution_offset;
    const precincts_at_r = tw.precincts_at_r;
    const slots_per_component = tw.slots_per_component;

    var body_pos: usize = 0;
    // Pull packets from the PERSISTENT iterator until this tile-part's
    // body is consumed; the iterator's cursor carries to the next part.
    while (body_pos < tp_body.len) {
        const pi = tw.iter.next() orelse break;
        tw.packets_seen += 1;

        // SOP marker (Scod bit 1): a per-packet delimiter when enabled. Consume +
        // validate it. Unlike openjpeg (which TODOs the Nsop check) we ALSO verify
        // the packet sequence number — the strict corruption-detection mission.
        if (params.scod & 0x02 != 0) {
            if (body_pos + 6 > tp_body.len or tp_body[body_pos] != 0xFF or tp_body[body_pos + 1] != 0x91) {
                try emit(report, allocator, .fail, .jp2_invalid_codestream, body_offset_in_data + body_pos, null);
                return .broken;
            }
            const lsop = std.mem.readInt(u16, tp_body[body_pos + 2 ..][0..2], .big);
            const nsop = std.mem.readInt(u16, tp_body[body_pos + 4 ..][0..2], .big);
            // Nsop = 0-based packet index within the tile, wraps at 65536 (openjpeg packno % 65536).
            const expected_nsop: u16 = @truncate(tw.packets_seen - 1);
            if (lsop != 4 or nsop != expected_nsop) {
                try emit(report, allocator, .fail, .jp2_invalid_codestream, body_offset_in_data + body_pos + 2, null);
                return .broken;
            }
            body_pos += 6;
        }

        // Per-packet view: SubbandStates for (component, resolution,
        // all-subbands-at-r, this-precinct). value-copied in (will be
        // copied out after readPacketHeader has mutated state).
        var view_buf: [3]packet_header.SubbandState = undefined;
        const sb_count = subbands.subbandCount(pi.resolution);
        var sb: u8 = 0;
        while (sb < sb_count) : (sb += 1) {
            const slot = slotIndex(@intCast(pi.component), pi.resolution, sb, pi.precinct, resolution_offset, precincts_at_r, slots_per_component);
            view_buf[sb] = states[slot];
        }
        const view = view_buf[0..sb_count];

        var reader = BitReader.init(tp_body[body_pos..], .{ .ff_stuffing = true });
        const seg_alloc: ?Allocator = if (extractor != null) allocator else null;
        const contribution_len = (try packet_header.readPacketHeader(&reader, view, pi.layer, params.cblksty, seg_alloc)) orelse {
            try emit(report, allocator, .fail, .truncated_stream, body_offset_in_data + body_pos, null);
            return .broken;
        };

        // Write back the (mutated) SubbandState entries.
        sb = 0;
        while (sb < sb_count) : (sb += 1) {
            const slot = slotIndex(@intCast(pi.component), pi.resolution, sb, pi.precinct, resolution_offset, precincts_at_r, slots_per_component);
            states[slot] = view[sb];
        }

        const header_bytes = reader.bytesConsumed();

        // EPH marker (Scod bit 2): follows the byte-aligned packet header when enabled.
        var eph_bytes: usize = 0;
        if (params.scod & 0x04 != 0) {
            const eph_at = body_pos + header_bytes;
            if (eph_at + 2 > tp_body.len or tp_body[eph_at] != 0xFF or tp_body[eph_at + 1] != 0x92) {
                try emit(report, allocator, .fail, .jp2_invalid_codestream, body_offset_in_data + eph_at, null);
                return .broken;
            }
            eph_bytes = 2;
        }

        // M3 brick 9d: per-cblk byte extraction. When an extractor is
        // wired in, we slice each cblk's contribution bytes out of the
        // tile-part body in the SAME order readPacketHeader walked them
        // (subband × cblk row-major), and append to the extractor's
        // per-cblk byte buffer. The extractor stamps subband-internal
        // rect + zero_bitplanes + cblksty on first sight and tracks the
        // running total_passes.
        if (extractor) |ex| {
            const ppx: u4 = @intCast(params.precinct_sizes[pi.resolution].x_exp);
            const ppy: u4 = @intCast(params.precinct_sizes[pi.resolution].y_exp);
            const prc_grid = subbands.numPrecincts(tile_x0, tile_y0, image_w, image_h, params.num_decomp_levels, pi.resolution, ppx, ppy);
            const prc_x_in_grid: u32 = if (prc_grid.width == 0) 0 else pi.precinct % prc_grid.width;
            const prc_y_in_grid: u32 = if (prc_grid.width == 0) 0 else pi.precinct / prc_grid.width;
            const data_base = body_pos + header_bytes + eph_bytes;
            var bytes_so_far: u32 = 0;
            var ex_sb: u8 = 0;
            while (ex_sb < sb_count) : (ex_sb += 1) {
                const sbs_view = view[ex_sb];
                if (sbs_view.grid_w == 0 or sbs_view.grid_h == 0) continue;
                // OpenJPEG `bandno`: 0 (LL @ r=0) or 1/2/3 (HL/LH/HH @ r>=1).
                const band_for_key: u8 = if (pi.resolution == 0) 0 else ex_sb + 1;
                var gy: u32 = 0;
                while (gy < sbs_view.grid_h) : (gy += 1) {
                    var gx: u32 = 0;
                    while (gx < sbs_view.grid_w) : (gx += 1) {
                        const cb = sbs_view.blocks[gy * sbs_view.grid_w + gx];
                        if (cb.last_contribution_length == 0) continue;
                        const L: usize = cb.last_contribution_length;
                        if (data_base + bytes_so_far + L > tp_body.len) {
                            // Bounds-mismatched contribution; the post-loop
                            // emit() below catches the structural issue.
                            break;
                        }
                        const rect = subbands.cblkSubbandRect(
                            tile_x0, tile_y0, image_w, image_h, params.num_decomp_levels,
                            pi.resolution, ex_sb,
                            prc_x_in_grid, prc_y_in_grid,
                            ppx, ppy,
                            params.cblk_width_exp, params.cblk_height_exp,
                            gx, gy,
                        );
                        try ex.appendContribution(.{
                            .tile = tw.tile_index,
                            .component = @intCast(pi.component),
                            .resolution = pi.resolution,
                            .band = band_for_key,
                            .precinct = pi.precinct,
                            .grid_x = gx,
                            .grid_y = gy,
                        }, tp_body[data_base + bytes_so_far .. data_base + bytes_so_far + L], .{
                            .sb_x0 = rect.x0,
                            .sb_y0 = rect.y0,
                            .sb_x1 = rect.x1,
                            .sb_y1 = rect.y1,
                            .zero_bitplanes = cb.zero_bitplanes,
                            .m_b = params.mbForSubband(pi.resolution, band_for_key),
                            .qcd_expn = params.qcd_expn[CodingParams.subbandIndex(pi.resolution, band_for_key)],
                            .qcd_mant = params.qcd_mant[CodingParams.subbandIndex(pi.resolution, band_for_key)],
                            .cblksty = params.cblksty,
                            .total_passes = cb.total_passes,
                            .segments = cb.segments.items,
                        });
                        bytes_so_far += @intCast(L);
                    }
                }
            }
        }

        const advance = header_bytes + eph_bytes + @as(usize, contribution_len);
        if (body_pos + advance > tp_body.len) {
            try emit(report, allocator, .fail, .truncated_stream, body_offset_in_data + body_pos + advance, null);
            return .broken;
        }
        body_pos += advance;
    }

    // Disposition. The iterator yields exactly `tw.total` packets across the tile's
    // tile-parts; once we've seen them all the tile is complete. This is
    // order-independent (LRCP/PCRL/RPCL set iter.done on different calls).
    if (tw.packets_seen >= tw.total) {
        // Surface walker-vs-tile match status. Only meaningful when COD
        // was fully parsed (num_layers > 0).
        if (params.num_layers > 0) {
            if (body_pos == tp_body.len) {
                try emit(report, allocator, .info, .jp2_packets_walked_to_end, body_offset_in_data, null);
            } else {
                try emit(report, allocator, .warn, .jp2_packets_under_read, body_offset_in_data + body_pos, null);
            }
        }
        return .complete;
    }
    // Body exactly consumed, iterator still has packets → resume next part.
    return .incomplete;
}


/// 4-D index into the flat per-component SubbandState pool. Layout:
///   slot(c, r, sb, p) = c·slots_per_component
///                     + resolution_offset[r]
///                     + sb·precincts_at_r[r]
///                     + p
fn slotIndex(
    component: u16,
    resolution: u8,
    subband_idx: u8,
    precinct: u32,
    resolution_offset: [33]usize,
    precincts_at_r: [33]u32,
    slots_per_component: usize,
) usize {
    const base = @as(usize, component) * slots_per_component;
    const sb_offset = @as(usize, subband_idx) * @as(usize, precincts_at_r[resolution]);
    return base + resolution_offset[resolution] + sb_offset + @as(usize, precinct);
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
fn parseSizBody(report: *ValidationReport, allocator: Allocator, body: []const u8, pos: usize) Allocator.Error!void {
    const xsiz = std.mem.readInt(u32, body[4..8], .big);
    const ysiz = std.mem.readInt(u32, body[8..12], .big);
    const xosiz = std.mem.readInt(u32, body[12..16], .big);
    const yosiz = std.mem.readInt(u32, body[16..20], .big);
    const csiz = std.mem.readInt(u16, body[36..38], .big);
    const xtsiz = std.mem.readInt(u32, body[20..24], .big);
    const ytsiz = std.mem.readInt(u32, body[24..28], .big);
    const xtosiz = std.mem.readInt(u32, body[28..32], .big);
    const ytosiz = std.mem.readInt(u32, body[32..36], .big);

    // T.800 A.5.1 geometry validation. A hostile-input validator must FLAG
    // malformed SIZ and bail (leaving coding_params null) BEFORE any
    // downstream code divides by / indexes with a bad value — never crash:
    //   C2: descriptor table must fit the marker (Lsiz == 38 + 3·Csiz).
    //   C4: jp2z's per-component arrays hold 16 → Csiz ∈ [1, 16].
    //   numTilesXY underflow: tile grid non-degenerate, tile origin ≤ image origin.
    //   image extent must be positive.
    if (csiz == 0 or csiz > 16 or
        body.len < 38 + @as(usize, 3) * @as(usize, csiz) or
        xtsiz == 0 or ytsiz == 0 or
        xtosiz > xosiz or ytosiz > yosiz or
        xsiz <= xosiz or ysiz <= yosiz)
    {
        try emit(report, allocator, .fail, .jp2_invalid_siz, pos, null);
        return;
    }

    // Seed CodingParams with the SIZ-derived fields. Remaining fields default
    // until parseCodBody overwrites them. width/height/coding_params are only
    // published after the per-component descriptors validate (C1), so a bad
    // XRsiz leaves the report un-seeded rather than half-seeded.
    var cp_local: jp2z.CodingParams = .{
        .num_components = csiz,
        .image_x0 = xosiz,
        .image_y0 = yosiz,
        .tile_x0 = xtosiz,
        .tile_y0 = ytosiz,
        .tile_w = xtsiz,
        .tile_h = ytsiz,
    };
    var ci: usize = 0;
    while (ci < csiz) : (ci += 1) {
        // Each component descriptor is 3 bytes: Ssiz, XRsiz, YRsiz.
        const ssiz = body[38 + ci * 3];
        const xrsiz = body[38 + ci * 3 + 1];
        const yrsiz = body[38 + ci * 3 + 2];
        // C1: sub-sampling factors are divisors (component grid = 1/dx × 1/dy).
        // T.800 A.5.1 Table A.10 requires XRsiz, YRsiz ∈ [1, 255].
        if (xrsiz == 0 or yrsiz == 0) {
            try emit(report, allocator, .fail, .jp2_invalid_siz, pos, null);
            return;
        }
        cp_local.comp_prec[ci] = (ssiz & 0x7F) + 1;
        if (ssiz & 0x80 != 0) cp_local.comp_signed |= (@as(u16, 1) << @intCast(ci));
        cp_local.comp_dx[ci] = xrsiz;
        cp_local.comp_dy[ci] = yrsiz;
    }
    report.width = xsiz - xosiz;
    report.height = ysiz - yosiz;
    report.coding_params = cp_local;
}


fn emit(
    report: *ValidationReport,
    allocator: Allocator,
    severity: Severity,
    code: FindingCode,
    offset: ?u64,
    detail: ?[]const u8,
) Allocator.Error!void {
    // Ownership note (A3): emit() DUPES `detail` — the caller keeps ownership
    // of its slice (callers pass string literals / stack buffers). This is the
    // opposite of reconstruct.zig's appendFinding, which TAKES ownership of an
    // allocPrint'd `detail`. Both free the stored copy in report.deinit.
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
    try parseSizBody(&report, std.testing.allocator, &body, 0);
    try std.testing.expectEqual(@as(?u32, 303), report.width);
    try std.testing.expectEqual(@as(?u32, 179), report.height);
}

test "parseQcdBody: style 0 reversible — extracts G_b and per-subband M_b" {
    const body = [_]u8{
        0x40,
        8  << 3,
        9  << 3,
        9  << 3,
        10 << 3,
        10 << 3,
        10 << 3,
        11 << 3,
    };
    var report = ValidationReport{
        .overall = .pass,
        .variant = .j2k_codestream,
        .width = null,
        .height = null,
        .findings = .empty,
        .coding_params = .{ .num_decomp_levels = 2 },
    };
    defer report.deinit(std.testing.allocator);

    try parseQcdBody(&report, std.testing.allocator, &body, 0);

    const cp = report.coding_params.?;
    try std.testing.expectEqual(@as(u8, 2), cp.guard_bits);
    try std.testing.expectEqual(@as(u8, 0), cp.quant_style);
    try std.testing.expectEqual(@as(u8, 9),  cp.mb_per_subband[0]);
    try std.testing.expectEqual(@as(u8, 10), cp.mb_per_subband[1]);
    try std.testing.expectEqual(@as(u8, 10), cp.mb_per_subband[2]);
    try std.testing.expectEqual(@as(u8, 11), cp.mb_per_subband[3]);
    try std.testing.expectEqual(@as(u8, 11), cp.mb_per_subband[4]);
    try std.testing.expectEqual(@as(u8, 11), cp.mb_per_subband[5]);
    try std.testing.expectEqual(@as(u8, 12), cp.mb_per_subband[6]);
}

test "CodingParams.mbForSubband: r=0 -> idx 0; r>=1 -> 3*(r-1)+band" {
    var cp = jp2z.CodingParams{ .num_decomp_levels = 2 };
    cp.mb_per_subband[0] = 9;
    cp.mb_per_subband[1] = 10;
    cp.mb_per_subband[2] = 11;
    cp.mb_per_subband[3] = 12;
    cp.mb_per_subband[4] = 13;
    cp.mb_per_subband[5] = 14;
    cp.mb_per_subband[6] = 15;

    try std.testing.expectEqual(@as(u8, 9),  cp.mbForSubband(0, 0));
    try std.testing.expectEqual(@as(u8, 10), cp.mbForSubband(1, 1));
    try std.testing.expectEqual(@as(u8, 11), cp.mbForSubband(1, 2));
    try std.testing.expectEqual(@as(u8, 12), cp.mbForSubband(1, 3));
    try std.testing.expectEqual(@as(u8, 13), cp.mbForSubband(2, 1));
    try std.testing.expectEqual(@as(u8, 14), cp.mbForSubband(2, 2));
    try std.testing.expectEqual(@as(u8, 15), cp.mbForSubband(2, 3));
}

test "CodingParams.tileRect: 256x256 image, 128x128 tiles -> 2x2 grid" {
    const cp: jp2z.CodingParams = .{
        .num_components = 1,
        .image_x0 = 0, .image_y0 = 0,
        .tile_x0 = 0, .tile_y0 = 0,
        .tile_w = 128, .tile_h = 128,
    };
    const nt = cp.numTilesXY(256, 256);
    try std.testing.expectEqual(@as(u32, 2), nt.x);
    try std.testing.expectEqual(@as(u32, 2), nt.y);
    // tile 0 = top-left, tile 3 = bottom-right (q=1,p=1).
    const t0 = cp.tileRect(256, 256, 0);
    try std.testing.expectEqual(@as(u32, 0), t0.x0);
    try std.testing.expectEqual(@as(u32, 128), t0.x1);
    const t3 = cp.tileRect(256, 256, 3);
    try std.testing.expectEqual(@as(u32, 128), t3.x0);
    try std.testing.expectEqual(@as(u32, 128), t3.y0);
    try std.testing.expectEqual(@as(u32, 256), t3.x1);
    try std.testing.expectEqual(@as(u32, 256), t3.y1);
}

test "CodingParams.numTilesXY: zero tile dims -> single tile" {
    const cp: jp2z.CodingParams = .{ .num_components = 1 };
    const nt = cp.numTilesXY(303, 179);
    try std.testing.expectEqual(@as(u32, 1), nt.x);
    try std.testing.expectEqual(@as(u32, 1), nt.y);
}

test "parsePocBody: e1_colr's real 7-byte entries parse; malformed/degenerate flagged" {
    var report = ValidationReport{
        .overall = .pass,
        .variant = .j2k_codestream,
        .width = null,
        .height = null,
        .findings = .empty,
    };
    defer report.deinit(std.testing.allocator);
    var entries: [max_pocs]PocEntry = @splat(.{ .rs = 0, .cs = 0, .lye = 0, .re = 0, .ce = 0, .order = .lrcp });
    var n: u8 = 0;

    // The two REAL entries from e1_colr's tile-1 tile-part headers
    // (offsets 13945 and 54017): {0,0,LYE=1,RE=10,CE=10,PCRL} then
    // {0,0,LYE=5,RE=10,CE=10,RLCP}. Csiz=3 → 7-byte entries, raw
    // (unclamped) values stored.
    const tp0 = [_]u8{ 0x00, 0x00, 0x00, 0x01, 0x0A, 0x0A, 0x03 };
    try parsePocBody(&report, std.testing.allocator, &tp0, 0, 3, &entries, &n);
    const tp1 = [_]u8{ 0x00, 0x00, 0x00, 0x05, 0x0A, 0x0A, 0x01 };
    try parsePocBody(&report, std.testing.allocator, &tp1, 0, 3, &entries, &n);
    try std.testing.expectEqual(@as(u8, 2), n);
    try std.testing.expectEqual(ProgressionOrder.pcrl, entries[0].order);
    try std.testing.expectEqual(@as(u16, 1), entries[0].lye);
    try std.testing.expectEqual(@as(u8, 10), entries[0].re);
    try std.testing.expectEqual(@as(u16, 10), entries[0].ce);
    try std.testing.expectEqual(ProgressionOrder.rlcp, entries[1].order);
    try std.testing.expectEqual(@as(u16, 5), entries[1].lye);
    try std.testing.expectEqual(@as(usize, 0), report.findings.items.len);

    // Truncated body (not a whole number of entries) → bad_marker_length,
    // nothing appended.
    const short = [_]u8{ 0x00, 0x00 };
    try parsePocBody(&report, std.testing.allocator, &short, 0, 3, &entries, &n);
    try std.testing.expectEqual(@as(u8, 2), n);
    try std.testing.expectEqual(FindingCode.bad_marker_length, report.findings.items[report.findings.items.len - 1].code);

    // Degenerate first entry (RSpoc >= REpoc) is flagged and SKIPPED, but
    // the valid entry after it still parses — one bad entry can't hide
    // the rest of the progression description.
    const degen_then_ok = [_]u8{
        0x02, 0x00, 0x00, 0x01, 0x02, 0x03, 0x00, // rs=2 >= re=2 → invalid
        0x00, 0x00, 0x00, 0x02, 0x06, 0x03, 0x04, // valid, CPRL
    };
    try parsePocBody(&report, std.testing.allocator, &degen_then_ok, 0, 3, &entries, &n);
    try std.testing.expectEqual(@as(u8, 3), n);
    try std.testing.expectEqual(ProgressionOrder.cprl, entries[2].order);
    try std.testing.expectEqual(FindingCode.jp2_bad_progression_order, report.findings.items[report.findings.items.len - 1].code);
}

test "PocSequencer: volume sequencing, cross-volume dedup, mid-walk append, passthrough replay" {
    // Hand-computable geometry: 64x64 tile at origin 0, 2 resolutions,
    // 2 components, 2 layers, default (2^15) precincts → exactly one
    // precinct per resolution → 2*2*2 = 8 distinct packets.
    const params: CodingParams = .{
        .progression_order = .lrcp,
        .num_layers = 2,
        .num_components = 2,
        .num_decomp_levels = 1,
        .num_pocs = 0,
    };
    const vol_a: PocEntry = .{ .rs = 0, .cs = 0, .lye = 1, .re = 2, .ce = 2, .order = .lrcp };
    const vol_b: PocEntry = .{ .rs = 0, .cs = 0, .lye = 2, .re = 2, .ce = 2, .order = .rlcp };
    // Expected: volume A (LRCP, layer 0 only) emits l0 in LRCP order;
    // volume B (RLCP, layers 0..1) re-visits l0 (deduped by the shared
    // include set — T.800 B.12.1 "shall not be included again") and emits
    // only the l1 packets, in RLCP order.
    const expected = [8][3]u16{
        .{ 0, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 1, 0 }, .{ 0, 1, 1 }, // A: (l,r,c)
        .{ 1, 0, 0 }, .{ 1, 0, 1 }, .{ 1, 1, 0 }, .{ 1, 1, 1 }, // B: l1 only
    };

    // (1) Both volumes known up front (a main-header POC).
    {
        var seq = PocSequencer.init(params, 0, 0, 64, 64);
        defer seq.deinit(std.testing.allocator);
        try seq.appendVolumes(std.testing.allocator, &.{ vol_a, vol_b });
        for (expected) |e| {
            const pi = seq.next().?;
            try std.testing.expectEqual(e[0], pi.layer);
            try std.testing.expectEqual(@as(u8, @intCast(e[1])), pi.resolution);
            try std.testing.expectEqual(e[2], pi.component);
        }
        try std.testing.expectEqual(@as(?PacketIndex, null), seq.next());
    }

    // (2) Volume B appended only after A exhausts — e1_colr's tile 1
    // shape (each tile-part header contributes one POC entry). The
    // sequencer must revive and produce the identical total sequence.
    {
        var seq = PocSequencer.init(params, 0, 0, 64, 64);
        defer seq.deinit(std.testing.allocator);
        try seq.appendVolumes(std.testing.allocator, &.{vol_a});
        for (expected[0..4]) |e| {
            const pi = seq.next().?;
            try std.testing.expectEqual(e[0], pi.layer);
        }
        try std.testing.expectEqual(@as(?PacketIndex, null), seq.next());
        try seq.appendVolumes(std.testing.allocator, &.{vol_b});
        for (expected[4..8]) |e| {
            const pi = seq.next().?;
            try std.testing.expectEqual(e[0], pi.layer);
            try std.testing.expectEqual(@as(u8, @intCast(e[1])), pi.resolution);
            try std.testing.expectEqual(e[2], pi.component);
        }
        try std.testing.expectEqual(@as(?PacketIndex, null), seq.next());
    }

    // (3) No volumes → bare passthrough, byte-identical to PacketIterator.
    {
        var seq = PocSequencer.init(params, 0, 0, 64, 64);
        defer seq.deinit(std.testing.allocator);
        var bare = PacketIterator.init(params, 0, 0, 64, 64);
        var count: usize = 0;
        while (bare.next()) |b| : (count += 1) {
            const s = seq.next().?;
            try std.testing.expectEqual(b, s);
        }
        try std.testing.expectEqual(@as(usize, 8), count);
        try std.testing.expectEqual(@as(?PacketIndex, null), seq.next());
    }

    // (4) Late first POC after passthrough packets were already pulled:
    // the already-emitted prefix is replayed into the include set so the
    // new volume cannot re-emit those packets.
    {
        var seq = PocSequencer.init(params, 0, 0, 64, 64);
        defer seq.deinit(std.testing.allocator);
        _ = seq.next().?; // l0 r0 c0 (COD LRCP order)
        _ = seq.next().?; // l0 r0 c1
        try seq.appendVolumes(std.testing.allocator, &.{vol_b}); // full box, RLCP
        const after = [6][3]u16{
            .{ 1, 0, 0 }, .{ 1, 0, 1 }, // r0: l0 deduped, l1 emits
            .{ 0, 1, 0 }, .{ 0, 1, 1 }, // r1: l0 NOT yet emitted
            .{ 1, 1, 0 }, .{ 1, 1, 1 },
        };
        for (after) |e| {
            const pi = seq.next().?;
            try std.testing.expectEqual(e[0], pi.layer);
            try std.testing.expectEqual(@as(u8, @intCast(e[1])), pi.resolution);
            try std.testing.expectEqual(e[2], pi.component);
        }
        try std.testing.expectEqual(@as(?PacketIndex, null), seq.next());
    }
}
