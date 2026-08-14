//! Public error vocabulary for jp2z. Single source of truth.
//!
//! Mirrors `jpegz/src/core/errors.zig` shape so jpegz can re-export
//! jp2z entry points as `jpegz.jpeg2000.*` via a thin shim once
//! cleanroom JP2 (M6) ships.
//!
//! Numeric values (in the `enum(u32)` declarations) are STABLE
//! FOREVER — new entries APPEND, never reorder, never reuse a freed
//! value. The C header `include/jp2z_core.h` mirrors these.

/// API-level error set returned by `decode`, `decodeWithOptions`,
/// and the C ABI mapper. C side gets the negative-coded mirror in
/// `jp2z_status_t`.
pub const DecodeError = error{
    NotImplemented,          // C: -1   (Phase 2 milestones not yet landed)
    InvalidMarker,           // C: -2
    UnsupportedPrecision,    // C: -3
    TruncatedStream,         // C: -4
    BackendError,            // C: -6   (openjpeg or future cleanroom failure)
    InvalidJp2Codestream,    // C: -7   (codestream/SIZ/COD/QCD parse failure)
    OutOfMemory,             // C: -8
    CallbackAborted,         // C: -9
};

/// Severity tier for `Finding`s in a `ValidationReport`. Mirrors
/// jpegz's vocabulary exactly so a unified report shape works across
/// both libraries.
pub const Severity = enum(u8) {
    pass = 0,
    info = 1,
    warn = 2,
    fail = 3,
};

/// JPEG 2000 storage variant detected during validation.
pub const Variant = enum(u8) {
    unknown        = 0,
    /// Raw codestream — starts with SOC (0xFF 0x4F).
    j2k_codestream = 1,
    /// JP2 file format — starts with the JP2 signature box.
    jp2_file       = 2,
    /// JPX extensions (Part 2). jp2z v1 does NOT decode these;
    /// flagged for visibility only.
    jpx            = 3,
};

/// Symbolic codes for a `Finding` in a `ValidationReport`. Numeric
/// `enum(u32)` value is the C ABI wire format. Mirrors jpegz's
/// `FindingCode` numbering pattern so consumer code can be uniform.
pub const FindingCode = enum(u32) {
    // ── Structural (1..49) ───────────────────────────────────────
    missing_soi              = 1,  // missing SOC in J2K or signature box in JP2
    missing_eoi              = 2,  // missing EOC
    truncated_stream         = 3,
    bad_marker_length        = 4,
    unknown_marker           = 5,

    // ── JPEG 2000 specifics (140..179) — match jpegz numbering ──
    jp2_invalid_signature        = 140,
    jp2_invalid_codestream       = 141,
    jp2_bad_progression_order    = 142,
    jp2_tile_decode_failed       = 143,
    jp2_codeblock_decode_failed  = 144,
    /// A per-component/ROI/progression override marker (COC/QCC/RGN/POC)
    /// was present but jp2z does not yet apply it — decode fell back to
    /// COD/QCD defaults. Surfaced so consumers aren't silently misled
    /// (validate's "stricter than openjpeg" contract). See reviewer I1.
    /// Also emitted for a JP2 box legally ignored per spec: a second+
    /// jp2c codestream box (readers use the first — T.800 I.5.4).
    jp2_unsupported_marker_ignored = 145,
    /// SIZ geometry malformed — zero subsampling (XRsiz/YRsiz=0), bad
    /// Lsiz/Csiz, or degenerate tile grid. Renumbered 6→146 per Einstein
    /// registry reconciliation (6 collided with jpegz duplicate_sof).
    jp2_invalid_siz                = 146,

    // ── Informational (200..249) — match jpegz numbering ─────────
    jp2_uses_9x7_wavelet     = 207,
    jp2_uses_5x3_wavelet     = 208,

    // ── Tier-2 / packet integrity (250..299) ─────────────────────
    jp2_packets_under_read   = 250,  // walker stopped before tp_body.len — possible per-cblk decode bug
    entropy_over_read        = 251,  // MQ/RAW decoder synthesized >2 past-end 0xFF — truncated entropy data
    entropy_under_read       = 252,  // cblk had leftover unconsumed bytes — length/data inconsistency
    coding_pass_overflow     = 253,  // cblk total_passes exceeds 3*numbps-2 (impossible — corrupt header)
    jp2_packets_walked_to_end = 254,  // walker consumed every tile-part body byte (renumbered 209→254 per Einstein: 209 collided with jpegz jfif_metadata_present)
};
