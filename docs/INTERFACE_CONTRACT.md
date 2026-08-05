---
purpose: Frozen public interface of jp2z (Zig surface + C ABI + finding-code registry) that consumers pin against; decouples interface stability from decode coverage.
audience: both
status: FROZEN v1 — awaiting Einstein blessing; changes require Einstein cross-board sign-off
maintained_by: einstein-signoff
frozen_as_of: yolo@7a962ed4
---

# jp2z Interface Contract — v1 (FROZEN, pending Einstein blessing)

## Purpose & status

This is the **version-gated public interface** of jp2z. Its consumers —
`jpegz` (re-exports jp2z as its `jpeg2000` namespace), `tiffz` (decodes
JP2-in-TIFF tiles, e.g. Aperio SVS, TIFF compression 33003/33005), and
`validate` (consumes the strict findings) — **pin against this surface**,
not against jp2z's decode completeness.

The point: **decode coverage grows behind a stable interface.** A consumer
can integrate jp2z today against v1 and get more working JP2 profiles over
time with zero interface churn.

**Change protocol.** Any change to the symbols, signatures, struct layouts,
C ABI, status-code values, or the shared finding-code registry below
requires **Einstein cross-board sign-off** (Einstein owns version
consistency, this frozen contract, and the finding-code registry). Routine
jp2z work that does NOT touch this surface (decode internals, fixtures, bug
fixes) proceeds through jp2z-reviewer as normal.

Frozen as of `yolo@7a962ed4`. Interface version **v1**.

## What is frozen vs. what is not

**Frozen — pin against these:**
- The public Zig module surface (functions + types below).
- The C ABI (`jp2z_*`, `include/jp2z_core.h`).
- The finding-code numeric values (wire format).
- The `DecodeError` ↔ `jp2z_status_t` numeric mapping.

**NOT frozen — grows freely *behind* the interface:**
- **Decode coverage / completeness.** Which JP2 profiles actually decode
  (bit depths, tile configs, RGN/ROI, progression orders, multi-tile 9/7,
  …) expands per milestone. `decode` may return `error.NotImplemented`
  (`JP2Z_ERR_NOT_IMPLEMENTED`, -1) for an unsupported input today and
  succeed on it later. That "not-yet" set only shrinks.
- **Whether decode routes through the openjpeg wrapper or the pure-Zig
  path.** Phase 1 = wrapper; Phase 2 = pure-Zig-first + wrapper fallback;
  Phase 3 = pure-Zig only. **The interface is identical across all three** —
  this contract is exactly what lets the runtime backend change invisibly.
- **The `internal.*` namespace** is explicitly NOT part of the stable ABI
  (test/oracle hooks: `decodeCleanroom`, `extractCblkPlans`, `inspect`,
  `openjpegDecode`, …). Consumers MUST NOT depend on it.
- **Finding semantics may strengthen** (a code may begin firing in more
  cases as validation sharpens), but a code's numeric value and meaning are
  stable once registered.

## Zig surface (frozen)

### Decode
```zig
pub fn decode(allocator: Allocator, data: []const u8) DecodeError!Image;
pub fn decodeWithOptions(allocator: Allocator, data: []const u8, options: DecodeOptions) DecodeError!Image;

pub const DecodeOptions = struct {
    threads: u8 = 1,
    lenient: bool = false,             // tolerant decode (Phase-2 semantics; recover + emit findings)
    findings_sink: ?*FindingsSink = null,
};
```

### Validate
```zig
pub fn validate(allocator: Allocator, data: []const u8) error{OutOfMemory}!ValidationReport;
pub fn deepValidate(allocator: Allocator, data: []const u8, strict: bool) error{OutOfMemory}!ValidationReport;
```

`deepValidate` is the production corruption-detection entry point. It adds a
full entropy decode to the structural walk using only jp2z's Zig code. The
public-module import gate executes it without OpenJPEG headers or libraries.
Unsupported-but-valid features stay warnings even when `strict` is true.

### Types
```zig
pub const Image = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    channels: u8,
    bits_per_sample: u8,
    source_color_space: ColorSpace,
    layout: PixelLayout,
    // methods: rowStride() usize, pixelsU16() []align(1) u16, deinit(allocator)
};
pub const PixelLayout = enum(u8) { grayscale, rgb, cmyk };
pub const ColorSpace  = enum(u8) { unknown, grayscale, rgb, ycbcr, cmyk, ycck, srgb, greyscale_jp2 };
pub const Severity    = enum(u8) { pass = 0, info = 1, warn = 2, fail = 3 };
pub const Variant     = enum(u8) { unknown = 0, j2k_codestream = 1, jp2_file = 2, jpx = 3 };

pub const Finding = struct {
    severity: Severity,
    code: FindingCode,
    offset: ?u64 = null,
    detail: ?[]const u8 = null,
};
pub const ValidationReport = struct {
    overall: Severity,
    variant: Variant,
    width: ?u32,
    height: ?u32,
    findings: std.ArrayList(Finding),
    coding_params: ?CodingParams = null,
    // methods: isOk() bool, deinit(allocator)
};

pub const DecodeError = error{
    NotImplemented, InvalidMarker, UnsupportedPrecision, TruncatedStream,
    BackendError, InvalidJp2Codestream, OutOfMemory, CallbackAborted,
};

pub const version: [:0]const u8;        // "0.0.1"
pub fn lastErrorMessage() []const u8;
```

`FindingsSink` and `CodingParams` are also public (the latter via
`ValidationReport.coding_params` for codec-feature introspection), but their
internal layout is **not** part of the frozen surface — treat them as opaque
across the boundary except through their public accessors.

**Vocabulary parity:** `Image`, `PixelLayout`, `ColorSpace`, `Severity`,
`FindingCode`, `Finding`, `ValidationReport` mirror jpegz's types
**structurally**, so the jpegz re-export is a pure-Zig alias with **no
translation layer**.

### jpegz re-export seam (the contract's reason to exist)
```zig
// jpegz/src/jpegz.zig — at jp2z feature-complete:
pub const jpeg2000 = struct {
    const jp2z = @import("jp2z");
    pub const decode = jp2z.decode;
    pub const decodeWithOptions = jp2z.decodeWithOptions;
    pub const validate = jp2z.validate;
    pub const deepValidate = jp2z.deepValidate;
};
```

## C ABI (frozen) — `include/jp2z_core.h`

```c
jp2z_status_t jp2z_decode(const uint8_t *data, size_t len, jp2z_image_t *out_image);
jp2z_status_t jp2z_decode_ex(const uint8_t *data, size_t len,
                             const jp2z_decode_options_t *opts, jp2z_image_t *out_image);
void          jp2z_image_free(jp2z_image_t *image);
const char   *jp2z_last_error_message(void);
const char   *jp2z_version(void);

/* findings sink (validation diagnostics for consumers like validate) */
jp2z_findings_sink_t *jp2z_findings_sink_create(void);
void                  jp2z_findings_sink_free(jp2z_findings_sink_t *sink);
size_t                jp2z_findings_sink_count(const jp2z_findings_sink_t *sink);
/* + jp2z_findings_sink_get(...), jp2z_decode_with_findings(...) */
int                   jp2z_deep_validate(const uint8_t *data, size_t len,
                                         int strict, jp2z_findings_sink_t *sink);
```

- **Structs:** `jp2z_image_t`, `jp2z_decode_options_t`, `jp2z_finding_t`.
- **Enums:** `jp2z_status_t`, `jp2z_color_space_t`, `jp2z_pixel_layout_t`,
  `jp2z_severity_t`.
- The finding `code` field is an `int` carrying the **numeric** FindingCode
  (no per-code C enum mirror) — so registry additions don't change the ABI
  *shape*, only the set of values a consumer may observe.

### Status / error mapping (frozen wire values)

| Zig `DecodeError`     | C `jp2z_status_t`                | value |
|-----------------------|----------------------------------|------:|
| (success)             | `JP2Z_OK`                        |   0   |
| `NotImplemented`      | `JP2Z_ERR_NOT_IMPLEMENTED`       |  -1   |
| `InvalidMarker`       | `JP2Z_ERR_INVALID_MARKER`        |  -2   |
| `UnsupportedPrecision`| `JP2Z_ERR_UNSUPPORTED_PRECISION` |  -3   |
| `TruncatedStream`     | `JP2Z_ERR_TRUNCATED_STREAM`      |  -4   |
| `BackendError`        | `JP2Z_ERR_BACKEND`               |  -6   |
| `InvalidJp2Codestream`| `JP2Z_ERR_INVALID_JP2_CODESTREAM`|  -7   |
| `OutOfMemory`         | `JP2Z_ERR_OUT_OF_MEMORY`         |  -8   |
| `CallbackAborted`     | `JP2Z_ERR_CALLBACK_ABORTED`      |  -9   |

## Shared finding-code registry (Einstein-owned)

These are jp2z's current numeric finding codes (the wire format consumers
read). The **canonical** cross-project registry — reconciled across
`validate` / `jpegz` / `jp2z` — is owned by Einstein. **Do not add or
renumber codes without Einstein sign-off** (numeric ABI + cross-project
semantics).

| Code | Name | Meaning |
|-----:|------|---------|
| 1 | `missing_soi` | missing SOC (J2K) or signature box (JP2) |
| 2 | `missing_eoi` | missing EOC |
| 3 | `truncated_stream` | stream/segment ends short of declared length |
| 4 | `bad_marker_length` | marker segment length field invalid |
| 5 | `unknown_marker` | unrecognized marker in the header |
| 140 | `jp2_invalid_signature` | JP2 signature box invalid |
| 141 | `jp2_invalid_codestream` | embedded codestream invalid |
| 142 | `jp2_bad_progression_order` | progression order out of range |
| 143 | `jp2_tile_decode_failed` | a tile failed to decode |
| 144 | `jp2_codeblock_decode_failed` | a code-block failed to decode |
| 145 | `jp2_unsupported_marker_ignored` | COC/QCC/RGN/POC present but not yet applied → fell back to COD/QCD defaults |
| **146** | **`jp2_invalid_siz`** | **SIZ geometry malformed — zero subsampling, bad Lsiz/Csiz, degenerate tile grid (renumbered 6→146 per Einstein registry: 6 = jpegz `duplicate_sof`)** |
| 207 | `jp2_uses_9x7_wavelet` | info: irreversible 9/7 |
| 208 | `jp2_uses_5x3_wavelet` | info: reversible 5/3 |
| 250 | `jp2_packets_under_read` | walker stopped before tp_body end — possible per-cblk bug |
| 251 | `entropy_over_read` | MQ/RAW synthesized >2 past-end 0xFF — truncated entropy data |
| 252 | `entropy_under_read` | cblk left bytes unconsumed — length/data inconsistency |
| 253 | `coding_pass_overflow` | cblk total_passes exceeds 3·numbps−2 (corrupt header) |
| **254** | **`jp2_packets_walked_to_end`** | **info: walker consumed every tile-part body byte, per tile (renumbered 209→254 per Einstein registry: 209 = jpegz `jfif_metadata_present`)** |

— jp2z (drafted for Einstein blessing; reply to `/Users/pmarreck/Code/jp2z/inbox/`)
