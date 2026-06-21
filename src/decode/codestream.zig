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
const Severity = errors.Severity;
const Variant = errors.Variant;
const FindingCode = errors.FindingCode;
const Finding = jp2z.Finding;
const ValidationReport = jp2z.ValidationReport;

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
    /// Per-subband quantization exponent (irreversible). Index matches
    /// mb_per_subband / stepsizes order: [0]=LL@r0, then 3 per resolution.
    qcd_expn: [97]u8 = @splat(0),
    /// Per-subband quantization mantissa (11-bit) for irreversible dequant.
    qcd_mant: [97]u16 = @splat(0),

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

    pub fn init(params: CodingParams, image_w: u32, image_h: u32) PacketIterator {
        var iter: PacketIterator = .{
            .params = params,
            .image_w = image_w,
            .image_h = image_h,
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
                image_w, image_h, params.num_decomp_levels, r, ppx, ppy);
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
        const r = self.resolution;
        const ppx: u4 = @intCast(self.params.precinct_sizes[r].x_exp);
        const ppy: u4 = @intCast(self.params.precinct_sizes[r].y_exp);
        const p_idx = subbands.precinctIndexAt(
            self.image_w, self.image_h, self.params.num_decomp_levels,
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

    fn advanceRpcl(self: *PacketIterator) void {
        // Nesting (inner→outer): l, c, x, y, r.
        self.layer += 1;
        if (self.layer < self.params.num_layers) return;
        self.layer = 0;
        self.component += 1;
        if (self.component < self.params.num_components) return;
        self.component = 0;
        self.x += self.ref_stride_x_at_r[self.resolution];
        if (self.x < self.image_w) return;
        self.x = 0;
        self.y += self.ref_stride_y_at_r[self.resolution];
        if (self.y < self.image_h) return;
        self.y = 0;
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
            // at (x, y) for the current precinct exponents.
            while (self.resolution < num_resolutions) {
                const ppx: u4 = @intCast(self.params.precinct_sizes[self.resolution].x_exp);
                const ppy: u4 = @intCast(self.params.precinct_sizes[self.resolution].y_exp);
                if (subbands.isOnPrecinctBoundary(
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
                    self.image_w, self.image_h, self.params.num_decomp_levels,
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
            switch (self.params.progression_order) {
                .pcrl => {
                    // Inner→outer past r: c, x, y.
                    self.component += 1;
                    if (self.component < self.params.num_components) continue;
                    self.component = 0;
                    self.x += self.min_stride_x;
                    if (self.x < self.image_w) continue;
                    self.x = 0;
                    self.y += self.min_stride_y;
                    if (self.y < self.image_h) continue;
                    self.done = true;
                },
                .cprl => {
                    // Inner→outer past r: x, y, c.
                    self.x += self.min_stride_x;
                    if (self.x < self.image_w) continue;
                    self.x = 0;
                    self.y += self.min_stride_y;
                    if (self.y < self.image_h) continue;
                    self.y = 0;
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

        // Walk this tile-part's packet headers, if we have enough
        // CodingParams to drive the iterator and width/height.
        if (report.coding_params) |params| {
            if (report.width != null and report.height != null) {
                if (findSod(data, pos, next_pos)) |sod_pos| {
                    const tp_body = data[sod_pos + 2 .. next_pos];
                    try walkPackets(report, allocator, tp_body, params, report.width.?, report.height.?, sod_pos + 2, extractor);
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
                cp.precinct_sizes[r] = .{
                    .x_exp = @intCast(byte & 0x0F),
                    .y_exp = @intCast((byte >> 4) & 0x0F),
                };
            }
        }
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
    const guard_bits: u8 = sqcd >> 5;
    if (quant_style > 2) {
        try emit(report, allocator, .warn, .jp2_invalid_codestream, offset, null);
    }

    // Populate per-subband M_b on CodingParams (T.800 A.6.4 Table A.30
    // + E.1). SIZ/COD parsing seeded num_components / num_decomp_levels;
    // we lay M_b across subband index space here so the tier-1 dispatcher
    // can pick it up per (resolution, band).
    if (report.coding_params) |*cp| {
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
fn walkPackets(
    report: *ValidationReport,
    allocator: Allocator,
    tp_body: []const u8,
    params: jp2z.CodingParams,
    image_w: u32,
    image_h: u32,
    body_offset_in_data: usize,
    extractor: ?*cblk_extract.CblkExtractor,
) Allocator.Error!void {
    const num_resolutions: u8 = params.num_decomp_levels + 1;

    // Per-resolution precinct counts and a prefix-sum offset into
    // the flat per-component slot array. With per-(component,
    // resolution, subband, precinct) layout, each component owns
    //   sum_r (subband_count(r) × precincts_at_r[r])
    // SubbandStates back-to-back; resolution_offset[r] indexes the
    // start of resolution r within one component's pool.
    var precincts_at_r: [33]u32 = @splat(0);
    var resolution_offset: [33]usize = @splat(0);
    var slots_per_component: usize = 0;
    {
        var r: u8 = 0;
        while (r < num_resolutions) : (r += 1) {
            resolution_offset[r] = slots_per_component;
            const ppx: u4 = @intCast(params.precinct_sizes[r].x_exp);
            const ppy: u4 = @intCast(params.precinct_sizes[r].y_exp);
            const grid = subbands.numPrecincts(image_w, image_h, params.num_decomp_levels, r, ppx, ppy);
            precincts_at_r[r] = grid.width * grid.height;
            slots_per_component += @as(usize, subbands.subbandCount(r)) * @as(usize, precincts_at_r[r]);
        }
    }

    const total_slots: usize = slots_per_component * @as(usize, params.num_components);
    if (total_slots == 0) return; // degenerate — nothing to walk

    const states = try allocator.alloc(packet_header.SubbandState, total_slots);
    var initialised: usize = 0;
    // Single deinit/free path covers both partial-init failure
    // (allocator OOM mid-loop) and fully-initialised success.
    defer {
        var i: usize = 0;
        while (i < initialised) : (i += 1) states[i].deinit(allocator);
        allocator.free(states);
    }

    // Populate every slot — one SubbandState per
    // (component, resolution, subband, precinct), sized to that
    // precinct's cblk count via cblksInPrecinctSubband. Empty
    // (0×0) precincts get an empty SubbandState (a no-op for
    // readPacketHeader's inner loop).
    {
        var c: u16 = 0;
        while (c < params.num_components) : (c += 1) {
            var r: u8 = 0;
            while (r < num_resolutions) : (r += 1) {
                const sb_count = subbands.subbandCount(r);
                const pcount = precincts_at_r[r];
                const ppx: u4 = @intCast(params.precinct_sizes[r].x_exp);
                const ppy: u4 = @intCast(params.precinct_sizes[r].y_exp);
                const grid = subbands.numPrecincts(image_w, image_h, params.num_decomp_levels, r, ppx, ppy);
                var sb: u8 = 0;
                while (sb < sb_count) : (sb += 1) {
                    var p: u32 = 0;
                    while (p < pcount) : (p += 1) {
                        const prc_x = p % grid.width;
                        const prc_y = p / grid.width;
                        const cblks = subbands.cblksInPrecinctSubband(
                            image_w, image_h, params.num_decomp_levels,
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

    // Walk every packet via the full per-r-variable-precinct iterator.
    var iter = jp2z.PacketIterator.init(params, image_w, image_h);
    var body_pos: usize = 0;
    while (iter.next()) |pi| {
        if (body_pos >= tp_body.len) {
            try emit(report, allocator, .fail, .truncated_stream, body_offset_in_data + body_pos, null);
            return;
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
            return;
        };

        // Write back the (mutated) SubbandState entries.
        sb = 0;
        while (sb < sb_count) : (sb += 1) {
            const slot = slotIndex(@intCast(pi.component), pi.resolution, sb, pi.precinct, resolution_offset, precincts_at_r, slots_per_component);
            states[slot] = view[sb];
        }

        const header_bytes = reader.bytesConsumed();

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
            const prc_grid = subbands.numPrecincts(image_w, image_h, params.num_decomp_levels, pi.resolution, ppx, ppy);
            const prc_x_in_grid: u32 = if (prc_grid.width == 0) 0 else pi.precinct % prc_grid.width;
            const prc_y_in_grid: u32 = if (prc_grid.width == 0) 0 else pi.precinct / prc_grid.width;
            const data_base = body_pos + header_bytes;
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
                            image_w, image_h, params.num_decomp_levels,
                            pi.resolution, ex_sb,
                            prc_x_in_grid, prc_y_in_grid,
                            ppx, ppy,
                            params.cblk_width_exp, params.cblk_height_exp,
                            gx, gy,
                        );
                        try ex.appendContribution(.{
                            .tile = 0, // single-tile fixtures only today
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
                            .cblksty = params.cblksty,
                            .total_passes = cb.total_passes,
                            .segments = cb.segments.items,
                        });
                        bytes_so_far += @intCast(L);
                    }
                }
            }
        }

        const advance = header_bytes + @as(usize, contribution_len);
        if (body_pos + advance > tp_body.len) {
            try emit(report, allocator, .fail, .truncated_stream, body_offset_in_data + body_pos + advance, null);
            return;
        }
        body_pos += advance;
    }

    // Surface walker-vs-tile-part-body match status as findings.
    // Only meaningful when COD was fully parsed (num_layers > 0).
    if (params.num_layers > 0) {
        if (body_pos == tp_body.len) {
            try emit(report, allocator, .info, .jp2_packets_walked_to_end, body_offset_in_data, null);
        } else if (body_pos < tp_body.len) {
            try emit(report, allocator, .warn, .jp2_packets_under_read, body_offset_in_data + body_pos, null);
        }
    }
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
fn parseSizBody(report: *ValidationReport, body: []const u8) void {
    const xsiz = std.mem.readInt(u32, body[4..8], .big);
    const ysiz = std.mem.readInt(u32, body[8..12], .big);
    const xosiz = std.mem.readInt(u32, body[12..16], .big);
    const yosiz = std.mem.readInt(u32, body[16..20], .big);
    const csiz = std.mem.readInt(u16, body[36..38], .big);

    if (xsiz <= xosiz or ysiz <= yosiz) return; // leave width/height null
    report.width = xsiz - xosiz;
    report.height = ysiz - yosiz;
    // Seed CodingParams with the SIZ-derived field. Remaining
    // fields default until parseCodBody overwrites them.
    var cp_local: jp2z.CodingParams = .{ .num_components = csiz };
    const ncomp: usize = @min(@as(usize, csiz), 16);
    var ci: usize = 0;
    while (ci < ncomp) : (ci += 1) {
        // Each component descriptor is 3 bytes; Ssiz is the first.
        const ssiz = body[38 + ci * 3];
        cp_local.comp_prec[ci] = (ssiz & 0x7F) + 1;
        if (ssiz & 0x80 != 0) cp_local.comp_signed |= (@as(u16, 1) << @intCast(ci));
    }
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
