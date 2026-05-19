# jp2z — Code Minimap

A grep-friendly inventory of every important file. Same convention
jpegz uses. Update as the cleanroom milestones land.

## Top level

| Path | Purpose |
|---|---|
| `README.md` | Project overview, status, integration plan |
| `PROJECT_OVERVIEW.md` | Goals, scope (Part 1 only), terminology, conventions |
| `PLAN.md` | Phase-1 punch list + Phase-2 cleanroom milestones |
| `CODE_MINIMAP.md` | This file |
| `NEXT_SESSION.md` | Handoff doc for the LLM picking up next |
| `flake.nix` | Nix build with openjpeg as Phase 1 dependency |
| `build.zig` | Zig build: core module, static lib, C CLI, test step |
| `build.zig.zon` | Project manifest (no Zig deps in Phase 1) |
| `build` | `nix build` wrapper, copies to `zig-out/bin/jp2z` |
| `test` | `nix flake check` wrapper, returns roll-up exit code |
| `build_all` | Cross-compile entry point (TODO: wire cross targets) |

## Public API surface

| Path | Defines | Notes |
|---|---|---|
| `src/jp2z.zig` | `decode`, `decodeWithOptions`, `validate`, `DecodeOptions`, `Image`, `FindingsSink`, `Severity`, `Variant`, `FindingCode`, `internal.openjpegDecode`, `version`, `lastErrorMessage` | Hub. Imports core/* + decode/* + ffi/c_api.zig (force-link) |

## Core (shared, no I/O)

| Path | Defines | Notes |
|---|---|---|
| `src/core/errors.zig` | `DecodeError`, `Severity`, `Variant`, `FindingCode` | Mirrors jpegz's vocabulary so the integration shim is trivial |
| `src/core/types.zig` | `ColorSpace`, `PixelLayout`, `Image`, `ImageMetadata` | Identical shape to jpegz |
| `src/core/last_error.zig` | `clear`, `set`, `current`, `cPtr` | Thread-local per-error preservation (same backing as C ABI) |

## Decode (cleanroom + helpers)

| Path | Defines | Notes |
|---|---|---|
| `src/decode/findings.zig` | `FindingsSink` | Mirrors jpegz; emit-time append; deinit frees owned details |
| `src/decode/codestream.zig` | *(TODO Phase 2 M1)* | Codestream marker walker (SOC/SIZ/COD/QCD/SOD/EOC) |
| `src/decode/tier2.zig` | *(TODO Phase 2 M2)* | Packet header decode, progression orders |
| `src/decode/tier1.zig` | *(TODO Phase 2 M3)* | EBCOT / MQ coder / code-block decode |
| `src/decode/wavelet53.zig` | *(TODO Phase 2 M4)* | Lossless 5/3 inverse DWT |
| `src/decode/wavelet97.zig` | *(TODO Phase 2 M5)* | Lossy 9/7 inverse DWT |
| `src/decode/mct.zig` | *(TODO Phase 2 M6)* | RCT / ICT inverse |

## FFI

| Path | Defines | Notes |
|---|---|---|
| `src/ffi/openjpeg_wrapper.zig` | `decode(allocator, data) → Image` | Phase 1 backend; ported from jpegz. Retires at Phase 2 M6, moves under `internal.*` |
| `src/ffi/c_api.zig` | `jp2z_*` exports — `decode`, `decode_ex`, `decode_with_findings`, `image_free`, `findings_sink_{create,free,count,get}`, `version`, `last_error_message` | Mirrors jpegz's C ABI; exhaustive switch on `DecodeError` is the compile-time guard |

## C header

| Path | Defines | Notes |
|---|---|---|
| `include/jp2z_core.h` | `jp2z_status_t`, `jp2z_image_t`, `jp2z_decode_options_t`, `jp2z_findings_sink_t`, `jp2z_sink_finding_t` + all entry-point declarations | Includes canonical 20-line C usage example for findings sink |

## CLI (dogfoods the FFI)

| Path | Purpose |
|---|---|
| `cli/main.c` | Decode JP2/J2K → PPM/PGM on stdout. Reaches Zig core only via `jp2z_core.h` (intentional — never `@import` from Zig CLI) |

## Tests

| Path | Coverage |
|---|---|
| `tests/unit/smoke.zig` | Public-API wiring: version, last error, decode error paths, FindingsSink basics |
| `tests/unit/decode.zig` | TODO: needs JP2/J2K fixtures + Phase-1 wrapper round-trip |
| `tests/unit/validate.zig` | TODO: stub passes; M1 codestream walker activates real tests |
| `tests/cli/smoke.c` | 10 C-side assertions: version, decode error paths, FindingsSink create/free/count/get |
| `tests/unit/fixtures/` | TODO: tiny 4×4 JP2 + J2K fixtures (use `opj_compress` from openjpeg-tools, or write a generator script à la `jpegz/scratch/gen_jpegls_fixtures.c`) |
