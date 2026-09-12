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

/// Quantization table (T.800 A.6.4/A.6.5): the default from QCD, or a
/// per-component override from QCC (`comp_quant`). Precedence, highest
/// first: tile-part QCC > tile-part QCD > main QCC > main QCD — a
/// tile-part QCD therefore clears every override inherited from the
/// main header before the tile's own QCCs re-apply.
pub const QuantTable = struct {
    /// Guard bits G_b from Sqcd/Sqcc high 3 bits (0..7). Applies to every
    /// subband.
    guard_bits: u8 = 0,
    /// Quantization style from the low 5 bits: 0 = no-quant
    /// (reversible / 5/3), 1 = scalar derived, 2 = scalar expounded.
    quant_style: u8 = 0,
    /// Per-subband number of magnitude bit-planes
    /// M_b = G_b + epsilon_b - 1 (T.800 E.1). Indexed by subband index:
    ///   r = 0:          subband_idx = 0   (only LL exists)
    ///   r >= 1, band b: subband_idx = 3*(r-1) + b  (b in {1,2,3} for HL/LH/HH)
    /// Length 1 + 3*32 = 97 covers num_decomp_levels up to 32.
    mb: [97]u8 = @splat(0),
    /// Per-subband quantization exponent (irreversible), same index.
    expn: [97]u8 = @splat(0),
    /// Per-subband quantization mantissa (11-bit) for irreversible dequant.
    mant: [97]u16 = @splat(0),
    /// Subband entries the marker actually carried (style 1: derived for
    /// all). A component whose decomposition needs more is reported by
    /// checkQuantCoverage; the missing bands read as eps 0 / mant 0, which
    /// is what openjpeg's zero-initialised stepsizes yield (p0_08).
    entries: u16 = 0,
    /// Codestream offset of the marker body (for coverage findings).
    offset: usize = 0,
    /// Set once a QCD/QCC marker filled this table; the coverage check
    /// skips tables no marker supplied (a missing QCD is a different
    /// finding, not a coverage shortfall).
    present: bool = false,
};
/// Per-component coding style (T.800 A.6.2): the fields a COC may override
/// for one component. The COD defaults are the fallback (`codingFor`).
pub const CompCoding = struct {
    num_decomp_levels: u8,
    cblk_width_exp: u8,
    cblk_height_exp: u8,
    cblksty: u8,
    wavelet: WaveletFilter,
    precinct_sizes: [33]PrecinctSize,
};

pub const CodingParams = struct {
    /// SIZ Rsiz as written (A.5.1 Table A.9 + amendments). Bit 15 = Part 2
    /// (T.801), bit 14 = HTJ2K (T.814): under those, base-standard reserved
    /// values may be extension-defined and are reported as indeterminate
    /// (c145) instead of proven violations.
    rsiz: u16 = 0,
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
    /// QCD table (the default for every component without a QCC).
    quant: QuantTable = .{},
    /// QCC overrides by component (first 16 components; a QCC for a later
    /// component is surfaced as unsupported).
    comp_quant: [16]?QuantTable = @splat(null),
    /// COC overrides by component (T.800 A.6.2): decomposition count,
    /// code-block size/style, wavelet, precincts. Precedence: tile-part COC >
    /// tile-part COD > main COC > main COD (a tile-part COD clears inherited
    /// overrides). A COC for a component past the 16 slots is c145.
    comp_coding: [16]?CompCoding = @splat(null),
    /// RGN ROI up-shift by component (T.800 A.6.3, implicit ROI): coded
    /// bit-planes = M_b + shift - zero_bitplanes, and decoded magnitudes at
    /// or above 2^shift are scaled back down by shift (H.2).
    comp_roishift: [16]u8 = @splat(0),
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

    /// Effective quantization table for component `c`: its QCC override
    /// when one exists, else the QCD default (T.800 A.6.5 precedence).
    pub fn quantFor(self: *const CodingParams, c: u16) *const QuantTable {
        if (c < self.comp_quant.len) {
            if (self.comp_quant[c]) |*t| return t;
        }
        return &self.quant;
    }

    /// Effective coding style for component `c`: its COC override when one
    /// exists, else the COD defaults.
    pub fn codingFor(self: *const CodingParams, c: u16) CompCoding {
        if (c < self.comp_coding.len) {
            if (self.comp_coding[c]) |cc| return cc;
        }
        return .{
            .num_decomp_levels = self.num_decomp_levels,
            .cblk_width_exp = self.cblk_width_exp,
            .cblk_height_exp = self.cblk_height_exp,
            .cblksty = self.cblksty,
            .wavelet = self.wavelet,
            .precinct_sizes = self.precinct_sizes,
        };
    }

    /// ROI up-shift of component `c` (0 without RGN).
    pub fn roishiftFor(self: *const CodingParams, c: u16) u8 {
        return self.comp_roishift[@min(c, self.comp_roishift.len - 1)];
    }

    /// Look up M_b for component `c` at a (resolution, band) pair. `band`
    /// follows the OpenJPEG convention: 0=LL@r=0, 1=HL, 2=LH, 3=HH.
    pub fn mbForSubband(self: *const CodingParams, c: u16, r: u8, band: u8) u8 {
        return self.quantFor(c).mb[subbandIndex(r, band)];
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
        // u64: every operand is a legal u32 (A.5.1), but Ysiz + YTsiz can
        // exceed 2^32 (issue823 fuzz corpus). The quotient always fits u32.
        const nx = (@as(u64, xsiz) - self.tile_x0 + self.tile_w - 1) / self.tile_w;
        const ny = (@as(u64, ysiz) - self.tile_y0 + self.tile_h - 1) / self.tile_h;
        return .{ .x = @intCast(@max(1, nx)), .y = @intCast(@max(1, ny)) };
    }

    /// Component-coordinate rect of tile `isot` (T.800 B.3). xsiz/ysiz are
    /// the absolute SIZ image extents (image_x0+width, image_y0+height).
    pub fn tileRect(self: CodingParams, xsiz: u32, ysiz: u32, isot: u32) TileRect {
        const nt = self.numTilesXY(xsiz, ysiz);
        const p = isot % nt.x; // tile column
        const q = isot / nt.x; // tile row
        // u64 intermediates: (q + 1) * YTsiz overflows u32 for legal SIZ
        // values; the clamps against the image extents bring it back to u32.
        const tw: u64 = self.tile_w;
        const th: u64 = self.tile_h;
        const x0: u32 = @intCast(@min(@max(self.tile_x0 + p * tw, self.image_x0), xsiz));
        const y0: u32 = @intCast(@min(@max(self.tile_y0 + q * th, self.image_y0), ysiz));
        const x1: u32 = @intCast(@min(self.tile_x0 + (p + 1) * tw, xsiz));
        const y1: u32 = @intCast(@min(self.tile_y0 + (q + 1) * th, ysiz));
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
    /// Tile rectangle on the REFERENCE grid (tx0, ty0, width, height).
    /// Each component's own tile-component rect is derived from it with the
    /// component's sub-sampling (T.800 B.2/B.3): interior tiles and
    /// sub-sampled components must not share component 0's geometry — a
    /// coarse resolution that collapses to zero extent for one component
    /// contributes NO packets for it (the b1_mono narrow-tile bug, now
    /// per component).
    tile_x0: u32,
    tile_y0: u32,
    image_w: u32,
    image_h: u32,

    /// Per-component precinct geometry (COC gives each component its own
    /// decomposition count and precinct partition; SIZ its own sub-sampling).
    /// Components past the 16th read slot 15 — parseSizBody guarantees their
    /// descriptors repeat it, and COC/RGN for them are surfaced as c145.
    geo: [16]CompGeo = @splat(.{}),
    /// max over components of (decomp + 1): the resolution loop bound.
    max_resolutions: u8 = 0,
    /// RPCL steps each r by the MIN reference-grid stride over components.
    rpcl_stride_x_at_r: [33]u32 = @splat(1),
    rpcl_stride_y_at_r: [33]u32 = @splat(1),
    /// PCRL / CPRL step by the MIN stride over all (component, r).
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

    pub const CompGeo = struct {
        /// Tile-component rect on the component's sub-sampled grid.
        tcx0: u32 = 0,
        tcy0: u32 = 0,
        tcw: u32 = 0,
        tch: u32 = 0,
        dx: u32 = 1,
        dy: u32 = 1,
        num_decomp_levels: u8 = 0,
        num_resolutions: u8 = 0,
        precinct_sizes: [33]PrecinctSize = @splat(.{}),
        precincts_at_r: [33]u32 = @splat(0),
        pcw_at_r: [33]u32 = @splat(0),
        pch_at_r: [33]u32 = @splat(0),
        /// Reference-grid stride of resolution r: dx · 2^(PPx + level).
        ref_stride_x_at_r: [33]u32 = @splat(1),
        ref_stride_y_at_r: [33]u32 = @splat(1),
    };

    /// Tile-component rect of component `c` for a reference-grid tile
    /// rect (T.800 B-12): tcx0 = ceil(tx0/dx), tcx1 = ceil(tx1/dx).
    pub fn compRect(params: *const CodingParams, tile_x0: u32, tile_y0: u32, image_w: u32, image_h: u32, c: u16) struct { tcx0: u32, tcy0: u32, tcw: u32, tch: u32, dx: u32, dy: u32 } {
        const ci: usize = @min(c, params.comp_dx.len - 1);
        const dx: u32 = params.comp_dx[ci];
        const dy: u32 = params.comp_dy[ci];
        const tcx0 = (tile_x0 + dx - 1) / dx;
        const tcy0 = (tile_y0 + dy - 1) / dy;
        const tcx1 = (tile_x0 + image_w + dx - 1) / dx;
        const tcy1 = (tile_y0 + image_h + dy - 1) / dy;
        return .{ .tcx0 = tcx0, .tcy0 = tcy0, .tcw = tcx1 - tcx0, .tch = tcy1 - tcy0, .dx = dx, .dy = dy };
    }

    fn geoFor(self: *const PacketIterator, c: u16) *const CompGeo {
        return &self.geo[@min(c, self.geo.len - 1)];
    }

    /// Precincts of (component, resolution); 0 beyond the component's resolutions.
    pub fn precinctsAt(self: *const PacketIterator, c: u16, r: u8) u32 {
        const g = self.geoFor(c);
        return if (r < g.num_resolutions) g.precincts_at_r[r] else 0;
    }

    /// Does (component, r) emit a packet at reference-grid (x, y)? Maps the
    /// position onto the component's grid: off-grid positions (x % dx != 0)
    /// never emit except at the tile origin, where openjpeg's pi.c pins a
    /// partial first precinct (the `x == tx0` case of isOnPrecinctBoundary).
    fn emitsAt(self: *const PacketIterator, c: u16, r: u8, x: u32, y: u32) bool {
        const g = self.geoFor(c);
        if (r >= g.num_resolutions or g.precincts_at_r[r] == 0) return false;
        const at_origin_x = x == self.tile_x0;
        const at_origin_y = y == self.tile_y0;
        if (!at_origin_x and x % g.dx != 0) return false;
        if (!at_origin_y and y % g.dy != 0) return false;
        const xc: u32 = if (at_origin_x) g.tcx0 else x / g.dx;
        const yc: u32 = if (at_origin_y) g.tcy0 else y / g.dy;
        const ppx: u4 = @intCast(g.precinct_sizes[r].x_exp);
        const ppy: u4 = @intCast(g.precinct_sizes[r].y_exp);
        return subbands.isOnPrecinctBoundary(g.tcx0, g.tcy0, g.num_decomp_levels, r, ppx, ppy, xc, yc);
    }

    fn precinctAt(self: *const PacketIterator, c: u16, r: u8, x: u32, y: u32) u32 {
        const g = self.geoFor(c);
        const xc: u32 = if (x == self.tile_x0) g.tcx0 else x / g.dx;
        const yc: u32 = if (y == self.tile_y0) g.tcy0 else y / g.dy;
        const ppx: u4 = @intCast(g.precinct_sizes[r].x_exp);
        const ppy: u4 = @intCast(g.precinct_sizes[r].y_exp);
        return subbands.precinctIndexAt(g.tcx0, g.tcy0, g.tcw, g.tch, g.num_decomp_levels, r, ppx, ppy, xc, yc);
    }

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
        var min_sx: u32 = std.math.maxInt(u32);
        var min_sy: u32 = std.math.maxInt(u32);
        var rpcl_sx: [33]u32 = @splat(std.math.maxInt(u32));
        var rpcl_sy: [33]u32 = @splat(std.math.maxInt(u32));
        var any_precincts = false;
        var max_res: u8 = 0;
        const ncomp_geo: u16 = @intCast(@min(@as(usize, params.num_components), iter.geo.len));
        var c: u16 = 0;
        while (c < ncomp_geo) : (c += 1) {
            const cc = params.codingFor(c);
            const rect = compRect(&params, tile_x0, tile_y0, image_w, image_h, c);
            var g: CompGeo = .{
                .tcx0 = rect.tcx0,
                .tcy0 = rect.tcy0,
                .tcw = rect.tcw,
                .tch = rect.tch,
                .dx = rect.dx,
                .dy = rect.dy,
                .num_decomp_levels = cc.num_decomp_levels,
                .num_resolutions = cc.num_decomp_levels + 1,
                .precinct_sizes = cc.precinct_sizes,
            };
            var r: u8 = 0;
            while (r < g.num_resolutions) : (r += 1) {
                const ppx: u4 = @intCast(cc.precinct_sizes[r].x_exp);
                const ppy: u4 = @intCast(cc.precinct_sizes[r].y_exp);
                const grid = subbands.numPrecincts(rect.tcx0, rect.tcy0, rect.tcw, rect.tch, cc.num_decomp_levels, r, ppx, ppy);
                g.pcw_at_r[r] = grid.width;
                g.pch_at_r[r] = grid.height;
                g.precincts_at_r[r] = grid.width * grid.height;
                if (g.precincts_at_r[r] > 0) any_precincts = true;
                const stride = subbands.referenceGridStride(cc.num_decomp_levels, r, ppx, ppy);
                // Component-grid stride → reference grid (openjpeg pi.c:
                // comp->dx << (pdx + levelno)); saturate rather than wrap.
                const sx: u32 = std.math.mul(u32, stride.width, rect.dx) catch std.math.maxInt(u32);
                const sy: u32 = std.math.mul(u32, stride.height, rect.dy) catch std.math.maxInt(u32);
                g.ref_stride_x_at_r[r] = sx;
                g.ref_stride_y_at_r[r] = sy;
                if (sx < rpcl_sx[r]) rpcl_sx[r] = sx;
                if (sy < rpcl_sy[r]) rpcl_sy[r] = sy;
                if (sx < min_sx) min_sx = sx;
                if (sy < min_sy) min_sy = sy;
            }
            if (g.num_resolutions > max_res) max_res = g.num_resolutions;
            iter.geo[c] = g;
        }
        iter.max_resolutions = max_res;
        var r: usize = 0;
        while (r < 33) : (r += 1) {
            iter.rpcl_stride_x_at_r[r] = if (rpcl_sx[r] == std.math.maxInt(u32)) 1 else rpcl_sx[r];
            iter.rpcl_stride_y_at_r[r] = if (rpcl_sy[r] == std.math.maxInt(u32)) 1 else rpcl_sy[r];
        }
        iter.min_stride_x = if (min_sx == std.math.maxInt(u32)) 1 else min_sx;
        iter.min_stride_y = if (min_sy == std.math.maxInt(u32)) 1 else min_sy;

        iter.done = params.num_layers == 0 or
            max_res == 0 or
            params.num_components == 0 or
            image_w == 0 or image_h == 0 or
            !any_precincts;
        return iter;
    }

    pub fn total(self: PacketIterator) usize {
        var total_p: usize = 0;
        var c: u16 = 0;
        while (c < self.params.num_components) : (c += 1) {
            const g = self.geoFor(c);
            var r: u8 = 0;
            while (r < g.num_resolutions) : (r += 1) total_p += @as(usize, g.precincts_at_r[r]);
        }
        return @as(usize, self.params.num_layers) * total_p;
    }

    pub fn next(self: *PacketIterator) ?PacketIndex {
        if (self.done) return null;
        return switch (self.params.progression_order) {
            .lrcp, .rlcp => self.nextIndexed(),
            .rpcl => self.nextRpcl(),
            .pcrl, .cprl => self.nextPositional(),
        };
    }

    // ── LRCP / RLCP — indexed iteration with per-(c, r) precinct count ──

    fn nextIndexed(self: *PacketIterator) ?PacketIndex {
        // Skip any (component, resolution) with zero precincts: a resolution
        // beyond the component's own decomposition count (COC), or one that
        // collapses to zero extent for this component's tile rect. Such a
        // pair contributes NO packets (that is exactly what `total()`
        // counts, and what openjpeg emits).
        while (self.precinctsAt(self.component, self.resolution) == 0) {
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
        const num_resolutions: u8 = self.max_resolutions;
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
                        // count is per-(c, r)). Component is untouched.
                        self.precinct = 0;
                        return;
                    }
                    self.resolution = 0;
                    self.precinct = 0;
                },
                .component => {
                    self.component += 1;
                    self.precinct = 0;
                    if (self.component < self.params.num_components) return;
                    self.component = 0;
                },
                .precinct => {
                    self.precinct += 1;
                    if (self.precinct < self.precinctsAt(self.component, self.resolution)) return;
                    self.precinct = 0;
                },
            }
        }
        self.done = true;
    }

    // ── RPCL — resolution outer; each r steps by its MIN stride over components ──

    fn nextRpcl(self: *PacketIterator) ?PacketIndex {
        // Nesting (outer→inner): r, y, x, c, l. A (c) that does not emit at
        // this (r, x, y) — off its grid, beyond its resolutions, or an empty
        // resolution — is skipped to the next component, not the next
        // position: other components may still emit here.
        while (!self.done) {
            const r = self.resolution;
            if (!self.emitsAt(self.component, r, self.x, self.y)) {
                self.layer = 0;
                self.advanceRpclComponent();
                continue;
            }
            const result: PacketIndex = .{
                .layer = self.layer,
                .resolution = r,
                .component = self.component,
                .precinct = self.precinctAt(self.component, r, self.x, self.y),
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
        self.advanceRpclComponent();
    }

    fn advanceRpclComponent(self: *PacketIterator) void {
        self.component += 1;
        if (self.component < self.params.num_components) return;
        self.component = 0;
        self.advanceRpclPosition();
    }

    /// Advance the RPCL position cursor (x → y → r) by the CURRENT
    /// resolution's stride, stepping to the next stride MULTIPLE on the
    /// absolute reference grid (openjpeg's `x += dx - (x % dx)` — an
    /// unaligned tile origin steps to the grid, not by a fixed offset)
    /// and resetting carries to the tile origin, not 0.
    fn advanceRpclPosition(self: *PacketIterator) void {
        const sx = self.rpcl_stride_x_at_r[self.resolution];
        const sy = self.rpcl_stride_y_at_r[self.resolution];
        self.x += sx - (self.x % sx);
        if (self.x < self.tile_x0 + self.image_w) return;
        self.x = self.tile_x0;
        self.y += sy - (self.y % sy);
        if (self.y < self.tile_y0 + self.image_h) return;
        self.y = self.tile_y0;
        self.resolution += 1;
        if (self.resolution < self.max_resolutions) return;
        self.done = true;
    }

    // ── PCRL / CPRL — reference-grid outer; (r) filtered on-boundary ──

    fn nextPositional(self: *PacketIterator) ?PacketIndex {
        // At entry, (x, y, c, r, l) is the *candidate* state. The
        // outer loop skips past invalid r (not on the component's own
        // precinct boundary at (x, y)) and advances the outer dims when
        // necessary. Emits when current r is on boundary.
        while (!self.done) {
            const num_resolutions: u8 = self.geoFor(self.component).num_resolutions;
            // Find the next r ≥ self.resolution that emits at (x, y) for
            // THIS component.
            while (self.resolution < num_resolutions and !self.emitsAt(self.component, self.resolution, self.x, self.y)) {
                self.resolution += 1;
            }
            if (self.resolution < num_resolutions) {
                const r = self.resolution;
                const result: PacketIndex = .{
                    .layer = self.layer,
                    .resolution = r,
                    .component = self.component,
                    .precinct = self.precinctAt(self.component, r, self.x, self.y),
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
        const num_resolutions: u8 = seq.inner.max_resolutions;
        var acc: usize = 0;
        var r: u8 = 0;
        while (r < num_resolutions) : (r += 1) {
            seq.rc_offset[r] = acc;
            var c: u16 = 0;
            while (c < params.num_components) : (c += 1) acc += @as(usize, seq.inner.precinctsAt(c, r));
        }
        seq.rc_total = acc;
        return seq;
    }

    /// Within-resolution base of component `c` in the canonical index:
    /// Σ_{c' < c} precincts(c', r). Per-component precinct counts differ
    /// under COC / sub-sampling, so this is a sum, not a multiply.
    fn compOffset(self: *const PocSequencer, r: u8, c: u16) usize {
        var acc: usize = 0;
        var k: u16 = 0;
        while (k < c) : (k += 1) acc += @as(usize, self.inner.precinctsAt(k, r));
        return acc;
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
            self.compOffset(pi.resolution, pi.component) +
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
    const bpcc: u32 = 0x62706363; // 'bpcc' — Bits Per Component box (in jp2h, I.5.3.2)
    const jp2c: u32 = 0x6A703263; // 'jp2c' — Contiguous Codestream box
    const cdef: u32 = 0x63646566; // 'cdef' — Channel Definition box (in jp2h)
    const pclr: u32 = 0x70636C72; // 'pclr' — Palette box (in jp2h, I.5.3.4)
    const cmap: u32 = 0x636D6170; // 'cmap' — Component Mapping box (in jp2h, I.5.3.5)
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
    var ihdr_dims: ?IhdrDims = null;

    while (pos < data.len) {
        if (data.len < pos + 8) {
            if (saw_jp2c) {
                // Fewer than 8 bytes after the last box cannot be a box
                // (I.4: a JP2 file is a sequence of boxes): trailing junk such
                // as a CRLF appended in transit (issue211.jp2). Decoders ignore
                // it, but it is a proven violation of the box structure, so it
                // FAILs (Peter, 2026-09-12); the walk's end checks still run.
                var buf: [96]u8 = undefined;
                const d = std.fmt.bufPrint(&buf, "{d} byte(s) after the last box cannot form a box header (T.800 I.4)", .{data.len - pos}) catch null;
                try emit(report, allocator, .fail, .jp2_trailing_bytes, pos, d);
                break;
            }
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
            BoxType.ftyp => {
                if (saw_ftyp) try emit(report, allocator, .fail, .jp2_invalid_signature, pos, "second ftyp box (T.800 I.5.2: exactly one)");
                saw_ftyp = true;
                // I.5.2: ftyp immediately follows the signature box; BR(4)
                // MinV(4) then 4-byte compatibility entries; a reader accepts
                // the file when BR is 'jp2 ' or the list contains it.
                if (pos != 12) try emit(report, allocator, .fail, .jp2_invalid_signature, pos, "ftyp must immediately follow the signature box (T.800 I.5.2)");
                if (body.len < 8 or (body.len - 8) % 4 != 0) {
                    try emit(report, allocator, .fail, .bad_marker_length, pos, "ftyp box length is not 8 + 4·n (T.800 I.5.2)");
                } else {
                    const jp2_brand: u32 = 0x6A703220; // 'jp2 '
                    var ok = std.mem.readInt(u32, body[0..4], .big) == jp2_brand;
                    var ci: usize = 8;
                    while (ci + 4 <= body.len) : (ci += 4) {
                        if (std.mem.readInt(u32, body[ci..][0..4], .big) == jp2_brand) ok = true;
                    }
                    if (!ok) try emit(report, allocator, .fail, .jp2_invalid_signature, pos + body_offset, "ftyp brand is not 'jp2 ' and the compatibility list does not include it (T.800 I.5.2)");
                }
            },
            BoxType.jp2h => {
                if (saw_jp2h) {
                    // I.5.3: exactly one JP2 Header box; the first one governs.
                    try emit(report, allocator, .fail, .jp2_invalid_codestream, pos, "second jp2h box (T.800 I.5.3: exactly one)");
                    pos += box_total;
                    continue;
                }
                saw_jp2h = true;
                ihdr_dims = try parseJp2HeaderBox(report, allocator, body, pos + body_offset);
                // I.5.3.1: ihdr is mandatory (and first) in jp2h. Without it the
                // file has no declared geometry to cross-check the codestream
                // against (issue364-903: openjpeg "no 'ihdr' box").
                if (ihdr_dims == null) try emit(report, allocator, .fail, .jp2_invalid_codestream, pos + body_offset, "jp2h has no usable ihdr box (T.800 I.5.3.1 requires it)");
            },
            BoxType.jp2c => {
                if (saw_jp2c) {
                    // T.800 I.5.4: readers shall use the FIRST contiguous
                    // codestream. Walking later ones would merge their
                    // findings AND pollute the cblk extractor under the
                    // same tile keys — surface the skip instead.
                    try emit(report, allocator, .warn, .jp2_unsupported_marker_ignored, pos, null);
                } else {
                    // I.5.3: the JP2 Header box precedes the codestream.
                    if (!saw_jp2h) try emit(report, allocator, .fail, .jp2_invalid_codestream, pos, "jp2h must precede jp2c (T.800 I.5.3)");
                    saw_jp2c = true;
                    // T.800 I.5.3: the JP2 Header box shall fall before
                    // the Contiguous Codestream box.
                    if (!saw_jp2h) {
                        try emit(report, allocator, .fail, .jp2_invalid_codestream, pos, null);
                    }
                    // The C ABI documents finding offsets as byte offsets
                    // into the INPUT data (the host file). walkJ2k emits
                    // them relative to the jp2c payload it was handed, so
                    // rebase everything it appends — findings here, and
                    // extractor plan src_offsets (which become deep-finding
                    // anchors in deepValidate) below.
                    const findings_start = report.findings.items.len;
                    try walkJ2k(report, allocator, body, extractor);
                    const base: u64 = pos + body_offset;
                    for (report.findings.items[findings_start..]) |*f| {
                        if (f.offset) |o| f.offset = o + base;
                    }
                    if (extractor) |ex| ex.addSrcOffsetBase(@intCast(base));
                }
            },
            else => {}, // unknown / optional boxes — ignore for M1
        }

        pos += box_total;
    }

    // Required-box absence anchors at data.len — the walk exhausted the
    // file without seeing the box (missing_eoi's "where it should have
    // been" convention). No finding leaves here with a null offset.
    if (!saw_ftyp) try emit(report, allocator, .fail, .jp2_invalid_signature, data.len, null);
    if (!saw_jp2h) try emit(report, allocator, .fail, .jp2_invalid_codestream, data.len, null);
    if (!saw_jp2c) try emit(report, allocator, .fail, .jp2_invalid_codestream, data.len, null);

    // T.800 I.5.3.1: ihdr HEIGHT/WIDTH "shall be equal to" the
    // codestream's reference-grid dims. After the walk, report.width/
    // height hold SIZ's values (SIZ overwrites ihdr's); a disagreeing
    // container is lying about its payload.
    if (ihdr_dims) |d| {
        if (report.width != null and (report.width.? != d.w or report.height.? != d.h)) {
            try emit(report, allocator, .fail, .jp2_invalid_codestream, d.off, null);
        }
        // I.5.3.1 / I.5.3.2: NC equals Csiz; BPC (or the bpcc entries when
        // BPC is 0xFF) equals every component's Ssiz depth and sign.
        if (report.coding_params) |cp| {
            if (d.nc != cp.num_components) {
                try emit(report, allocator, .fail, .jp2_invalid_codestream, d.off + 8, "ihdr component count (NC) disagrees with SIZ Csiz (T.800 I.5.3.1)");
            }
            const n: usize = @min(@as(usize, cp.num_components), 16);
            if (d.bpc != 0xFF) {
                var k: usize = 0;
                while (k < n) : (k += 1) {
                    const signed = (cp.comp_signed >> @intCast(k)) & 1 != 0;
                    if ((d.bpc & 0x7F) + 1 != cp.comp_prec[k] or (d.bpc >> 7 != 0) != signed) {
                        try emit(report, allocator, .fail, .jp2_invalid_codestream, d.off + 10, "ihdr bit depth (BPC) disagrees with SIZ Ssiz (T.800 I.5.3.1)");
                        break;
                    }
                }
            } else if (d.bpcc) |bpcc| {
                if (bpcc.len != cp.num_components) {
                    try emit(report, allocator, .fail, .jp2_invalid_codestream, d.off + 10, "bpcc entry count disagrees with SIZ Csiz (T.800 I.5.3.2)");
                } else {
                    var k: usize = 0;
                    while (k < n) : (k += 1) {
                        const signed = (cp.comp_signed >> @intCast(k)) & 1 != 0;
                        if ((bpcc[k] & 0x7F) + 1 != cp.comp_prec[k] or (bpcc[k] >> 7 != 0) != signed) {
                            try emit(report, allocator, .fail, .jp2_invalid_codestream, d.off + 10, "bpcc bit depth disagrees with SIZ Ssiz (T.800 I.5.3.2)");
                            break;
                        }
                    }
                }
            } else {
                try emit(report, allocator, .fail, .jp2_invalid_codestream, d.off + 10, "ihdr BPC 0xFF (varying depths) requires a bpcc box (T.800 I.5.3.2)");
            }
        }
    }
}

/// ihdr's declared dims + the host-file offset of the ihdr body, so
/// walkJp2 can cross-check them against SIZ (T.800 I.5.3.1).
const IhdrDims = struct {
    w: u32,
    h: u32,
    off: u64,
    nc: u16 = 0,
    /// ihdr BPC: bit 7 signed, bits 0-6 depth−1, 0xFF = varying (see bpcc).
    bpc: u8 = 0,
    /// ihdr C: compression type, 7 for JPEG 2000.
    c: u8 = 7,
    /// bpcc box body (one BPC byte per component) when present.
    bpcc: ?[]const u8 = null,
};

/// Walk the sub-boxes inside a `jp2h` container, looking for `ihdr`
/// (Image Header — T.800 Annex I.5.3) to pull width/height. Other
/// sub-boxes (colr, pclr, cmap, cdef, ...) are ignored for M1.
/// `base` is the jp2h BODY's host-file offset — findings and the
/// returned ihdr offset are anchored host-relative. Handles XLBox
/// (LBox=1) sub-boxes; malformed lengths emit bad_marker_length
/// instead of silently abandoning the walk.
fn parseJp2HeaderBox(report: *ValidationReport, allocator: Allocator, body: []const u8, base: u64) Allocator.Error!?IhdrDims {
    var dims: ?IhdrDims = null;
    // pclr / cmap / cdef may appear in any order after ihdr (I.5.3), and
    // cmap is checked against pclr while cdef's channel space is cmap's
    // output (issue412: 1 component, 3 palette channels). Collect, then
    // validate once the whole jp2h has been walked.
    var pclr: ?PclrInfo = null;
    var cmap_span: ?struct { body: []const u8, off: u64 } = null;
    var cdef_span: ?struct { body: []const u8, off: u64 } = null;
    var pos: usize = 0;
    while (pos + 8 <= body.len) {
        const lbox = std.mem.readInt(u32, body[pos..][0..4], .big);
        const tbox = std.mem.readInt(u32, body[pos + 4 ..][0..4], .big);

        var box_total: usize = undefined;
        var body_off: usize = 8;
        if (lbox == 0) {
            box_total = body.len - pos;
        } else if (lbox == 1) {
            // Extended length: 8-byte XLBox follows the type field.
            if (pos + 16 > body.len) {
                try emit(report, allocator, .fail, .truncated_stream, base + pos, null);
                return dims;
            }
            const xlbox = std.mem.readInt(u64, body[pos + 8 ..][0..8], .big);
            if (xlbox < 16 or xlbox > body.len - pos) {
                try emit(report, allocator, .fail, .bad_marker_length, base + pos, null);
                return dims;
            }
            box_total = @intCast(xlbox);
            body_off = 16;
        } else if (lbox >= 8) {
            box_total = lbox;
        } else {
            // LBox 2..7 is unrepresentable (a box header alone is 8 bytes).
            try emit(report, allocator, .fail, .bad_marker_length, base + pos, null);
            return dims;
        }
        if (box_total < body_off or box_total > body.len - pos) {
            try emit(report, allocator, .fail, .bad_marker_length, base + pos, null);
            return dims;
        }

        if (tbox == BoxType.ihdr and box_total >= body_off + 14) {
            const ihdr_body = body[pos + body_off .. pos + box_total];
            // ihdr layout: HEIGHT(u32) WIDTH(u32) NC(u16) BPC(u8) C(u8) ...
            const height = std.mem.readInt(u32, ihdr_body[0..4], .big);
            const width = std.mem.readInt(u32, ihdr_body[4..8], .big);
            report.height = height;
            report.width = width;
            const bpc = ihdr_body[10];
            const c = ihdr_body[11];
            dims = .{ .w = width, .h = height, .off = base + pos + body_off, .nc = std.mem.readInt(u16, ihdr_body[8..10], .big), .bpc = bpc, .c = c };
            // I.5.3.1: C is 7 (JPEG 2000) — the only value defined.
            // I.5.3.1 defines exactly one value; a different C is a proven
            // container lie and FAILs (Peter, 2026-09-12) even though decoders
            // read the codestream regardless.
            if (c != 7) try emit(report, allocator, .fail, .jp2_invalid_codestream, base + pos + body_off + 11, "ihdr compression type (C) must be 7 (T.800 I.5.3.1)");
        }
        if (tbox == BoxType.bpcc) {
            if (dims) |*d| d.bpcc = body[pos + body_off .. pos + box_total];
        }
        if (tbox == BoxType.cdef) {
            cdef_span = .{ .body = body[pos + body_off .. pos + box_total], .off = base + pos + body_off };
        }
        if (tbox == BoxType.colr) {
            // I.5.3.3: METH(1) PREC(1) APPROX(1); METH 1 → EnumCS(4), exactly
            // 7 bytes; METH 2 → a restricted ICC profile follows. Part 1 knows
            // EnumCS 16 (sRGB), 17 (greyscale), 18 (sYCC); other values and
            // METH 3/4 belong to Part 2 (valid, unsupported here). The first
            // colr box is the one a reader uses.
            const cb = body[pos + body_off .. pos + box_total];
            const coff = base + pos + body_off;
            if (cb.len < 3) {
                try emit(report, allocator, .fail, .bad_marker_length, coff, "colr box shorter than METH/PREC/APPROX (T.800 I.5.3.3)");
            } else switch (cb[0]) {
                1 => if (cb.len < 7) {
                    try emit(report, allocator, .fail, .bad_marker_length, coff, "colr METH 1 box is shorter than METH/PREC/APPROX/EnumCS (T.800 I.5.3.3)");
                } else {
                    const cs = std.mem.readInt(u32, cb[3..7], .big);
                    if (report.colr_enumcs == null) report.colr_enumcs = cs;
                    switch (cs) {
                        // Part-1 spaces carry no parameters: exactly 7 bytes.
                        // Amendment / Part-2 spaces (CIELab 14, ...) append
                        // their own fields, so only the minimum is checked.
                        16, 17, 18 => if (cb.len != 7) try emit(report, allocator, .fail, .bad_marker_length, coff, "colr METH 1 box must be exactly 7 bytes for a Part-1 EnumCS (T.800 I.5.3.3)"),
                        else => try emit(report, allocator, .warn, .jp2_unsupported_marker_ignored, coff + 3, "colr EnumCS is not a Part-1 colour space (16 sRGB, 17 greyscale, 18 sYCC); Part 2 / vendor value"),
                    }
                },
                2 => if (cb.len <= 3) {
                    try emit(report, allocator, .fail, .bad_marker_length, coff, "colr METH 2 carries no ICC profile (T.800 I.5.3.3)");
                },
                else => try emit(report, allocator, .warn, .jp2_unsupported_marker_ignored, coff, "colr METH is not 1 or 2: reserved in Part 1 (Part 2 any-ICC / vendor colour)"),
            }
        }
        if (tbox == BoxType.pclr) {
            pclr = try parsePclrBox(report, allocator, body[pos + body_off .. pos + box_total], base + pos + body_off);
        }
        if (tbox == BoxType.cmap) {
            cmap_span = .{ .body = body[pos + body_off .. pos + box_total], .off = base + pos + body_off };
        }

        pos += box_total;
    }
    // I.5.3.5: cmap is present exactly when pclr is.
    if (pclr != null and cmap_span == null) {
        try emit(report, allocator, .fail, .jp2_invalid_codestream, base, "pclr palette present without a cmap component-mapping box (T.800 I.5.3.5)");
    }
    if (cmap_span != null and pclr == null) {
        try emit(report, allocator, .fail, .jp2_invalid_codestream, cmap_span.?.off, "cmap present without a pclr palette box (T.800 I.5.3.5)");
    }
    const nc: u16 = if (dims) |d| d.nc else 0xFFFF;
    var channels: u16 = nc;
    if (cmap_span) |cm| channels = try parseCmapBox(report, allocator, cm.body, cm.off, nc, pclr);
    if (pclr != null) {
        // Valid Part-1 feature jp2z's decode does not apply (c145): the
        // codestream components come out unmapped.
        try emit(report, allocator, .warn, .jp2_unsupported_marker_ignored, base, "palette (pclr/cmap) is not applied by jp2z decode; codestream components are delivered unmapped");
    }
    if (cdef_span) |cd| try parseCdefBox(report, allocator, cd.body, cd.off, channels);
    return dims;
}

const PclrInfo = struct { ne: u16, npc: u8 };

/// pclr (T.800 I.5.3.4): NE (1..1024) palette entries × NPC (≥1) columns,
/// one B_i depth byte per column (bit 7 signed, bits 0-6 depth−1), then
/// NE×NPC entries of ceil(depth/8) bytes each. Returns NE/NPC whenever the
/// header is readable so cmap can still be checked against NPC; every
/// deviation is a FAIL (mem-b2ace68c-1381: NE=1, NPC=4, no entries).
fn parsePclrBox(report: *ValidationReport, allocator: Allocator, body: []const u8, offset: u64) Allocator.Error!?PclrInfo {
    if (body.len < 3) {
        try emit(report, allocator, .fail, .bad_marker_length, offset, "pclr box shorter than its NE/NPC header (T.800 I.5.3.4)");
        return null;
    }
    const ne = std.mem.readInt(u16, body[0..2], .big);
    const npc = body[2];
    if (ne == 0 or ne > 1024 or npc == 0) {
        try emit(report, allocator, .fail, .jp2_invalid_codestream, offset, "pclr NE must be 1..1024 and NPC at least 1 (T.800 I.5.3.4)");
    }
    if (body.len < 3 + @as(usize, npc)) {
        try emit(report, allocator, .fail, .bad_marker_length, offset, "pclr box shorter than its NPC column-depth fields (T.800 I.5.3.4)");
        return .{ .ne = ne, .npc = npc };
    }
    var entry_bytes: usize = 0;
    var i: usize = 0;
    while (i < npc) : (i += 1) {
        const depth: usize = @as(usize, body[3 + i] & 0x7F) + 1;
        entry_bytes += (depth + 7) / 8;
    }
    const expected: usize = 3 + @as(usize, npc) + @as(usize, ne) * entry_bytes;
    if (body.len != expected) {
        try emit(report, allocator, .fail, .bad_marker_length, offset, "pclr box length does not match NE × NPC palette entries (T.800 I.5.3.4)");
        return .{ .ne = ne, .npc = npc };
    }
    // Well-formed: surface the values for the cleanroom decode (palette
    // application) and any consumer. Entries are big-endian, ceil(depth/8)
    // bytes; a signed column (B_i bit 7) keeps its raw two's-complement bits.
    if (report.palette == null and ne > 0 and npc > 0) {
        const depths = try allocator.alloc(u8, npc);
        errdefer allocator.free(depths);
        const entries = try allocator.alloc(u32, @as(usize, ne) * npc);
        errdefer allocator.free(entries);
        var p: usize = 3 + @as(usize, npc);
        var e: usize = 0;
        while (e < ne) : (e += 1) {
            var col: usize = 0;
            while (col < npc) : (col += 1) {
                const depth: usize = @as(usize, body[3 + col] & 0x7F) + 1;
                depths[col] = @intCast(depth);
                const nb = (depth + 7) / 8;
                var v: u32 = 0;
                var k: usize = 0;
                while (k < nb) : (k += 1) v = (v << 8) | body[p + k];
                p += nb;
                entries[e * npc + col] = v;
            }
        }
        report.palette = .{ .ne = ne, .npc = npc, .depths = depths, .entries = entries };
    }
    return .{ .ne = ne, .npc = npc };
}

/// cmap (T.800 I.5.3.5): 4-byte entries (CMP u16, MTYP u8, PCOL u8), one
/// per output channel. CMP names a codestream component (< ihdr NC); MTYP 1
/// maps it through palette column PCOL (< pclr NPC), MTYP 0 uses it
/// directly (PCOL 0). Returns the channel count, which is the space cdef's
/// Cn indexes when a palette is present.
fn parseCmapBox(report: *ValidationReport, allocator: Allocator, body: []const u8, offset: u64, nc: u16, pclr: ?PclrInfo) Allocator.Error!u16 {
    if (body.len == 0 or body.len % 4 != 0) {
        try emit(report, allocator, .fail, .bad_marker_length, offset, "cmap box is not a whole number of 4-byte entries (T.800 I.5.3.5)");
    }
    const n: usize = body.len / 4;
    if (report.cmap.len == 0 and n > 0) {
        const entries = try allocator.alloc(jp2z.ValidationReport.CmapEntry, n);
        var k: usize = 0;
        while (k < n) : (k += 1) {
            entries[k] = .{ .cmp = std.mem.readInt(u16, body[k * 4 ..][0..2], .big), .mtyp = body[k * 4 + 2], .pcol = body[k * 4 + 3] };
        }
        report.cmap = entries;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const at = i * 4;
        const cmp = std.mem.readInt(u16, body[at..][0..2], .big);
        const mtyp = body[at + 2];
        const pcol = body[at + 3];
        if (cmp >= nc) {
            try emit(report, allocator, .fail, .jp2_invalid_codestream, offset + at, "cmap entry names a component beyond the ihdr component count (T.800 I.5.3.5)");
        }
        if (mtyp > 1) {
            try emit(report, allocator, .fail, .jp2_invalid_codestream, offset + at + 2, "cmap MTYP must be 0 (direct) or 1 (palette) (T.800 I.5.3.5)");
        } else if (mtyp == 1) {
            if (pclr == null or pcol >= pclr.?.npc) {
                try emit(report, allocator, .fail, .jp2_invalid_codestream, offset + at + 3, "cmap entry names a palette column beyond pclr NPC (T.800 I.5.3.5)");
            }
        } else if (pcol != 0) {
            try emit(report, allocator, .fail, .jp2_invalid_codestream, offset + at + 3, "cmap direct-use entry (MTYP 0) must carry PCOL 0 (T.800 I.5.3.5)");
        }
    }
    return @intCast(@min(n, 0xFFFF));
}

/// cdef (T.800 I.5.3.6): N entries of (Cn channel, Typ, Asoc). Typ 0 =
/// colour with Asoc = 1-based colour index (0 = whole image); Typ 1/2 =
/// opacity. Builds `report.cdef`: colour i ← channel order[i], identity
/// for colours no entry names. A channel index at or past the ihdr
/// component count, or two channels claiming one colour, is a structural
/// lie (FAIL) — the file cannot be rendered as declared.
fn parseCdefBox(report: *ValidationReport, allocator: Allocator, body: []const u8, offset: u64, nc: u16) Allocator.Error!void {
    if (body.len < 2) {
        try emit(report, allocator, .fail, .bad_marker_length, offset, "cdef box too short for N");
        return;
    }
    const n = std.mem.readInt(u16, body[0..2], .big);
    if (body.len < 2 + 6 * @as(usize, n)) {
        try emit(report, allocator, .fail, .bad_marker_length, offset, "cdef box shorter than its N entries");
        return;
    }
    var map: jp2z.ValidationReport.ChannelMap = .{ .order = undefined, .n = @intCast(@min(nc, 16)) };
    var i: u8 = 0;
    while (i < 16) : (i += 1) map.order[i] = i;
    var claimed: [16]bool = @splat(false);
    var e: usize = 0;
    while (e < n) : (e += 1) {
        const at = 2 + 6 * e;
        const cn = std.mem.readInt(u16, body[at..][0..2], .big);
        const typ = std.mem.readInt(u16, body[at + 2 ..][0..2], .big);
        const asoc = std.mem.readInt(u16, body[at + 4 ..][0..2], .big);
        if (cn >= nc) {
            try emit(report, allocator, .fail, .jp2_invalid_codestream, offset + at, "cdef names a channel beyond the ihdr component count");
            return;
        }
        if (typ != 0 or asoc == 0 or asoc == 65535) continue; // opacity / whole-image: not a colour slot
        const colour: usize = asoc - 1;
        if (colour >= map.order.len or cn >= map.order.len) continue; // beyond the 16 stored slots: identity
        if (claimed[colour]) {
            try emit(report, allocator, .fail, .jp2_invalid_codestream, offset + at + 4, "cdef assigns two channels to one colour");
            return;
        }
        claimed[colour] = true;
        map.order[colour] = @intCast(cn);
    }
    report.cdef = map;
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
    // TLM entries (A.7.1) accumulate here in encounter order; the
    // tile-part walker cross-checks each against the walked spans.
    var tlm_entries: std.ArrayListUnmanaged(TlmEntry) = .empty;
    defer tlm_entries.deinit(allocator);
    var saw_tlm = false;
    // PPM segments (A.7.4) keyed by Zppm; merged into per-tile-part
    // chunks once the main header ends (a chunk may span segments).
    var ppm = PpmCollector{};
    var plm = PlmCollector{};
    // A.4 Table A.1: COD and QCD are required in the main header. Without
    // them coding_params holds only SIZ-seeded defaults and every walk
    // would be fiction (1888.pdf.asan / issue408: openjpeg "required COD
    // marker not found").
    var saw_cod = false;
    var saw_qcd = false;
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

        // T.800 Table A.2: markers FF30..FF3F are reserved and have NO
        // marker segment (no Lxxx). Skip the two bytes; nothing to parse
        // (p0_02 places FF30 after its COM).
        if (marker >= 0xFF30 and marker <= 0xFF3F) {
            pos += 2;
            continue;
        }

        // Delimiting markers — main header ends.
        switch (marker) {
            @intFromEnum(Marker.sot) => {
                // T.800 A.4.1 leaves COD/COC/QCD/QCC order free after SIZ.
                // Quantization tables parse body-driven, so only the coverage
                // check (an entry per subband for every component) waits for
                // the whole main header.
                if (!saw_cod) {
                    try emit(report, allocator, .fail, .jp2_invalid_codestream, pos, "main header has no COD marker segment (T.800 A.4 Table A.1 requires one)");
                    return;
                }
                if (!saw_qcd) {
                    try emit(report, allocator, .fail, .jp2_invalid_codestream, pos, "main header has no QCD marker segment (T.800 A.4 Table A.1 requires one)");
                    return;
                }
                if (report.coding_params) |*cp| try checkQuantCoverage(report, allocator, cp);
                // Hand off to the tile-part walker — it consumes
                // every tile-part via Psot and confirms EOC at end.
                var ppm_chunks: ?PpmChunks = if (ppm.seen) try ppm.merge(report, allocator) else null;
                defer if (ppm_chunks) |*c| c.deinit(allocator);
                const plm_lists: ?[][]u32 = if (plm.seen) try plm.parse(report, allocator) else null;
                defer if (plm_lists) |lists| {
                    for (lists) |l| allocator.free(l);
                    allocator.free(lists);
                };
                try walkTileParts(report, allocator, data, pos, extractor, if (saw_tlm) tlm_entries.items else null, if (ppm_chunks) |*c| c else null, plm_lists, plm.origin);
                return;
            },
            @intFromEnum(Marker.sod), @intFromEnum(Marker.eoc) => {
                // SOD/EOC before any SOT: a codestream with no tile-part
                // carries no image (issue362-2863: a fuzzed SOT became a PPM
                // marker and the walk used to return here silently).
                try emit(report, allocator, .fail, .jp2_invalid_codestream, pos, "SOD/EOC before any SOT: the codestream has no tile-part (T.800 A.4)");
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

        if (marker == 0xFF50) {
            // CAP (T.800 2019 A.5.2 / T.814): declares Part 2 or HTJ2K
            // capabilities. A valid marker jp2z does not act on (c145);
            // the cblksty HT flag decides whether decode is refused.
            try emit(report, allocator, .warn, .jp2_unsupported_marker_ignored, pos - 2, "CAP marker declares Part 2 / HTJ2K capabilities; jp2z validates Part 1 only");
        } else if (!isKnownMainHeaderMarker(marker)) {
            try emit(report, allocator, .warn, .unknown_marker, pos - 2, null);
        }

        // Parse body for markers we have field-level validation for.
        // `pos` points to the Lxxx field; body excluding Lxxx starts
        // at pos+2 and ends at pos+lxxx.
        const body = data[pos + 2 .. pos + lxxx];
        switch (marker) {
            @intFromEnum(Marker.cod) => {
                saw_cod = true;
                try parseCodBody(report, allocator, body, pos);
            },
            @intFromEnum(Marker.qcd) => {
                saw_qcd = true;
                try parseQcdBody(report, allocator, body, pos);
            },
            // QCC (A.6.5) is APPLIED: a per-component quantization table.
            @intFromEnum(Marker.qcc) => if (report.coding_params) |*cp| {
                try parseQccBody(report, allocator, cp, body, pos + 2);
            },
            // COC (A.6.2) and RGN (A.6.3) are APPLIED: per-component coding
            // style and ROI up-shift. A COC carries its own SPcoc, so its
            // order relative to COD is free.
            @intFromEnum(Marker.coc) => if (report.coding_params) |*cp| {
                const ok = try parseCocBody(report, allocator, cp, body, pos + 2);
                if (!ok) report.coding_params = null;
            },
            @intFromEnum(Marker.rgn) => if (report.coding_params) |*cp| {
                try parseRgnBody(report, allocator, cp, body, pos + 2);
            },
            // COM (A.9.2): Rcom 0 = binary, 1 = Latin; other values reserved.
            @intFromEnum(Marker.com) => {
                if (body.len < 2) {
                    try emit(report, allocator, .fail, .bad_marker_length, pos, null);
                } else if (std.mem.readInt(u16, body[0..2], .big) > 1) {
                    try emit(report, allocator, .fail, .jp2_invalid_codestream, pos + 2, "COM Rcom registration value is reserved (T.800 Table A.43: 0 binary, 1 Latin)");
                }
            },
            // CRG (A.9.1): exactly one (Xcrg, Ycrg) u16 pair per component.
            @intFromEnum(Marker.crg) => if (report.coding_params) |cp| {
                if (body.len != 4 * @as(usize, cp.num_components)) {
                    try emit(report, allocator, .fail, .bad_marker_length, pos, "CRG length is not 2 + 4 * Csiz");
                }
            },
            // POC is APPLIED, not ignored: entries parsed here become the
            // default progression-volume list for every tile's packet walk.
            // SIZ precedes POC in a conforming main header (T.800 A.5.1),
            // so coding_params is already seeded; if SIZ was malformed the
            // walk is dead anyway and the POC body is skipped.
            @intFromEnum(Marker.poc) => if (report.coding_params) |*cp| {
                try parsePocBody(report, allocator, body, pos + 2, cp.num_components, &cp.pocs, &cp.num_pocs);
            },
            @intFromEnum(Marker.tlm) => {
                saw_tlm = true;
                try parseTlmBody(report, allocator, body, pos + 2, &tlm_entries);
            },
            @intFromEnum(Marker.ppm) => try ppm.add(report, allocator, body, pos - 2),
            @intFromEnum(Marker.plm) => try plm.add(report, allocator, body, pos - 2),
            else => {},
        }

        pos += lxxx;
    }
}

/// Dev diagnostic: when set, the packet walk prints every contribution
/// (layer, passes, bytes, lblock) for this one code-block to stderr.
/// Null in production — the only I/O in this module, and only when a tool
/// (tools/tile_hist.zig via JP2Z_TRACE_CBLK) asks for it.
pub var debug_trace_key: ?cblk_extract.CblkKey = null;

/// Packed packet headers for ONE tile-part (PPM: T.800 A.7.4, PPT: A.7.5).
/// The packet walk reads headers (and EPH, when signalled) from
/// `buf[pos..]` while packet bodies (and SOP) stay in the tile-part body.
/// `origin` is the codestream offset of the first PPM/PPT marker that fed
/// the store: merged bytes have no single file position, so store-level
/// findings anchor there.
const PackedHeaders = struct {
    buf: []const u8,
    pos: usize = 0,
    origin: u64,
};

/// PPM data after Nppm chunking: `chunks[k]` holds every packet header of
/// the k-th tile-part in codestream order. `buf` owns the merged bytes the
/// chunks slice into.
const PpmChunks = struct {
    buf: []u8,
    chunks: [][]const u8,
    origin: u64,

    fn deinit(self: *PpmChunks, allocator: Allocator) void {
        allocator.free(self.chunks);
        allocator.free(self.buf);
    }
};

/// Collects PPM marker segments by Zppm during the main-header walk and
/// merges them (A.7.4): concatenate in Zppm order, then split into
/// Nppm-prefixed chunks, one per tile-part. Nppm chunks may straddle
/// segment boundaries (g3_colr spreads 3 KB over 214 segments), so the
/// split runs over the concatenation, not per segment.
const PpmCollector = struct {
    /// Zppm → segment bytes after Zppm (slices into the codestream).
    segs: [256]?[]const u8 = @splat(null),
    seen: bool = false,
    origin: u64 = 0,

    /// `body` is the segment after Lppm (Zppm first); `marker_off` is the
    /// FF60 offset for findings. Table A.38: Lppm >= 7 in practice, but a
    /// continuation-only segment needs just Zppm + 1 byte (openjpeg agrees).
    fn add(self: *PpmCollector, report: *ValidationReport, allocator: Allocator, body: []const u8, marker_off: u64) Allocator.Error!void {
        if (!self.seen) {
            self.seen = true;
            self.origin = marker_off;
        }
        if (body.len < 2) {
            try emit(report, allocator, .fail, .bad_marker_length, marker_off + 2, null);
            return;
        }
        const z = body[0];
        if (self.segs[z] != null) {
            // Two segments claim the same Zppm: the concatenation order is
            // undefined, so the whole store is untrustworthy.
            try emit(report, allocator, .fail, .jp2_invalid_codestream, marker_off + 4, "duplicate Zppm index");
            return;
        }
        self.segs[z] = body[1..];
    }

    fn merge(self: *PpmCollector, report: *ValidationReport, allocator: Allocator) Allocator.Error!PpmChunks {
        var total: usize = 0;
        var gap = false;
        var last_present: ?usize = null;
        for (self.segs, 0..) |s, z| {
            if (s) |bytes| {
                if (last_present) |lp| {
                    if (z != lp + 1) gap = true;
                } else if (z != 0) gap = true;
                last_present = z;
                total += bytes.len;
            }
        }
        // Zppm is sequential from 0 (A.7.4); a gap means a segment went
        // missing or an index byte was corrupted. Order is still defined,
        // so the walk continues — surfaced, not fatal.
        if (gap) try emit(report, allocator, .warn, .jp2_invalid_codestream, self.origin + 4, "PPM Zppm indices are not contiguous from 0");
        const buf = try allocator.alloc(u8, total);
        errdefer allocator.free(buf);
        var w: usize = 0;
        for (self.segs) |s| {
            if (s) |bytes| {
                @memcpy(buf[w .. w + bytes.len], bytes);
                w += bytes.len;
            }
        }
        // Split into Nppm chunks. A truncated Nppm or a chunk running past
        // the merged data is a length lie: bad_marker_length, and the
        // chunks parsed so far are kept (later tile-parts then report a
        // missing chunk).
        var chunks: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer chunks.deinit(allocator);
        var p: usize = 0;
        while (p < buf.len) {
            if (p + 4 > buf.len) {
                try emit(report, allocator, .fail, .bad_marker_length, self.origin, "PPM data ends inside an Nppm field");
                break;
            }
            const n: usize = std.mem.readInt(u32, buf[p..][0..4], .big);
            if (p + 4 + n > buf.len) {
                try emit(report, allocator, .fail, .bad_marker_length, self.origin, "Nppm runs past the end of the PPM data");
                break;
            }
            try chunks.append(allocator, buf[p + 4 .. p + 4 + n]);
            p += 4 + n;
        }
        return .{ .buf = buf, .chunks = try chunks.toOwnedSlice(allocator), .origin = self.origin };
    }
};

/// One TLM tile-part-length record. `ttlm == null` means ST=0: entries
/// describe tile-parts in file order with no explicit tile index.
const TlmEntry = struct { ttlm: ?u16, ptlm: u32 };

/// Parse a TLM marker body (T.800 A.7.1): Ztlm(u8), Stlm(u8), then
/// fixed-width entries. Stlm's ST field (bits 4-5) selects the tile-index
/// width (0/1/2 bytes); SP (bit 6) selects u16 or u32 lengths. TLM exists
/// so decoders can seek without walking — a lying entry silently corrupts
/// any consumer that trusts it, which is why the walker cross-checks.
/// Structurally malformed bodies emit bad_marker_length and contribute
/// no entries.
fn parseTlmBody(
    report: *ValidationReport,
    allocator: Allocator,
    body: []const u8,
    offset: usize,
    entries: *std.ArrayListUnmanaged(TlmEntry),
) Allocator.Error!void {
    if (body.len < 2) {
        try emit(report, allocator, .fail, .bad_marker_length, offset, null);
        return;
    }
    const stlm = body[1];
    const st: u8 = (stlm >> 4) & 0x3;
    const sp: u8 = (stlm >> 6) & 0x1;
    // Table A.34: Stlm bits 0-3 and bit 7 are reserved (must be 0).
    if (stlm & 0x8F != 0) {
        try emit(report, allocator, .fail, .jp2_invalid_codestream, offset + 1, "TLM Stlm reserved bits (0-3, 7) set (T.800 Table A.34)");
    }
    if (st == 3) {
        try emit(report, allocator, .fail, .bad_marker_length, offset + 1, null);
        return;
    }
    const entry_len: usize = @as(usize, st) + @as(usize, if (sp == 1) 4 else 2);
    const payload = body[2..];
    if (payload.len % entry_len != 0) {
        try emit(report, allocator, .fail, .bad_marker_length, offset, null);
        return;
    }
    var i: usize = 0;
    while (i < payload.len) : (i += entry_len) {
        const ttlm: ?u16 = switch (st) {
            0 => null,
            1 => payload[i],
            2 => std.mem.readInt(u16, payload[i..][0..2], .big),
            else => unreachable,
        };
        const ptlm: u32 = if (sp == 1)
            std.mem.readInt(u32, payload[i + st ..][0..4], .big)
        else
            std.mem.readInt(u16, payload[i + st ..][0..2], .big);
        try entries.append(allocator, .{ .ttlm = ttlm, .ptlm = ptlm });
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
/// PLM (T.800 A.7.2): main-header packet lengths. After Zplm, one run per
/// tile-part in codestream order: Nplm (byte count) then Iplm, the same
/// 7-bit-continued lengths PLT uses. A tile-part's run may continue into
/// the next PLM segment, so segments are keyed by Zplm and concatenated in
/// index order before parsing (the PPM shape). Until this slice PLM was
/// recognised but never read, so a corrupted PLM passed silently.
const PlmCollector = struct {
    segs: [256]?[]const u8 = @splat(null),
    seen: bool = false,
    origin: u64 = 0,

    fn add(self: *PlmCollector, report: *ValidationReport, allocator: Allocator, body: []const u8, marker_off: u64) Allocator.Error!void {
        if (!self.seen) {
            self.seen = true;
            self.origin = marker_off;
        }
        if (body.len < 1) {
            try emit(report, allocator, .fail, .bad_marker_length, marker_off + 2, "PLM segment has no Zplm");
            return;
        }
        const z = body[0];
        if (self.segs[z] != null) {
            try emit(report, allocator, .fail, .jp2_invalid_codestream, marker_off + 4, "duplicate Zplm index");
            return;
        }
        self.segs[z] = body[1..];
    }

    /// Concatenate in Zplm order and split into per-tile-part length lists.
    /// Caller frees every list and the outer slice.
    fn parse(self: *const PlmCollector, report: *ValidationReport, allocator: Allocator) Allocator.Error![][]u32 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        var gap = false;
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            if (self.segs[i]) |s| {
                if (gap) {
                    try emit(report, allocator, .fail, .jp2_invalid_codestream, self.origin, "PLM Zplm sequence has a gap (T.800 A.7.2)");
                    break;
                }
                try buf.appendSlice(allocator, s);
            } else gap = true;
        }
        var lists: std.ArrayListUnmanaged([]u32) = .empty;
        errdefer {
            for (lists.items) |l| allocator.free(l);
            lists.deinit(allocator);
        }
        var pos: usize = 0;
        while (pos < buf.items.len) {
            const nplm: usize = buf.items[pos];
            pos += 1;
            const end = pos + nplm;
            if (end > buf.items.len) {
                try emit(report, allocator, .fail, .bad_marker_length, self.origin, "PLM Nplm runs past the PLM data (T.800 A.7.2)");
                break;
            }
            var list: std.ArrayListUnmanaged(u32) = .empty;
            errdefer list.deinit(allocator);
            var acc: u32 = 0;
            var mid = false;
            while (pos < end) : (pos += 1) {
                const b = buf.items[pos];
                if (acc > (std.math.maxInt(u32) >> 7)) {
                    try emit(report, allocator, .fail, .bad_marker_length, self.origin, "PLM packet length code overflows (T.800 A.7.2)");
                    acc = 0;
                    mid = false;
                    pos = end;
                    break;
                }
                acc = (acc << 7) | (b & 0x7F);
                if (b & 0x80 != 0) {
                    mid = true;
                    continue;
                }
                try list.append(allocator, acc);
                acc = 0;
                mid = false;
            }
            if (mid) try emit(report, allocator, .fail, .bad_marker_length, self.origin, "PLM packet length code straddles an Nplm boundary (T.800 A.7.2)");
            try lists.append(allocator, try list.toOwnedSlice(allocator));
        }
        return lists.toOwnedSlice(allocator);
    }
};

fn walkTileParts(
    report: *ValidationReport,
    allocator: Allocator,
    data: []const u8,
    start: usize,
    extractor: ?*cblk_extract.CblkExtractor,
    tlm: ?[]const TlmEntry,
    ppm: ?*const PpmChunks,
    plm: ?[]const []const u32,
    plm_origin: u64,
) Allocator.Error!void {
    var pos: usize = start;
    var plm_short = false;
    // TLM cross-check cursor: entry N describes the Nth tile-part in
    // file order. `tlm == null` means no TLM marker was present (an
    // EMPTY list is a present-but-lying TLM and still checks). First
    // disagreement stops the check (a desynced list would otherwise
    // flag every later part).
    var tp_index: usize = 0;
    var tlm_broken = false;
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
    // Per-tile tile-part bookkeeping (T.800 A.4.2): TPsot starts at 0 and
    // arrives strictly sequentially per tile (tiles may interleave); TNsot,
    // once declared nonzero, caps the part count; a completed tile accepts
    // no further parts. Survives TileWalk removal (walk state is freed on
    // completion, but the structural ledger must outlive it).
    const TpState = struct { next_tpsot: u16 = 0, tnsot: u8 = 0, broken: bool = false, complete: bool = false };
    var tp_state = std.AutoHashMap(u16, TpState).init(allocator);
    defer tp_state.deinit();
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
        // Psot 1..13 cannot even hold the 12-byte SOT segment plus SOD —
        // the "next tile-part" it points at would be inside THIS segment.
        // Unwalkable; stop the structural walk here.
        if (psot > 0 and psot < 14) {
            try emit(report, allocator, .fail, .bad_marker_length, pos + 6, null);
            return;
        }
        const isot16: u16 = std.mem.readInt(u16, data[pos + 4 ..][0..2], .big);
        const tpsot: u8 = data[pos + 10];
        const tnsot: u8 = data[pos + 11];
        // Structural soundness of THIS part; an unsound part is skipped by
        // the packet walk below (its bytes cannot be attributed) while the
        // structural traversal continues to the next SOT.
        var part_ok = true;
        // Isot must map into the SIZ tile grid (T.800 A.4.2: Isot ranges
        // over the tiles that exist).
        if (report.coding_params) |p| {
            if (report.width != null and report.height != null) {
                const nt = p.numTilesXY(p.image_x0 + report.width.?, p.image_y0 + report.height.?);
                if (@as(u32, isot16) >= nt.x * nt.y) {
                    try emit(report, allocator, .fail, .jp2_invalid_codestream, pos + 4, null);
                    part_ok = false;
                }
            }
        }
        {
            const st = try tp_state.getOrPut(isot16);
            if (!st.found_existing) st.value_ptr.* = .{};
            const s = st.value_ptr;
            if (s.complete or s.broken) {
                // A part after the tile completed, or after a prior
                // structural violation broke its ledger.
                if (s.complete) try emit(report, allocator, .fail, .jp2_invalid_codestream, pos + 10, null);
                part_ok = false;
            } else if (tpsot != s.next_tpsot) {
                // First part must be TPsot=0; each later part increments.
                try emit(report, allocator, .fail, .jp2_invalid_codestream, pos + 10, null);
                s.broken = true;
                part_ok = false;
            } else if (s.tnsot != 0 and @as(u16, tpsot) + 1 > @as(u16, s.tnsot)) {
                // More tile-parts than TNsot declares: A.4.2 requires TNsot to
                // be the true count or 0. A real-world encoder off-by-one
                // (openjpeg's nonregression corpus: issue206/208/235/254,
                // text_GBR, the eci CIELab set, Britannica 2007 PDF JPX all
                // declare 5 and emit 6) and openjpeg ignoring the field do not
                // make it conformant: FAIL (Peter, 2026-09-12: proven
                // nonconformance fails and is reported). The walk continues so
                // the remaining tile-parts and any later fault are still seen.
                var tn_buf: [96]u8 = undefined;
                const tn_detail = std.fmt.bufPrint(&tn_buf, "tile {d}: tile-part {d} exceeds the declared TNsot {d} (T.800 A.4.2)", .{ isot16, tpsot, s.tnsot }) catch "more tile-parts than TNsot declares";
                try emit(report, allocator, .fail, .jp2_invalid_codestream, pos + 11, tn_detail);
            }
            if (s.tnsot == 0) {
                s.tnsot = tnsot; // first nonzero declaration is authoritative
            } else if (tnsot != 0 and tnsot != s.tnsot) {
                // Conflicting TNsot across parts of the same tile: A.4.2 lets a
                // tile declare one count (or 0). FAIL, walk continues.
                var tc_buf: [96]u8 = undefined;
                const tc_detail = std.fmt.bufPrint(&tc_buf, "tile {d}: tile-part {d} declares TNsot {d} but an earlier part declared {d} (T.800 A.4.2)", .{ isot16, tpsot, tnsot, s.tnsot }) catch "conflicting TNsot across tile-parts";
                try emit(report, allocator, .fail, .jp2_invalid_codestream, pos + 11, tc_detail);
            }
            s.next_tpsot = @as(u16, tpsot) + 1;
        }

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

        // TLM cross-check (T.800 A.7.1): when TLM is present it describes
        // every tile-part; entry tp_index must match THIS part's tile
        // index (when ST!=0 carries one) and walked length. A missing
        // entry means the main header lies about the file's layout.
        if (tlm != null and !tlm_broken) {
            const entries = tlm.?;
            if (tp_index >= entries.len) {
                try emit(report, allocator, .fail, .jp2_invalid_codestream, pos, null);
                tlm_broken = true;
            } else {
                const e = entries[tp_index];
                if (e.ttlm != null and e.ttlm.? != isot16) {
                    try emit(report, allocator, .fail, .jp2_invalid_codestream, pos + 4, null);
                    tlm_broken = true;
                } else if (e.ptlm != next_pos - pos) {
                    try emit(report, allocator, .fail, .jp2_invalid_codestream, pos + 6, null);
                    tlm_broken = true;
                }
            }
        }
        const this_tp = tp_index;
        tp_index += 1;

        // Locate SOD once (reused for the marker scan and the packet walk).
        const sod = findSod(data, pos, next_pos);
        // Scan the tile-part header: flags override markers jp2z doesn't
        // apply per-tile (COD/COC/QCC/RGN) — the tile-part analogue of the
        // main-header I1 scan — and captures the overrides it DOES apply
        // (POC entries for this tile's sequencer; a QCD body span for the
        // tile's params). Independent of CodingParams; runs even when the
        // packet walk below is skipped. The SOT segment is 12 bytes.
        var tp_ov: TileOverrides = .{};
        defer tp_ov.deinit(allocator);
        if (sod) |sod_pos| {
            tp_ov = try scanTilePartHeaderMarkers(report, allocator, data, pos + 12, sod_pos, ppm != null);
        } else {
            // A.4.4: every tile-part carries SOD. Unreachable means a header
            // segment's length runs past the tile-part end (edf_c2_1103421:
            // a COC with Lcoc 521 that openjpeg refuses) or non-marker bytes
            // sit between SOT and SOD. The packet walk is skipped below.
            try emit(report, allocator, .fail, .jp2_invalid_codestream, pos + 12, "tile-part has no reachable SOD: a header segment runs past the tile-part end or bytes between SOT and SOD are not marker segments (T.800 A.4.2/A.4.4)");
        }
        // Packed packet headers for THIS tile-part: PPM chunk `this_tp`
        // (A.7.4: one Nppm chunk per tile-part in codestream order) or the
        // merged PPT store from its own header (A.7.5). A tile-part with no
        // PPM chunk means the main header's chunk list is short — a lie
        // about the layout.
        var packed_store: ?PackedHeaders = null;
        if (ppm) |chunks| {
            if (this_tp < chunks.chunks.len) {
                packed_store = .{ .buf = chunks.chunks[this_tp], .origin = chunks.origin };
            } else {
                try emit(report, allocator, .fail, .packed_headers_mismatch, pos, "tile-part has no PPM chunk");
                part_ok = false;
            }
        } else if (tp_ov.has_ppt) {
            packed_store = .{ .buf = tp_ov.ppt.items, .origin = tp_ov.ppt_origin };
        }
        // Walk this tile-part's packet headers, if the part is structurally
        // sound and we have enough CodingParams to drive the iterator.
        if (report.coding_params) |params| {
            if (part_ok and report.width != null and report.height != null) {
                if (sod) |sod_pos| {
                    const tp_body = data[sod_pos + 2 .. next_pos];
                    // Per-tile, per-component geometry (T.800 B.2/B.3): drive
                    // the packet walk from THIS tile's COMPONENT extent, not the
                    // whole reference grid. Isot (SOT tile index) is at pos+4;
                    // component tile dims = ceil(tx1/dx) − ceil(tx0/dx) (all our
                    // fixtures share dx/dy across components, so use comp 0).
                    // Single-tile, non-sub-sampled files reduce to image dims.
                    // (isot16 was read + range-validated with the SOT fields.)
                    const gop = try tiles.getOrPut(isot16);
                    if (!gop.found_existing) {
                        const isot: u32 = isot16;
                        const xsiz: u32 = params.image_x0 + report.width.?;
                        const ysiz: u32 = params.image_y0 + report.height.?;
                        // The tile's REFERENCE-grid rect; every component's own
                        // sub-sampled tile-component rect is derived inside the
                        // walk (T.800 B.2/B.3), never component 0's for all.
                        const tr = params.tileRect(xsiz, ysiz, isot);
                        // A first-tile-part QCD overrides the main header's
                        // quantization FOR THIS TILE (T.800 A.6.4): Mb per
                        // subband (pass budgets, tier-1 bitplanes) and the
                        // dequant stepsizes both change. p1_04 carries one
                        // on 63 of its 64 tiles.
                        var tile_params = params;
                        var tile_ok = true;
                        // A first-tile-part COD is the tile's coding style
                        // (T.800 A.6.1) — progression, layers, MCT, decomposition,
                        // cblk size/style, wavelet, precincts — and goes FIRST:
                        // the QCD/QCC tables below are sized by its decomp count.
                        // d2_colr switches progression on tiles 1 and 3; f1_mono's
                        // tile 4 declares 7 layers against the main header's 4.
                        if (tp_ov.cod) |span| {
                            // A tile-part COD outranks every main-header COC
                            // (A.6.2 precedence): clear inherited overrides first.
                            tile_params.comp_coding = @splat(null);
                            tile_ok = try parseCodInto(report, allocator, &tile_params, data[span.start..span.end], span.start);
                        }
                        for (tp_ov.coc.items) |span| {
                            if (!try parseCocBody(report, allocator, &tile_params, data[span.start..span.end], span.start)) tile_ok = false;
                        }
                        // Decode reconstructs every tile with the MAIN header's
                        // per-component decomposition/wavelet and MCT; a tile
                        // whose COD/COC changes any of those is validated here
                        // but refused by decode.
                        if (extractor) |ex| {
                            if (tile_params.mct != params.mct) ex.tile_override_unsupported = true;
                            var k: u16 = 0;
                            while (k < params.num_components and k < 16) : (k += 1) {
                                const a = tile_params.codingFor(k);
                                const b = params.codingFor(k);
                                if (a.num_decomp_levels != b.num_decomp_levels or a.wavelet != b.wavelet) ex.tile_override_unsupported = true;
                                // HT code-blocks (T.814): the packet walk is Part-1
                                // tier-2, but the entropy data is not MQ/RAW —
                                // no plan from this tile can be decoded.
                                if (a.cblksty & 0x40 != 0) ex.ht_unsupported = true;
                            }
                        }
                        if (tp_ov.has_qcd) {
                            // A tile-part QCD outranks every main-header QCC
                            // (A.6.5): clear inherited overrides first.
                            tile_params.comp_quant = @splat(null);
                            try parseQcdInto(report, allocator, &tile_params, data[tp_ov.qcd_start..tp_ov.qcd_end], tp_ov.qcd_start);
                        }
                        for (tp_ov.qcc.items) |q| {
                            try parseQccBody(report, allocator, &tile_params, data[q.start..q.end], q.start);
                        }
                        // Tile-part RGN outranks the main header's for its component.
                        for (tp_ov.rgn.items) |span| {
                            try parseRgnBody(report, allocator, &tile_params, data[span.start..span.end], span.start);
                        }
                        if (!tile_ok) {
                            // Unwalkable tile geometry (findings already emitted):
                            // no walk for this tile, and no later part may build
                            // one over the main-header params by mistake.
                            _ = tiles.remove(isot16);
                            if (tp_state.getPtr(isot16)) |s| s.broken = true;
                        } else {
                            gop.value_ptr.* = TileWalk.init(allocator, tile_params, tr.x1 - tr.x0, tr.y1 - tr.y0, tr.x0, tr.y0, isot) catch |e| {
                                // Don't leave a half-built entry in the map.
                                _ = tiles.remove(isot16);
                                return e;
                            };
                        }
                    } else {
                        // COD/QCD/QCC are only honored in a tile's FIRST tile-part
                        // header (T.800 A.6.1/A.6.4/A.6.5 placement); a later one
                        // is ignored — surface it rather than silently drop.
                        if (tp_ov.cod) |span| try emit(report, allocator, .warn, .jp2_unsupported_marker_ignored, span.start - 4, null);
                        if (tp_ov.has_qcd) try emit(report, allocator, .warn, .jp2_unsupported_marker_ignored, tp_ov.qcd_start - 4, null);
                        for (tp_ov.qcc.items) |q| try emit(report, allocator, .warn, .jp2_unsupported_marker_ignored, q.start - 4, null);
                        for (tp_ov.coc.items) |q| try emit(report, allocator, .warn, .jp2_unsupported_marker_ignored, q.start - 4, null);
                        for (tp_ov.rgn.items) |q| try emit(report, allocator, .warn, .jp2_unsupported_marker_ignored, q.start - 4, null);
                    }
                    if (tiles.getPtr(isot16)) |tw| {
                        // POC entries from THIS tile-part's header accumulate
                        // onto the tile's sequencer before its body is walked
                        // (e1_colr: tile 1's two parts each contribute one).
                        try tw.iter.appendVolumes(allocator, tp_ov.entries[0..tp_ov.n]);
                        // A tile-part body is a whole number of packets; resume
                        // this tile's iterator across its tile-parts (TNsot>1).
                        // PLM cross-check (A.7.2): entry N lists the Nth tile-part's
                        // packet lengths. PLT, when present, is walked and PLM is
                        // required to agree with it; otherwise PLM is walked itself.
                        var plm_lengths: ?[]const u32 = null;
                        if (plm) |lists| {
                            if (this_tp < lists.len) {
                                plm_lengths = lists[this_tp];
                            } else if (!plm_short) {
                                plm_short = true;
                                try emit(report, allocator, .fail, .jp2_invalid_codestream, plm_origin, "PLM lists fewer tile-parts than the codestream contains (T.800 A.7.2)");
                            }
                        }
                        if (tp_ov.has_plt and plm_lengths != null and !std.mem.eql(u32, tp_ov.plt.items, plm_lengths.?)) {
                            try emit(report, allocator, .fail, .jp2_invalid_codestream, plm_origin, "PLM and PLT disagree on this tile-part's packet lengths (T.800 A.7.2/A.7.3)");
                        }
                        const lengths: ?[]const u32 = if (tp_ov.has_plt) tp_ov.plt.items else plm_lengths;
                        const res = try walkTilePartBody(report, allocator, tw, tp_body, sod_pos + 2, extractor, lengths, !tp_ov.has_plt and plm_lengths != null, if (packed_store) |*ps| ps else null);
                        if (res != .incomplete) {
                            tw.deinit(allocator);
                            _ = tiles.remove(isot16);
                            // Structural ledger: the tile is done; any further
                            // tile-part claiming it is a violation (and must
                            // not resurrect a fresh TileWalk over old state).
                            if (tp_state.getPtr(isot16)) |s| s.complete = true;
                        }
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
            // PPM chunks left unclaimed: the main header describes more
            // tile-parts than the codestream delivers.
            if (ppm) |chunks| {
                if (chunks.chunks.len > tp_index) {
                    try emit(report, allocator, .fail, .packed_headers_mismatch, chunks.origin, "PPM holds chunks for more tile-parts than the codestream contains");
                }
            }
            if (plm) |lists| {
                if (lists.len > tp_index) {
                    try emit(report, allocator, .fail, .jp2_invalid_codestream, plm_origin, "PLM holds entries for more tile-parts than the codestream contains (T.800 A.7.2)");
                }
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
    for (keys[0..ki]) |isot| {
        // Name what is missing: Marrin.jp2 (Kakadu 5.2.1) declares 2 layers
        // and holds only layer 0's packets; openjpeg/JasPer silently treat
        // the absent packets as empty. The next expected packet comes from
        // the tile's own iterator, which is being reaped anyway.
        const w = tiles.getPtr(isot).?;
        var buf: [192]u8 = undefined;
        const detail: ?[]const u8 = if (w.iter.next()) |pi|
            std.fmt.bufPrint(&buf, "tile {d}: {d} of {d} packets present before the codestream ends (next expected: layer {d} res {d} comp {d} prc {d})", .{ isot, w.packets_seen, w.total, pi.layer, pi.resolution, pi.component, pi.precinct }) catch null
        else
            std.fmt.bufPrint(&buf, "tile {d}: {d} of {d} packets present before the codestream ends", .{ isot, w.packets_seen, w.total }) catch null;
        try emit(report, allocator, .fail, .truncated_stream, offset, detail);
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
    /// PLT-declared packet lengths for THIS tile-part (A.7.3), in Zplt
    /// encounter order. Owned by the caller — deinit after the walk.
    plt: std.ArrayListUnmanaged(u32) = .empty,
    has_plt: bool = false,
    /// PPT (A.7.5): this tile-part's packed packet headers, merged in
    /// Zppt order. Owned by the caller — deinit after the walk.
    ppt: std.ArrayListUnmanaged(u8) = .empty,
    has_ppt: bool = false,
    ppt_origin: u64 = 0,
    /// QCC bodies (after Lqcc) in this tile-part header, as [start, end)
    /// spans of `data`. Applied to the tile's params after its QCD, in
    /// order (A.6.5 precedence: tile QCC > tile QCD > main QCC > main QCD).
    qcc: std.ArrayListUnmanaged(struct { start: usize, end: usize }) = .empty,
    /// COD body (after Lcod) in this tile-part header (T.800 A.6.1: the
    /// tile's coding style — progression, layers, MCT, decomposition,
    /// code-block size/style, wavelet, precincts). Applied FIRST at tile
    /// init, since QCD/QCC sizing depends on its decomposition count.
    cod: ?struct { start: usize, end: usize } = null,
    /// COC / RGN bodies in this tile-part header (A.6.2 / A.6.3), applied
    /// to the tile's params after its COD (tile COC > tile COD > main COC).
    coc: std.ArrayListUnmanaged(struct { start: usize, end: usize }) = .empty,
    rgn: std.ArrayListUnmanaged(struct { start: usize, end: usize }) = .empty,

    fn deinit(self: *TileOverrides, allocator: Allocator) void {
        self.plt.deinit(allocator);
        self.ppt.deinit(allocator);
        self.qcc.deinit(allocator);
        self.coc.deinit(allocator);
        self.rgn.deinit(allocator);
    }
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
    ppm_present: bool,
) Allocator.Error!TileOverrides {
    var out: TileOverrides = .{};
    errdefer out.deinit(allocator);
    // PPT segments arrive in any Zppt order; collect, then merge in index
    // order. 256 slots × slice is 4 KB of stack per tile-part header.
    var ppt_segs: [256]?[]const u8 = @splat(null);
    var p = hdr_start;
    while (p + 4 <= hdr_end) {
        // findSod already walked this span with the same rules, so these
        // two bails are unreachable on a located SOD; the caller reports an
        // unreachable SOD as a FAIL (edf_c2_1103421).
        if (data[p] != 0xFF) return out; // not a marker boundary — stop
        const marker: u16 = (@as(u16, 0xFF) << 8) | @as(u16, data[p + 1]);
        if (marker == @intFromEnum(Marker.sod)) return out;
        if (marker >= 0xFF30 and marker <= 0xFF3F) {
            p += 2; // reserved, no segment (Table A.2)
            continue;
        }
        const lseg = std.mem.readInt(u16, data[p + 2 ..][0..2], .big);
        if (lseg < 2 or p + 2 + lseg > hdr_end) return out; // malformed length — bail
        switch (marker) {
            // Tile-part COC / RGN are APPLIED to the tile: record body spans;
            // the caller parses them after the tile COD (COC) and last (RGN).
            @intFromEnum(Marker.coc) => try out.coc.append(allocator, .{ .start = p + 4, .end = p + 2 + @as(usize, lseg) }),
            @intFromEnum(Marker.rgn) => try out.rgn.append(allocator, .{ .start = p + 4, .end = p + 2 + @as(usize, lseg) }),
            // Tile-part COD is APPLIED (the tile's coding style, A.6.1):
            // record its body span; the caller parses it into the owning
            // tile's params before QCD/QCC (last one wins, like QCD).
            @intFromEnum(Marker.cod) => out.cod = .{ .start = p + 4, .end = p + 2 + @as(usize, lseg) },
            // Tile-part QCC is APPLIED (per-component quantization for this
            // tile): record its body span; the caller parses it into the
            // owning tile's params after the tile QCD.
            @intFromEnum(Marker.qcc) => try out.qcc.append(allocator, .{ .start = p + 4, .end = p + 2 + @as(usize, lseg) }),
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
            // PLT (A.7.3): declared per-packet lengths — 7-bit varints,
            // MSB = continuation. The packet walk cross-checks each
            // against the walked span (SOP+header+EPH+body; the dominant
            // PLT writers include the delimiters so summed entries seek).
            // A varint may not dangle past the segment (openjpeg agrees),
            // and a >u32 length is hostile — both bad_marker_length.
            @intFromEnum(Marker.plt) => {
                out.has_plt = true;
                const body = data[p + 4 .. p + 2 + lseg]; // [Zplt, varints...]
                var acc: u32 = 0;
                var mid = false;
                var q: usize = 1;
                while (q < body.len) : (q += 1) {
                    const b = body[q];
                    if (acc > (std.math.maxInt(u32) >> 7)) {
                        try emit(report, allocator, .fail, .bad_marker_length, p + 4 + q, null);
                        acc = 0;
                        mid = false;
                        break;
                    }
                    acc = (acc << 7) | (b & 0x7F);
                    if (b & 0x80 != 0) {
                        mid = true;
                        continue;
                    }
                    try out.plt.append(allocator, acc);
                    acc = 0;
                    mid = false;
                }
                if (mid) try emit(report, allocator, .fail, .bad_marker_length, p, null);
            },
            // PPT (A.7.5): packed packet headers for this tile-part. Table
            // A.41: Lppt >= 4 (Zppt + at least one Ippt byte). PPM and PPT
            // are mutually exclusive in a codestream (A.7.4).
            @intFromEnum(Marker.ppt) => {
                if (!out.has_ppt) {
                    out.has_ppt = true;
                    out.ppt_origin = p;
                }
                if (ppm_present) {
                    try emit(report, allocator, .fail, .jp2_invalid_codestream, p, "PPT present alongside PPM");
                } else if (lseg < 4) {
                    try emit(report, allocator, .fail, .bad_marker_length, p + 2, null);
                } else {
                    const body = data[p + 4 .. p + 2 + lseg]; // [Zppt, Ippt...]
                    const z = body[0];
                    if (ppt_segs[z] != null) {
                        try emit(report, allocator, .fail, .jp2_invalid_codestream, p + 4, "duplicate Zppt index");
                    } else {
                        ppt_segs[z] = body[1..];
                    }
                }
            },
            else => {},
        }
        p += 2 + @as(usize, lseg);
    }
    if (out.has_ppt) {
        var gap = false;
        var last_present: ?usize = null;
        for (ppt_segs, 0..) |s, z| {
            if (s) |bytes| {
                if (last_present) |lp| {
                    if (z != lp + 1) gap = true;
                } else if (z != 0) gap = true;
                last_present = z;
                try out.ppt.appendSlice(allocator, bytes);
            }
        }
        if (gap) try emit(report, allocator, .warn, .jp2_invalid_codestream, out.ppt_origin + 4, "PPT Zppt indices are not contiguous from 0");
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
fn parseCodInto(
    report: *ValidationReport,
    allocator: Allocator,
    cp_opt: ?*CodingParams,
    body: []const u8,
    offset: usize,
) Allocator.Error!bool {
    if (body.len < 10) {
        try emit(report, allocator, .fail, .bad_marker_length, offset, null);
        return true;
    }
    // SGcod
    // An undefined progression order (Table A.16: 0..4) cannot be walked:
    // FAIL, and the caller un-publishes / skips the tile.
    const prog_order_raw = body[1];
    if (prog_order_raw > 4) {
        try emit(report, allocator, .fail, .jp2_bad_progression_order, offset + 1, null);
        return false;
    }
    const num_layers = std.mem.readInt(u16, body[2..4], .big);
    // SGcod layers: 1..65535 (T.800 Table A.14). Zero layers is
    // non-conformant — there is nothing to decode.
    if (num_layers == 0) {
        try emit(report, allocator, .fail, .jp2_invalid_codestream, offset + 2, null);
    }
    // SGcod MCT is 0 or 1 (Table A.17); any other value names a transform
    // no Part-1 decoder can apply.
    const mct_raw = body[4];
    if (mct_raw > 1) {
        try emit(report, allocator, .fail, .jp2_invalid_codestream, offset + 4, "SGcod multiple component transform value is not 0 or 1");
    }
    // Scod reserved bits 3-7 must be zero. Surface as WARN:
    // unknown-but-decodable per Part 1 rules.
    const scod = body[0];
    if (scod & 0xF8 != 0) {
        // Table A.13 defines bits 0-2. Under a Part-2 Rsiz the rest may be
        // extension-defined (indeterminate, c145); under Part 1 a set bit is
        // a proven violation (Peter, 2026-09-12).
        const part2 = if (report.coding_params) |cp| cp.rsiz & 0x8000 != 0 else false;
        if (part2) {
            try emit(report, allocator, .warn, .jp2_unsupported_marker_ignored, offset, "COD Scod bits 3-7 set under a Part-2 Rsiz: extension-defined, not verified by jp2z");
        } else {
            try emit(report, allocator, .fail, .jp2_invalid_codestream, offset, "COD Scod reserved bits 3-7 set (T.800 Table A.13)");
        }
    }
    // SPcod (shared with COC): decomposition, code-block exponents/style,
    // wavelet, precincts. Out-of-range geometry is CRASH-class downstream
    // and un-publishes/skips (caller) rather than walks.
    var cc: CompCoding = .{ .num_decomp_levels = 0, .cblk_width_exp = 0, .cblk_height_exp = 0, .cblksty = 0, .wavelet = .reversible_5x3, .precinct_sizes = @splat(.{}) };
    // Scod(1) + SGcod(4) = 5 bytes precede SPcod; the caller checked body.len >= 10.
    const walkable = try parseSPcodInto(report, allocator, body[5..], offset + 5, scod & 0x01 != 0, &cc);
    // A.6.1: Lcod = 12 + (Scod&1 ? levels+1 : 0), exactly. openjpeg refuses
    // any other length; a surplus byte is a corrupted or hand-edited header.
    if (walkable) {
        const expected: usize = 10 + (if (scod & 0x01 != 0) @as(usize, cc.num_decomp_levels) + 1 else 0);
        if (body.len != expected) try emit(report, allocator, .fail, .bad_marker_length, offset - 2, "Lcod does not match Scod and the decomposition-level count (T.800 A.6.1)");
    }

    // Update CodingParams (which parseSizBody seeded with num_components).
    if (cp_opt) |cp| {
        if (prog_order_raw <= 4) cp.progression_order = @enumFromInt(prog_order_raw);
        cp.num_layers = num_layers;
        cp.mct = mct_raw == 1;
        cp.scod = scod;
        if (walkable) {
            cp.num_decomp_levels = cc.num_decomp_levels;
            cp.cblk_width_exp = cc.cblk_width_exp;
            cp.cblk_height_exp = cc.cblk_height_exp;
            cp.wavelet = cc.wavelet;
            cp.cblksty = cc.cblksty;
            cp.precinct_sizes = cc.precinct_sizes;
        }
    }
    return walkable;
}

/// Validate + parse an SPcod/SPcoc block (T.800 A.6.1 Table A.15 / A.6.2):
/// `sp[0]` decomposition levels, `sp[1..2]` code-block exponents, `sp[3]`
/// code-block style, `sp[4]` wavelet, then one precinct byte per
/// resolution when `user_precincts`. Findings anchor at `offset` (the
/// codestream offset of `sp[0]`). Fills `out` and returns whether the
/// geometry is walkable: out-of-range decomposition / code-block
/// exponents and a zero HF precinct exponent are CRASH-class downstream
/// (array sizing, u6 shifts), so they FAIL and the caller must not walk
/// with them.
fn parseSPcodInto(
    report: *ValidationReport,
    allocator: Allocator,
    sp: []const u8,
    offset: usize,
    user_precincts: bool,
    out: *CompCoding,
) Allocator.Error!bool {
    if (sp.len < 5) {
        try emit(report, allocator, .fail, .bad_marker_length, offset, null);
        return false;
    }
    var geometry_unsafe = false;
    const decomp_levels = sp[0];
    if (decomp_levels > 32) {
        try emit(report, allocator, .fail, .jp2_invalid_codestream, offset, null);
        geometry_unsafe = true;
    }
    const cblkw_exp = sp[1];
    const cblkh_exp = sp[2];
    // Code-block dimension exponent: 0..8 maps to actual size 4..256.
    if (cblkw_exp > 8 or cblkh_exp > 8) {
        try emit(report, allocator, .fail, .jp2_invalid_codestream, offset + 1, null);
        geometry_unsafe = true;
    } else if (@as(u16, cblkw_exp) + 2 + @as(u16, cblkh_exp) + 2 > 12) {
        // T.800 A.6.1: xcb + ycb <= 12 (code-block area cap, 4096
        // samples). Each exponent can be individually legal while the
        // pair violates the cap — normative, so FAIL, but the geometry
        // is still safely walkable.
        try emit(report, allocator, .fail, .jp2_invalid_codestream, offset + 1, null);
    }
    const cblksty = sp[3];
    // cblksty bit 6 (0x40) is HTJ2K's HT flag (T.814): a valid stream jp2z
    // does not decode (c145 — deep validation is skipped, decode refused).
    // Bit 7 is reserved in Part 1 and T.814 alike: WARN, unknown-but-walkable.
    if (cblksty & 0x40 != 0) {
        try emit(report, allocator, .warn, .jp2_unsupported_marker_ignored, offset + 3, "cblksty declares HT code-blocks (T.814 HTJ2K); jp2z decodes Part 1 code-blocks only");
    }
    if (cblksty & 0x80 != 0) {
        // Table A.19 (and T.814) leave bit 7 reserved. Under a Part-2 Rsiz it
        // is indeterminate (c145); under Part 1 a proven violation.
        const part2 = if (report.coding_params) |cp| cp.rsiz & 0x8000 != 0 else false;
        if (part2) {
            try emit(report, allocator, .warn, .jp2_unsupported_marker_ignored, offset + 3, "cblksty bit 7 set under a Part-2 Rsiz: extension-defined, not verified by jp2z");
        } else {
            try emit(report, allocator, .fail, .jp2_invalid_codestream, offset + 3, "cblksty reserved bit 7 set (T.800 Table A.19)");
        }
    }
    // qmfbid: 0 = 9/7 irreversible (lossy), 1 = 5/3 reversible (lossless).
    const qmfbid = sp[4];
    switch (qmfbid) {
        0 => try emit(report, allocator, .info, .jp2_uses_9x7_wavelet, offset + 4, null),
        1 => try emit(report, allocator, .info, .jp2_uses_5x3_wavelet, offset + 4, null),
        // Table A.20: only 0 (9/7) and 1 (5/3) exist in Part 1; anything
        // else names a transform that cannot be inverted.
        else => try emit(report, allocator, .fail, .jp2_invalid_codestream, offset + 4, "SPcod wavelet transform id is not 0 or 1"),
    }
    const num_resolutions: usize = @as(usize, decomp_levels) + 1;
    const needed_precinct_bytes: usize = if (user_precincts) num_resolutions else 0;
    if (sp.len < 5 + needed_precinct_bytes) {
        try emit(report, allocator, .warn, .jp2_invalid_codestream, offset + sp.len, null);
    }
    if (geometry_unsafe) return false;

    out.num_decomp_levels = decomp_levels;
    out.cblk_width_exp = cblkw_exp;
    out.cblk_height_exp = cblkh_exp;
    out.cblksty = cblksty;
    if (qmfbid <= 1) out.wavelet = @enumFromInt(qmfbid);
    // Precinct sizes (user-defined; else the default 2^15 per resolution).
    out.precinct_sizes = @splat(.{});
    var invalid_precinct = false;
    if (user_precincts and sp.len >= 5 + needed_precinct_bytes) {
        var r: usize = 0;
        while (r < num_resolutions and r < out.precinct_sizes.len) : (r += 1) {
            const byte = sp[5 + r];
            const x_exp: u4 = @intCast(byte & 0x0F);
            const y_exp: u4 = @intCast((byte >> 4) & 0x0F);
            // T.800 B.6: PPx/PPy must be >= 1 for every resolution ABOVE the
            // lowest (r>0) — the HF precinct partition halves the exponent, so a
            // 0 there is non-conformant and would underflow the u6 code-block
            // geometry (crash in TileWalk.init while sizing the pool).
            if (r > 0 and (x_exp == 0 or y_exp == 0)) invalid_precinct = true;
            out.precinct_sizes[r] = .{ .x_exp = x_exp, .y_exp = y_exp };
        }
    }
    if (invalid_precinct) {
        try emit(report, allocator, .fail, .jp2_invalid_codestream, offset + 5, null);
        return false;
    }
    return true;
}

/// COC (T.800 A.6.2): Ccoc (1 byte when Csiz < 257, else 2), Scoc (bit 0 =
/// user precincts; other bits reserved), SPcoc in SPcod layout. Overrides
/// the coding style of ONE component. `offset` addresses `body[0]`.
/// Returns whether the override is walkable (an unsafe one is reported and
/// not installed).
fn parseCocBody(
    report: *ValidationReport,
    allocator: Allocator,
    cp: *CodingParams,
    body: []const u8,
    offset: usize,
) Allocator.Error!bool {
    const cw: usize = if (cp.num_components < 257) 1 else 2;
    if (body.len < cw + 1 + 5) {
        try emit(report, allocator, .fail, .bad_marker_length, offset, null);
        return true;
    }
    const c: u16 = if (cw == 1) body[0] else std.mem.readInt(u16, body[0..2], .big);
    if (c >= cp.num_components) {
        try emit(report, allocator, .fail, .jp2_invalid_codestream, offset, "COC names a component beyond Csiz");
        return true;
    }
    const scoc = body[cw];
    if (scoc & 0xFE != 0) {
        try emit(report, allocator, .warn, .jp2_invalid_codestream, offset + cw, "COC Scoc reserved bits set");
    }
    var cc = cp.codingFor(c);
    const ok = try parseSPcodInto(report, allocator, body[cw + 1 ..], offset + cw + 1, scoc & 0x01 != 0, &cc);
    if (!ok) return false;
    // A.6.2: Lcoc = 9 (or 10 for Csiz >= 257) + (Scoc&1 ? levels+1 : 0), exactly
    // (edf_c2_1103421: openjpeg "Error reading COC marker").
    const expected: usize = cw + 1 + 5 + (if (scoc & 0x01 != 0) @as(usize, cc.num_decomp_levels) + 1 else 0);
    if (body.len != expected) try emit(report, allocator, .fail, .bad_marker_length, offset - 2, "Lcoc does not match Scoc and the decomposition-level count (T.800 A.6.2)");
    if (c >= cp.comp_coding.len) {
        try emit(report, allocator, .warn, .jp2_unsupported_marker_ignored, offset, "COC for a component beyond the 16 jp2z stores");
        return true;
    }
    cp.comp_coding[c] = cc;
    return true;
}

/// RGN (T.800 A.6.3): Crgn (1 or 2 bytes), Srgn (0 = implicit ROI, the only
/// Part 1 style), SPrgn = ROI up-shift (0..37). `offset` addresses `body[0]`.
fn parseRgnBody(
    report: *ValidationReport,
    allocator: Allocator,
    cp: *CodingParams,
    body: []const u8,
    offset: usize,
) Allocator.Error!void {
    const cw: usize = if (cp.num_components < 257) 1 else 2;
    if (body.len < cw + 2) {
        try emit(report, allocator, .fail, .bad_marker_length, offset, null);
        return;
    }
    // A.6.3: Lrgn = 5 (or 6 for Csiz >= 257), exactly.
    if (body.len != cw + 2) try emit(report, allocator, .fail, .bad_marker_length, offset - 2, "Lrgn is not the fixed RGN segment length (T.800 A.6.3)");
    const c: u16 = if (cw == 1) body[0] else std.mem.readInt(u16, body[0..2], .big);
    if (c >= cp.num_components) {
        try emit(report, allocator, .fail, .jp2_invalid_codestream, offset, "RGN names a component beyond Csiz");
        return;
    }
    if (body[cw] != 0) {
        try emit(report, allocator, .warn, .jp2_invalid_codestream, offset + cw, "RGN Srgn is not the implicit ROI style");
    }
    const shift = body[cw + 1];
    if (shift > 37) {
        try emit(report, allocator, .fail, .jp2_invalid_codestream, offset + cw + 1, "RGN SPrgn exceeds 37");
        return;
    }
    if (c >= cp.comp_roishift.len) {
        try emit(report, allocator, .warn, .jp2_unsupported_marker_ignored, offset, "RGN for a component beyond the 16 jp2z stores");
        return;
    }
    cp.comp_roishift[c] = shift;
}

/// Main-header COD: parse into the report's params; un-publish them when
/// the geometry is unwalkable (error.NoCodingParams downstream).
fn parseCodBody(
    report: *ValidationReport,
    allocator: Allocator,
    body: []const u8,
    offset: usize,
) Allocator.Error!void {
    const ok = try parseCodInto(report, allocator, if (report.coding_params) |*cp| cp else null, body, offset);
    if (!ok) report.coding_params = null;
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

/// Parse a QCD/QCC body (Sqcd + SPqcd, T.800 A.6.4/A.6.5) into a
/// QuantTable, BODY-driven: exactly the subband entries the marker carries
/// are read (style 0: one byte each; style 2: two; style 1: LL only, the
/// rest derived per E.5), and the remaining bands default to eps 0 /
/// mant 0 — openjpeg's zero-initialised stepsizes, so a component whose
/// decomposition needs more bands than the marker signalled decodes the
/// same way (p0_08). Whether a table covers its components is checked
/// separately (checkQuantCoverage), once every COD/COC is known, so the
/// parse depends on no other marker's order.
fn parseQuantTable(
    report: *ValidationReport,
    allocator: Allocator,
    table: *QuantTable,
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
    // Table A.28: styles 0, 1, 2 only. A reserved style leaves the
    // subband exponents unknowable — no M_b, no dequant: FAIL.
    if (quant_style > 2) {
        try emit(report, allocator, .fail, .jp2_invalid_codestream, offset, "Sqcd/Sqcc quantization style is not 0, 1 or 2");
        return;
    }
    table.* = .{ .guard_bits = guard_bits, .quant_style = quant_style, .offset = offset, .present = true };
    // Default every band to eps 0 (M_b = G_b - 1), mant 0.
    table.mb = @splat(if (guard_bits >= 1) guard_bits - 1 else 0);
    table.expn = @splat(0);
    table.mant = @splat(0);
    // A.6.4 Table A.28 shapes: style 1 carries exactly ONE 2-byte entry
    // (every subband derives from it, E-5); style 2 entries are 2-byte
    // pairs, so a dangling byte is a corrupted or hand-edited marker.
    if (quant_style == 1 and body.len != 3) {
        try emit(report, allocator, .fail, .bad_marker_length, offset, "scalar-derived quantization (style 1) carries exactly one 2-byte entry (T.800 A.6.4)");
    }
    if (quant_style == 2 and (body.len - 1) % 2 != 0) {
        try emit(report, allocator, .fail, .bad_marker_length, offset, "scalar-expounded quantization (style 2) entries are 2-byte pairs; a dangling byte remains (T.800 A.6.4)");
    }
    switch (quant_style) {
        // Style 0: no quantization (reversible / 5/3). One SPqcd byte per
        // subband — eps_b in bits 7..3, low 3 reserved.
        0 => {
            const count: usize = @min(body.len - 1, table.mb.len);
            var sb: usize = 0;
            while (sb < count) : (sb += 1) {
                const eps: u8 = body[1 + sb] >> 3;
                const sum: u16 = @as(u16, guard_bits) + @as(u16, eps);
                table.mb[sb] = if (sum >= 1) @intCast(sum - 1) else 0;
                table.expn[sb] = eps;
            }
            table.entries = @intCast(count);
        },
        // Style 2: scalar expounded (irreversible / 9/7). Two bytes per
        // subband: eps_b in bits 15..11, mantissa mu_b in 10..0.
        2 => {
            const count: usize = @min((body.len - 1) / 2, table.mb.len);
            var sb: usize = 0;
            while (sb < count) : (sb += 1) {
                const off2: usize = 1 + 2 * sb;
                const eps: u8 = body[off2] >> 3;
                const sum: u16 = @as(u16, guard_bits) + @as(u16, eps);
                table.mb[sb] = if (sum >= 1) @intCast(sum - 1) else 0;
                table.expn[sb] = eps;
                table.mant[sb] = ((@as(u16, body[off2]) & 0x07) << 8) | @as(u16, body[off2 + 1]);
            }
            table.entries = @intCast(count);
            if ((body.len - 1) % 2 != 0) try emit(report, allocator, .warn, .jp2_invalid_codestream, offset + body.len - 1, "odd SPqcd byte count for scalar expounded quantization");
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
            var sb: usize = 0;
            while (sb < table.mb.len) : (sb += 1) {
                const dec_levels: u8 = if (sb == 0) 0 else @intCast((sb - 1) / 3);
                const e: u8 = if (expn0 > dec_levels) expn0 - dec_levels else 0;
                table.expn[sb] = e;
                table.mant[sb] = mant0;
                const sum: u16 = @as(u16, guard_bits) + @as(u16, e);
                table.mb[sb] = if (sum >= 1) @intCast(sum - 1) else 0;
            }
            table.entries = @intCast(table.mb.len);
        },
        else => {},
    }
}

/// Every component's effective quantization table must carry an entry for
/// each of its subbands (1 + 3·decomposition levels). Runs once all COD /
/// COC / QCD / QCC of a header are known — the check is what depends on
/// marker order, so it lives after the walk, not inside the parse.
fn checkQuantCoverage(report: *ValidationReport, allocator: Allocator, cp: *const CodingParams) Allocator.Error!void {
    var c: u16 = 0;
    const n: u16 = @intCast(@min(@as(usize, cp.num_components), cp.comp_quant.len));
    var reported_offsets: [17]usize = undefined;
    var reported: usize = 0;
    while (c < n) : (c += 1) {
        const t = cp.quantFor(c);
        const needed: u16 = 1 + 3 * @as(u16, cp.codingFor(c).num_decomp_levels);
        if (!t.present or t.entries >= needed) continue;
        // One finding per table, not per component sharing it.
        var seen = false;
        for (reported_offsets[0..reported]) |o| if (o == t.offset) {
            seen = true;
        };
        if (seen) continue;
        reported_offsets[reported] = t.offset;
        reported += 1;
        // A.6.4 Table A.28: one entry per subband (3·NL + 1). Under a Part-2
        // Rsiz (T.801 arbitrary decompositions change the subband count) the
        // count is indeterminate here (c145); under Part 1 it is a proven
        // violation (Peter, 2026-09-12).
        if (cp.rsiz & 0x8000 != 0) {
            try emit(report, allocator, .warn, .jp2_unsupported_marker_ignored, t.offset, "quantization marker carries fewer subband entries than a Part-1 decomposition needs; Part-2 decompositions are not verified by jp2z");
        } else {
            try emit(report, allocator, .fail, .jp2_invalid_codestream, t.offset, "quantization marker carries fewer subband entries than a component's decomposition needs (T.800 A.6.4 Table A.28)");
        }
    }
}

/// QCD into `cp`'s default table. Main header: QCC overrides (by marker
/// type, regardless of order) are left alone. Tile-part: the caller
/// clears `comp_quant` first — a tile-part QCD outranks main-header QCCs.
fn parseQcdInto(
    report: *ValidationReport,
    allocator: Allocator,
    cp: *CodingParams,
    body: []const u8,
    offset: usize,
) Allocator.Error!void {
    try parseQuantTable(report, allocator, &cp.quant, body, offset);
}

/// QCC (T.800 A.6.5): Cqcc (1 byte when Csiz < 257, else 2) names the
/// component, then Sqcc/SPqcc in QCD layout. An out-of-range Cqcc is a
/// structural lie (FAIL); a component past the 16 stored slots is valid
/// but unsupported (c145). `offset` addresses `body[0]`.
fn parseQccBody(
    report: *ValidationReport,
    allocator: Allocator,
    cp: *CodingParams,
    body: []const u8,
    offset: usize,
) Allocator.Error!void {
    const cw: usize = if (cp.num_components < 257) 1 else 2;
    if (body.len < cw + 1) {
        try emit(report, allocator, .fail, .bad_marker_length, offset, null);
        return;
    }
    const c: u16 = if (cw == 1) body[0] else std.mem.readInt(u16, body[0..2], .big);
    if (c >= cp.num_components) {
        try emit(report, allocator, .fail, .jp2_invalid_codestream, offset, "QCC names a component beyond Csiz");
        return;
    }
    if (c >= cp.comp_quant.len) {
        try emit(report, allocator, .warn, .jp2_unsupported_marker_ignored, offset, "QCC for a component beyond the 16 jp2z stores");
        return;
    }
    var table: QuantTable = .{};
    try parseQuantTable(report, allocator, &table, body[cw..], offset + cw);
    cp.comp_quant[c] = table;
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
        if (marker >= 0xFF30 and marker <= 0xFF3F) {
            pos += 2; // reserved, no segment (Table A.2)
            continue;
        }
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
    /// Tile rectangle on the REFERENCE grid (origin + extent). Each
    /// component's tile-component rect derives from it via its own
    /// sub-sampling (PacketIterator.compRect) — never component 0's.
    image_w: u32,
    image_h: u32,
    tile_x0: u32,
    tile_y0: u32,
    tile_index: u32,
    layout: SlotLayout,
    states: []packet_header.SubbandState,
    initialised: usize,
    iter: PocSequencer,
    /// Total packets this tile's iterator will yield, and how many have
    /// been consumed across its tile-parts so far. `packets_seen == total`
    /// is the progression-order-INDEPENDENT tile-complete signal — unlike
    /// `iter.done`, which flips on different calls for LRCP vs PCRL/RPCL.
    total: usize,
    packets_seen: usize,

    /// Flat per-component SubbandState pool layout. Per-component because
    /// COC and sub-sampling give components different resolution counts and
    /// precinct grids:
    ///   slot(c, r, sb, p) = base(c) + res_offset[c][r] + sb·precincts_at_r[c][r] + p
    /// Components past the 16th share slot 15's geometry (their SIZ
    /// descriptors repeat it; COC/RGN for them are c145), each with its own
    /// contiguous run: base(c) = base(15) + (c - 15)·slots[15].
    const SlotLayout = struct {
        precincts_at_r: [16][33]u32 = @splat(@splat(0)),
        res_offset: [16][33]usize = @splat(@splat(0)),
        slots: [16]usize = @splat(0),
        base: [16]usize = @splat(0),

        fn index(self: *const SlotLayout, c: u16, r: u8, sb: u8, p: u32) usize {
            const cm: usize = @min(c, self.slots.len - 1);
            const b: usize = if (c < self.base.len) self.base[c] else self.base[self.base.len - 1] + (@as(usize, c) - (self.base.len - 1)) * self.slots[self.slots.len - 1];
            return b + self.res_offset[cm][r] + @as(usize, sb) * @as(usize, self.precincts_at_r[cm][r]) + @as(usize, p);
        }
    };

    /// Build the per-component slot pool (one SubbandState per
    /// (component, resolution, subband, precinct)) and seed the packet
    /// iterator. `image_w`/`image_h`/`tile_x0`/`tile_y0` are the tile's
    /// REFERENCE-grid rect; per-component rects are derived here.
    fn init(
        allocator: Allocator,
        params: jp2z.CodingParams,
        image_w: u32,
        image_h: u32,
        tile_x0: u32,
        tile_y0: u32,
        tile_index: u32,
    ) Allocator.Error!TileWalk {
        var layout: SlotLayout = .{};
        const ngeo: u16 = @intCast(@min(@as(usize, params.num_components), layout.slots.len));
        var running: usize = 0;
        {
            var c: u16 = 0;
            while (c < ngeo) : (c += 1) {
                const cc = params.codingFor(c);
                const rect = PacketIterator.compRect(&params, tile_x0, tile_y0, image_w, image_h, c);
                var slots: usize = 0;
                var r: u8 = 0;
                while (r < cc.num_decomp_levels + 1) : (r += 1) {
                    layout.res_offset[c][r] = slots;
                    const ppx: u4 = @intCast(cc.precinct_sizes[r].x_exp);
                    const ppy: u4 = @intCast(cc.precinct_sizes[r].y_exp);
                    const grid = subbands.numPrecincts(rect.tcx0, rect.tcy0, rect.tcw, rect.tch, cc.num_decomp_levels, r, ppx, ppy);
                    layout.precincts_at_r[c][r] = grid.width * grid.height;
                    slots += @as(usize, subbands.subbandCount(r)) * @as(usize, layout.precincts_at_r[c][r]);
                }
                layout.slots[c] = slots;
                layout.base[c] = running;
                running += slots;
            }
        }
        // Components past the 16th: one more run of slot 15's size each.
        var total_slots: usize = running;
        if (params.num_components > ngeo) total_slots += (@as(usize, params.num_components) - ngeo) * layout.slots[layout.slots.len - 1];
        const states = try allocator.alloc(packet_header.SubbandState, total_slots);
        errdefer allocator.free(states);

        // Slots are filled in ascending index order below, so on OOM
        // mid-loop every slot < `initialised` is live — a single prefix
        // free covers partial init.
        var initialised: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < initialised) : (i += 1) states[i].deinit(allocator);
        }
        {
            var c: u16 = 0;
            while (c < params.num_components) : (c += 1) {
                const cc = params.codingFor(c);
                const rect = PacketIterator.compRect(&params, tile_x0, tile_y0, image_w, image_h, c);
                const cm: usize = @min(c, layout.slots.len - 1);
                var r: u8 = 0;
                while (r < cc.num_decomp_levels + 1) : (r += 1) {
                    const sb_count = subbands.subbandCount(r);
                    const pcount = layout.precincts_at_r[cm][r];
                    const ppx: u4 = @intCast(cc.precinct_sizes[r].x_exp);
                    const ppy: u4 = @intCast(cc.precinct_sizes[r].y_exp);
                    const grid = subbands.numPrecincts(rect.tcx0, rect.tcy0, rect.tcw, rect.tch, cc.num_decomp_levels, r, ppx, ppy);
                    var sb: u8 = 0;
                    while (sb < sb_count) : (sb += 1) {
                        var p: u32 = 0;
                        while (p < pcount) : (p += 1) {
                            const prc_x = p % grid.width;
                            const prc_y = p / grid.width;
                            const cblks = subbands.cblksInPrecinctSubband(
                                rect.tcx0, rect.tcy0, rect.tcw, rect.tch, cc.num_decomp_levels,
                                r, sb, prc_x, prc_y, ppx, ppy,
                                cc.cblk_width_exp, cc.cblk_height_exp,
                            );
                            const slot = layout.index(c, r, sb, p);
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
            .layout = layout,
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
    plt: ?[]const u32,
    plt_from_plm: bool,
    phdr: ?*PackedHeaders,
) Allocator.Error!TilePartResult {
    const params = tw.params;
    const states = tw.states;

    var body_pos: usize = 0;
    // PLT cross-check state (A.7.3): entry N describes the Nth packet of
    // THIS tile-part (ordinal resets per part). First disagreement stops
    // the check — a desynced list would flag every later packet.
    var plt_index: usize = 0;
    var plt_broken = false;
    // Pull packets from the PERSISTENT iterator until this tile-part's
    // body is consumed; the iterator's cursor carries to the next part.
    // With packed headers (PPM/PPT) an empty packet leaves no body bytes
    // at all, so the store's remaining headers ALSO keep the loop alive.
    while (body_pos < tp_body.len or (phdr != null and phdr.?.pos < phdr.?.buf.len)) {
        const packet_start = body_pos;
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

        // This packet's component: its own coding style (COC), tile-component
        // rect (sub-sampling) and ROI shift (RGN).
        const comp: u16 = @intCast(pi.component);
        const cc = params.codingFor(comp);
        const rect = PacketIterator.compRect(&params, tw.tile_x0, tw.tile_y0, tw.image_w, tw.image_h, comp);
        // Per-packet view: SubbandStates for (component, resolution,
        // all-subbands-at-r, this-precinct). value-copied in (will be
        // copied out after readPacketHeader has mutated state).
        var view_buf: [3]packet_header.SubbandState = undefined;
        const sb_count = subbands.subbandCount(pi.resolution);
        var sb: u8 = 0;
        while (sb < sb_count) : (sb += 1) {
            const slot = tw.layout.index(comp, pi.resolution, sb, pi.precinct);
            view_buf[sb] = states[slot];
        }
        const view = view_buf[0..sb_count];

        // Header source: the packed store (PPM/PPT) or the body inline.
        const hdr_bytes: []const u8 = if (phdr) |pk| pk.buf[pk.pos..] else tp_body[body_pos..];
        var reader = BitReader.init(hdr_bytes, .{ .ff_stuffing = true });
        const seg_alloc: ?Allocator = if (extractor != null) allocator else null;
        const contribution_len = (try packet_header.readPacketHeader(&reader, view, pi.layer, cc.cblksty, seg_alloc)) orelse {
            if (phdr) |pk| {
                // The store ran dry mid-header: PPM/PPT holds fewer header
                // bytes than this tile-part's packets need.
                try emit(report, allocator, .fail, .packed_headers_mismatch, pk.origin, "packed packet-header store exhausted before the tile-part's packets");
            } else {
                try emit(report, allocator, .fail, .truncated_stream, body_offset_in_data + body_pos, null);
            }
            return .broken;
        };

        // Write back the (mutated) SubbandState entries.
        sb = 0;
        while (sb < sb_count) : (sb += 1) {
            const slot = tw.layout.index(comp, pi.resolution, sb, pi.precinct);
            states[slot] = view[sb];
        }

        const header_bytes = reader.bytesConsumed();

        // EPH marker (Scod bit 2): follows the byte-aligned packet header when
        // enabled — INSIDE the packed store when PPM/PPT are used (A.7.4/A.7.5).
        var eph_bytes: usize = 0;
        if (params.scod & 0x04 != 0) {
            const eph_at = header_bytes;
            if (eph_at + 2 > hdr_bytes.len or hdr_bytes[eph_at] != 0xFF or hdr_bytes[eph_at + 1] != 0x92) {
                const at: u64 = if (phdr) |pk| pk.origin else body_offset_in_data + body_pos + eph_at;
                try emit(report, allocator, .fail, .jp2_invalid_codestream, at, if (phdr != null) "EPH missing from the packed packet-header store" else null);
                return .broken;
            }
            eph_bytes = 2;
        }
        // Bytes the header (+EPH) occupy in the tile-part BODY: zero when
        // packed, in which case the store's cursor advances instead.
        const hdr_span_in_body: usize = if (phdr != null) 0 else header_bytes + eph_bytes;
        if (phdr) |pk| pk.pos += header_bytes + eph_bytes;

        // M3 brick 9d: per-cblk byte extraction. When an extractor is
        // wired in, we slice each cblk's contribution bytes out of the
        // tile-part body in the SAME order readPacketHeader walked them
        // (subband × cblk row-major), and append to the extractor's
        // per-cblk byte buffer. The extractor stamps subband-internal
        // rect + zero_bitplanes + cblksty on first sight and tracks the
        // running total_passes.
        if (extractor) |ex| {
            const ppx: u4 = @intCast(cc.precinct_sizes[pi.resolution].x_exp);
            const ppy: u4 = @intCast(cc.precinct_sizes[pi.resolution].y_exp);
            const prc_grid = subbands.numPrecincts(rect.tcx0, rect.tcy0, rect.tcw, rect.tch, cc.num_decomp_levels, pi.resolution, ppx, ppy);
            const roishift: u8 = params.roishiftFor(comp);
            const prc_x_in_grid: u32 = if (prc_grid.width == 0) 0 else pi.precinct % prc_grid.width;
            const prc_y_in_grid: u32 = if (prc_grid.width == 0) 0 else pi.precinct / prc_grid.width;
            const data_base = body_pos + hdr_span_in_body;
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
                        // Not included in this packet → nothing to record. A cblk
                        // included with passes but ZERO bytes still appends, so its
                        // plan.total_passes advances (openjpeg runs those passes over
                        // the exhausted stream; the budget check counts them too).
                        if (cb.last_contribution_passes == 0) continue;
                        const L: usize = cb.last_contribution_length;
                        if (debug_trace_key) |k| {
                            if (k.tile == tw.tile_index and k.component == comp and k.resolution == pi.resolution and k.band == band_for_key and k.precinct == pi.precinct and k.grid_x == gx and k.grid_y == gy) {
                                std.debug.print("trace cblk: layer {d} passes {d} bytes {d} lblock {d} total_passes {d} zbp {d} src_offset {d}\n", .{ pi.layer, cb.last_contribution_passes, L, cb.lblock, cb.total_passes, cb.zero_bitplanes, body_offset_in_data + data_base + bytes_so_far });
                            }
                        }
                        if (data_base + bytes_so_far + L > tp_body.len) {
                            // Bounds-mismatched contribution; the post-loop
                            // emit() below catches the structural issue.
                            break;
                        }
                        const cb_rect = subbands.cblkSubbandRect(
                            rect.tcx0, rect.tcy0, rect.tcw, rect.tch, cc.num_decomp_levels,
                            pi.resolution, ex_sb,
                            prc_x_in_grid, prc_y_in_grid,
                            ppx, ppy,
                            cc.cblk_width_exp, cc.cblk_height_exp,
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
                            .sb_x0 = cb_rect.x0,
                            .sb_y0 = cb_rect.y0,
                            .sb_x1 = cb_rect.x1,
                            .sb_y1 = cb_rect.y1,
                            .zero_bitplanes = cb.zero_bitplanes,
                            // Coded bit-planes = M_b + ROI shift (T.800 H.1: the
                            // encoder up-shifts ROI coefficients by SPrgn), minus
                            // the zero bit-planes — folded into plan.numbps.
                            .m_b = params.mbForSubband(comp, pi.resolution, band_for_key) +| roishift,
                            .qcd_expn = params.quantFor(comp).expn[CodingParams.subbandIndex(pi.resolution, band_for_key)],
                            .qcd_mant = params.quantFor(comp).mant[CodingParams.subbandIndex(pi.resolution, band_for_key)],
                            .roishift = roishift,
                            .src_offset = body_offset_in_data + data_base + bytes_so_far,
                            .cblksty = cc.cblksty,
                            .total_passes = cb.total_passes,
                            .segments = cb.segments.items,
                        });
                        bytes_so_far += @intCast(L);
                    }
                }
            }
        }

        const advance = hdr_span_in_body + @as(usize, contribution_len);
        if (body_pos + advance > tp_body.len) {
            try emit(report, allocator, .fail, .truncated_stream, body_offset_in_data + body_pos + advance, null);
            return .broken;
        }
        body_pos += advance;

        // PLT cross-check: the walked packet span (SOP marker if present
        // + header + EPH + body) must equal the declared length. A packet
        // beyond the declared list means the header lies about this
        // tile-part's layout.
        if (plt != null and !plt_broken) {
            const lengths = plt.?;
            const walked: u32 = @intCast(body_pos - packet_start);
            if (plt_index >= lengths.len or lengths[plt_index] != walked) {
                const detail: []const u8 = if (plt_from_plm) "PLM packet length disagrees with the walked packet (T.800 A.7.2)" else "PLT packet length disagrees with the walked packet (T.800 A.7.3)";
                try emit(report, allocator, .fail, .jp2_invalid_codestream, body_offset_in_data + packet_start, detail);
                plt_broken = true;
            }
            plt_index += 1;
        }
    }

    // A packed store (PPM chunk / PPT) describes exactly this tile-part's
    // packets: bytes left over once its packets are exhausted mean the
    // header lies about the layout (or a packet body went missing).
    var store_drained = true;
    if (phdr) |pk| {
        if (pk.pos != pk.buf.len) {
            store_drained = false;
            try emit(report, allocator, .fail, .packed_headers_mismatch, pk.origin, "packed packet-header store has bytes left over after the tile-part's packets");
        }
    }

    // Disposition. The iterator yields exactly `tw.total` packets across the tile's
    // tile-parts; once we've seen them all the tile is complete. This is
    // order-independent (LRCP/PCRL/RPCL set iter.done on different calls).
    if (tw.packets_seen >= tw.total) {
        // Surface walker-vs-tile match status. Only meaningful when COD
        // was fully parsed (num_layers > 0).
        if (params.num_layers > 0) {
            if (body_pos == tp_body.len and store_drained) {
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
    //   C4: Csiz ∈ [1, 16384] (T.800 A.5.1). jp2z's per-component arrays
    //       hold 16; components past the 16th are accepted when they repeat
    //       the 16th's descriptor (see below) — never rejected as invalid.
    //   numTilesXY underflow: tile grid non-degenerate, tile origin ≤ image origin.
    //   image extent must be positive.
    if (csiz == 0 or csiz > 16384 or
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
    // Rsiz (A.5.1 Table A.9): 0 = Part 1 (no profile), 1 = Profile 0,
    // 2 = Profile 1. Bits 14/15 declare Part 2 / HTJ2K capabilities — a
    // valid stream jp2z does not decode (c145). Any other value is an
    // undefined Part-1 profile: surfaced, but the codestream stays walkable.
    const rsiz = std.mem.readInt(u16, body[2..4], .big);
    cp_local.rsiz = rsiz;
    if (rsiz & 0xC000 != 0) {
        try emit(report, allocator, .warn, .jp2_unsupported_marker_ignored, pos, "SIZ Rsiz declares Part 2 / HTJ2K capabilities");
    } else if (rsiz > 2) {
        // Profiles added by amendments (values per openjpeg's OPJ_PROFILE_*
        // table): 3..7 digital cinema (2K, 4K, scalable 2K/4K, long-term
        // storage; T.800 Amd 1/2), 0x0100..0x0300 + mainlevel 0..11
        // broadcast (Amd 3), 0x0400..0x0900 + mainlevel 0..11 / sublevel
        // 0..9 IMF (Amd 8). Recognised but their constraints are not
        // verified here: valid-but-unchecked (c145). Anything else is
        // defined by no edition or amendment: FAIL.
        const hi = rsiz & 0xFF00;
        const mainlevel = rsiz & 0x000F;
        const sublevel = (rsiz & 0x00F0) >> 4;
        const cinema = rsiz >= 3 and rsiz <= 7;
        const broadcast = (hi == 0x0100 or hi == 0x0200 or hi == 0x0300) and sublevel == 0 and mainlevel <= 11;
        const imf = hi >= 0x0400 and hi <= 0x0900 and mainlevel <= 11 and sublevel <= 9;
        if (cinema or broadcast or imf) {
            try emit(report, allocator, .warn, .jp2_unsupported_marker_ignored, pos, "SIZ Rsiz declares a cinema/broadcast/IMF profile (T.800 amendments); its constraints are not verified by jp2z");
        } else {
            try emit(report, allocator, .fail, .jp2_invalid_siz, pos, "SIZ Rsiz value is defined by neither T.800 Table A.9 nor its amendments");
        }
    }
    // A.5.1: the tile grid may not exceed 65535 tiles (Isot is 16-bit).
    {
        const nt = cp_local.numTilesXY(xsiz, ysiz);
        if (@as(u64, nt.x) * @as(u64, nt.y) > 65535) {
            try emit(report, allocator, .fail, .jp2_invalid_siz, pos, "tile grid exceeds 65535 tiles");
            return;
        }
    }
    // Components past the 16th are read through slot 15: valid as long as
    // their descriptor matches it (every consumer already clamps with
    // @min(c, 15)). A differing descriptor is an unsupported-but-valid
    // stream (c145), surfaced once after the loop.
    var nonuniform_tail = false;
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
        const prec: u8 = (ssiz & 0x7F) + 1;
        const signed = ssiz & 0x80 != 0;
        // Table A.10: component precision is 1..38 bits.
        if (prec > 38) {
            try emit(report, allocator, .fail, .jp2_invalid_siz, pos, "component precision exceeds 38 bits");
            return;
        }
        if (ci < cp_local.comp_prec.len) {
            cp_local.comp_prec[ci] = prec;
            if (signed) cp_local.comp_signed |= (@as(u16, 1) << @intCast(ci));
            cp_local.comp_dx[ci] = xrsiz;
            cp_local.comp_dy[ci] = yrsiz;
        } else {
            const last = cp_local.comp_prec.len - 1;
            const last_signed = (cp_local.comp_signed >> @intCast(last)) & 1 != 0;
            if (prec != cp_local.comp_prec[last] or signed != last_signed or xrsiz != cp_local.comp_dx[last] or yrsiz != cp_local.comp_dy[last]) {
                nonuniform_tail = true;
            }
        }
    }
    if (nonuniform_tail) {
        try emit(report, allocator, .warn, .jp2_unsupported_marker_ignored, pos, "components beyond the 16th carry descriptors that differ from the 16th's; jp2z reads them through the 16th");
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
    try std.testing.expectEqual(@as(u8, 2), cp.quant.guard_bits);
    try std.testing.expectEqual(@as(u8, 0), cp.quant.quant_style);
    try std.testing.expectEqual(@as(u8, 9),  cp.quant.mb[0]);
    try std.testing.expectEqual(@as(u8, 10), cp.quant.mb[1]);
    try std.testing.expectEqual(@as(u8, 10), cp.quant.mb[2]);
    try std.testing.expectEqual(@as(u8, 11), cp.quant.mb[3]);
    try std.testing.expectEqual(@as(u8, 11), cp.quant.mb[4]);
    try std.testing.expectEqual(@as(u8, 11), cp.quant.mb[5]);
    try std.testing.expectEqual(@as(u8, 12), cp.quant.mb[6]);
}

test "CodingParams.mbForSubband: r=0 -> idx 0; r>=1 -> 3*(r-1)+band" {
    var cp = jp2z.CodingParams{ .num_decomp_levels = 2 };
    cp.quant.mb[0] = 9;
    cp.quant.mb[1] = 10;
    cp.quant.mb[2] = 11;
    cp.quant.mb[3] = 12;
    cp.quant.mb[4] = 13;
    cp.quant.mb[5] = 14;
    cp.quant.mb[6] = 15;

    try std.testing.expectEqual(@as(u8, 9),  cp.mbForSubband(0, 0, 0));
    try std.testing.expectEqual(@as(u8, 10), cp.mbForSubband(0, 1, 1));
    try std.testing.expectEqual(@as(u8, 11), cp.mbForSubband(0, 1, 2));
    try std.testing.expectEqual(@as(u8, 12), cp.mbForSubband(0, 1, 3));
    try std.testing.expectEqual(@as(u8, 13), cp.mbForSubband(0, 2, 1));
    try std.testing.expectEqual(@as(u8, 14), cp.mbForSubband(0, 2, 2));
    try std.testing.expectEqual(@as(u8, 15), cp.mbForSubband(0, 2, 3));
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
