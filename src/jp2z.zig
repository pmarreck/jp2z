//! jp2z — cleanroom JPEG 2000 (T.800) decoder. Public API hub.
//!
//! Mirrors jpegz's public-API shape (DecodeOptions, FindingsSink,
//! lenient mode, internal.* oracle namespace) so consumers can
//! treat the two libraries uniformly and so jpegz's planned
//! re-export shim at jp2z M6 is a 5-line file.
//!
//! Phase 1 (now): `decode` / `decodeWithOptions` delegate to the
//! openjpeg wrapper at `ffi/openjpeg_wrapper.zig`. The wrapper
//! handles both JP2 (file format) and J2K (raw codestream).
//!
//! Phase 2 (multi-month): each milestone adds a cleanroom path
//! (codestream walker → tier-2 → tier-1 EBCOT → 5/3 wavelet →
//! 9/7 wavelet → MCT) and shrinks the wrapper's runtime role.
//!
//! Phase 3 (cleanroom complete, M6): wrapper moves to
//! `internal.openjpegDecode` for build-time oracle use only;
//! runtime decode is pure Zig.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ── Re-exports from canonical core modules ──────────────────────
const errors = @import("core/errors.zig");
pub const DecodeError = errors.DecodeError;
pub const Severity = errors.Severity;
pub const Variant = errors.Variant;
pub const FindingCode = errors.FindingCode;

const core_types = @import("core/types.zig");
pub const ColorSpace = core_types.ColorSpace;
pub const PixelLayout = core_types.PixelLayout;
pub const Image = core_types.Image;
pub const ImageMetadata = core_types.ImageMetadata;

/// Side-channel collector for spec-deviation findings emitted by
/// the cleanroom decoder during lenient (tolerant) decode. Same
/// shape as `jpegz.FindingsSink`. Caller-owned; pair with
/// `decodeWithOptions(.. .findings_sink = &sink, .lenient = true)`
/// to capture warnings.
pub const FindingsSink = @import("decode/findings.zig").FindingsSink;

pub const version: [:0]const u8 = "0.0.1";

const last_error = @import("core/last_error.zig");

pub fn lastErrorMessage() []const u8 {
    return last_error.current();
}

// ─────────────────────────────────────────────────────────────────────
// Pixel-data types are re-exported above. See `core/types.zig`.
// ─────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────
// Validation
// ─────────────────────────────────────────────────────────────────────

pub const Finding = struct {
    severity: Severity,
    code: FindingCode,
    offset: ?u64 = null,
    detail: ?[]const u8 = null,
};

pub const ProgressionOrder = @import("decode/codestream.zig").ProgressionOrder;
pub const WaveletFilter = @import("decode/codestream.zig").WaveletFilter;
pub const CodingParams = @import("decode/codestream.zig").CodingParams;
pub const PrecinctSize = @import("decode/codestream.zig").PrecinctSize;
pub const PacketIndex = @import("decode/codestream.zig").PacketIndex;
pub const PacketIterator = @import("decode/codestream.zig").PacketIterator;
pub const BitReader = @import("decode/bit_reader.zig").BitReader;
pub const TagTree = @import("decode/tag_tree.zig").TagTree;
pub const CblkDecodePlan = @import("decode/cblk_plan.zig").CblkDecodePlan;
pub const CblkDecodePlanList = @import("decode/cblk_plan.zig").CblkDecodePlanList;
pub const ValidationReport = struct {
    overall: Severity,
    variant: Variant,
    width: ?u32,
    height: ?u32,
    findings: std.ArrayList(Finding),
    /// Populated when the walker successfully parses SIZ + COD.
    /// `null` if the codestream didn't get that far. Tier-2 packet
    /// walking (M2+) keys off this; consumers can also use it for
    /// codec-feature introspection (wavelet filter, MCT, etc.).
    coding_params: ?CodingParams = null,

    pub fn isOk(self: ValidationReport) bool {
        return self.overall == .pass or self.overall == .info or self.overall == .warn;
    }

    pub fn deinit(self: *ValidationReport, allocator: Allocator) void {
        for (self.findings.items) |f| {
            if (f.detail) |d| allocator.free(d);
        }
        self.findings.deinit(allocator);
        self.* = undefined;
    }
};

// ─────────────────────────────────────────────────────────────────────
// Decode
// ─────────────────────────────────────────────────────────────────────

pub const DecodeOptions = struct {
    /// Number of threads jp2z may use for parallelizable decode steps.
    /// Mirror of jpegz's threading convention. Phase 1 wrapper does
    /// not yet plumb this through to `opj_codec_set_threads` — that
    /// lands as a wrapper-side enhancement when a consumer asks.
    threads: u8 = 1,

    /// `false` (default) — strict decode; bitstream deviations
    /// return `DecodeError`. `true` — tolerant decode (Phase 2:
    /// recover partial images, emit findings into `findings_sink`).
    /// In Phase 1 the openjpeg wrapper ignores this flag (openjpeg
    /// has its own tolerance posture); kept on the API surface so
    /// Phase 2 cleanroom doesn't need an ABI bump to honor it.
    lenient: bool = false,

    /// Optional collector for `Finding(.warn, ...)` / `(.info, ...)`
    /// notes. Currently no-op until the cleanroom paths land.
    findings_sink: ?*FindingsSink = null,
};

/// Decode a JP2 (file format) or J2K (raw codestream) buffer into
/// a fully-realized `Image`. Default options (`threads = 1`).
pub fn decode(allocator: Allocator, data: []const u8) DecodeError!Image {
    return decodeWithOptions(allocator, data, .{});
}

/// Same as `decode` but accepts a `DecodeOptions`.
pub fn decodeWithOptions(
    allocator: Allocator,
    data: []const u8,
    options: DecodeOptions,
) DecodeError!Image {
    _ = options; // Phase 1: wrapper ignores all options
    // Phase 1: delegate to openjpeg wrapper. Phase 2 will route
    // each cleanroom path (codestream walker / tier-1 / etc.)
    // ahead of the wrapper, surrounded by the same `try X(...)
    // catch error.NotImplemented => {}` pattern jpegz uses.
    last_error.clear();
    return @import("ffi/openjpeg_wrapper.zig").decode(allocator, data) catch |err| {
        last_error.set("jp2z.decode failed: {s}", .{@errorName(err)});
        return err;
    };
}

/// Validate a JP2/J2K bitstream and return a structured report.
/// Phase 2 M1: cleanroom codestream walker — SOC + SIZ today; the
/// rest of the main-header markers land per the M1 punch list.
/// JP2 file format (box walker → embedded codestream) is a separate
/// follow-on; today this only validates raw J2K codestreams.
pub fn validate(
    allocator: Allocator,
    data: []const u8,
) error{OutOfMemory}!ValidationReport {
    return @import("decode/codestream.zig").validate(allocator, data);
}

// ─────────────────────────────────────────────────────────────────────
// Internal namespace — diagnostic-only oracle entry points.
// ─────────────────────────────────────────────────────────────────────

/// Test-only entry points. NOT part of the stable ABI. Mirrors
/// jpegz's `internal.*` namespace pattern so future cleanroom-vs-
/// oracle byte-perfect tests have a clear hook.
pub const internal = struct {
    /// Direct openjpeg decode — bypasses any future cleanroom
    /// dispatcher. Used by tests to validate the cleanroom output
    /// byte-for-byte against the wrapper.
    pub fn openjpegDecode(allocator: Allocator, data: []const u8) DecodeError!Image {
        return @import("ffi/openjpeg_wrapper.zig").decode(allocator, data);
    }

    /// Run the cleanroom walker against `data` and pull out the
    /// `CodingParams` (SIZ + COD config). `null` if the walker
    /// didn't reach far enough — i.e. the codestream is missing
    /// SOC, SIZ, or COD, or stops short before parseCodBody runs.
    pub fn inspect(allocator: Allocator, data: []const u8) error{OutOfMemory}!?CodingParams {
        var report = try validate(allocator, data);
        defer report.deinit(allocator);
        return report.coding_params;
    }

    /// Walk a codestream and extract one `CblkDecodePlan` per
    /// code-block that was included in any packet — a list of
    /// concatenated cblk byte slices + accumulated coding-pass counts
    /// + subband-internal rects, ready to be handed to the M3 tier-1
    /// EBCOT dispatcher (`ebcot.decodeCblkPasses`).
    ///
    /// Caller owns the returned list and must deinit it.
    pub fn extractCblkPlans(allocator: Allocator, data: []const u8) error{OutOfMemory}!CblkDecodePlanList {
        return @import("decode/codestream.zig").extractCblkPlans(allocator, data);
    }

    /// Run EBCOT tier-1 decode on a single `CblkDecodePlan` (from
    /// `extractCblkPlans`). Derives `msb_bp` from `plan.numbps`
    /// (= M_b - zero_bitplanes; both filled in by the walker).
    ///
    /// Returns a heap-owned `decode.ebcot.Cblk` with reconstructed
    /// coefficient state; caller must deinit.
    pub fn decodePlan(
        allocator: Allocator,
        plan: CblkDecodePlan,
    ) error{OutOfMemory}!@import("decode/ebcot.zig").Cblk {
        return @import("decode/cblk_dispatch.zig").decodePlan(allocator, plan);
    }

    /// OpenJPEG-style i32 sign-magnitude encoding for one decoded
    /// coefficient. `half_bit_pos` comes from `halfBitPos(msb_bp, total_passes)`.
    pub fn coeffToOpenJpegI32(coeff: @import("decode/ebcot.zig").Coeff, half_bit_pos: u5) i32 {
        return @import("decode/cblk_dispatch.zig").coeffToOpenJpegI32(coeff, half_bit_pos);
    }

    /// Position of OpenJPEG's "half-bit" reconstruction marker for the
    /// given (msb_bp, total_passes) pair. Used to convert our raw
    /// bit-plane magnitude to OpenJPEG's centred-bin representation.
    pub fn halfBitPos(msb_bp: u5, total_passes: u32) u5 {
        return @import("decode/cblk_dispatch.zig").halfBitPos(msb_bp, total_passes);
    }
};

// ─────────────────────────────────────────────────────────────────────
// Force-link the C ABI module so its `export fn`s land in the static lib.
// ─────────────────────────────────────────────────────────────────────

comptime {
    _ = @import("ffi/c_api.zig");
}

// ─────────────────────────────────────────────────────────────────────
// Force test discovery for modules that don't have a non-test
// declaration referenced from this hub (Zig only pulls inline
// tests from modules that are reached via @import + a referenced
// decl; an unreferenced @import is dead code).
// ─────────────────────────────────────────────────────────────────────

test {
    _ = @import("decode/bit_reader.zig");
    _ = @import("decode/cblk_dispatch.zig");
    _ = @import("decode/cblk_extract.zig");
    _ = @import("decode/cblk_plan.zig");
    _ = @import("decode/codestream.zig");
    _ = @import("decode/ebcot.zig");
    _ = @import("decode/findings.zig");
    _ = @import("decode/mq_coder.zig");
    _ = @import("decode/packet_header.zig");
    _ = @import("decode/subbands.zig");
    _ = @import("decode/tag_tree.zig");
}

// ─────────────────────────────────────────────────────────────────────
// Inline tests
// ─────────────────────────────────────────────────────────────────────

test "version constant" {
    try std.testing.expect(version.len > 0);
}

test "decode rejects garbage input" {
    const garbage = "definitely not a JP2 file at all";
    try std.testing.expectError(
        error.InvalidJp2Codestream,
        decode(std.testing.allocator, garbage),
    );
}

test "validate empty input fails with missing_soi" {
    var report = try validate(std.testing.allocator, "");
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(Severity.fail, report.overall);
    try std.testing.expectEqual(@as(usize, 1), report.findings.items.len);
    try std.testing.expectEqual(FindingCode.missing_soi, report.findings.items[0].code);
}
