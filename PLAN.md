# jp2z — Plan

## In progress

- [ ] Initial scaffolding (this commit)

## Phase 1 — openjpeg wrapper (working v1)

- [ ] `flake.nix` with openjpeg dependency wired (mirror jpegz's libjpeg-turbo setup)
- [ ] `src/ffi/openjpeg_wrapper.zig` — port from jpegz's existing wrapper
- [ ] `src/jp2z.zig` — public API surface (`decode`, `decodeWithOptions`, `validate`, `FindingsSink`)
- [ ] `src/core/{errors, types, last_error}.zig` — adopt jpegz's vocabulary so future jpegz integration is a re-export shim
- [ ] `src/decode/findings.zig` — `FindingsSink` (mirror jpegz)
- [ ] `src/ffi/c_api.zig` — `jp2z_*` C exports matching jpegz's `jpegz_jp2_*` shape
- [ ] `include/jp2z_core.h` — C header with usage example
- [ ] `cli/main.c` — minimal C CLI that decodes JP2/J2K and emits PPM/PGM
- [ ] `tests/unit/{smoke, decode, validate}.zig` — Zig test suite
- [ ] `tests/cli/smoke.c` — C FFI smoke test
- [ ] `tests/unit/fixtures/` — small JP2/J2K test fixtures
- [ ] CI green on Garnix (auto-detects `flake.nix`)

## Phase 2 — cleanroom milestones

Each milestone retires part of the openjpeg dependency. After M6 the
wrapper moves to `jp2z.internal.openjpegDecode` for byte-perfect
oracle tests.

### M1 — codestream walker + minimal headers
- [ ] SOC / SOT / SIZ / COD / QCD / SOD / EOC marker parse
- [ ] `validate(...)` cleanroom (structural integrity, no decode-through yet)
- [ ] Fixtures: known-good and known-bad codestreams

### M2 — tier-2 (packet headers)
- [ ] Progression order: LRCP / RLCP / RPCL / PCRL / CPRL
- [ ] Packet header decode (PPM / PPT / inline)
- [ ] Layer / resolution / component / precinct walk

### M3 — tier-1 EBCOT
- [ ] MQ arithmetic coder (initial state, context model)
- [ ] Code-block decode: significance / refinement / cleanup passes
- [ ] Context formation per T.800 Annex C

### M4 — inverse 5/3 wavelet (lossless)
- [ ] 1D inverse DWT (lifting steps)
- [ ] 2D inverse via tile/code-block boundary handling
- [ ] Quantization (none for 5/3 lossless)

### M5 — inverse 9/7 wavelet (lossy)
- [ ] 1D inverse DWT with lifting + scale
- [ ] Fixed-point integer arithmetic (no float — project rule)
- [ ] Dequantization per QCD

### M6 — MCT inverse + final polish
- [ ] RCT (Reversible Color Transform — used with 5/3)
- [ ] ICT (Irreversible Color Transform — used with 9/7)
- [ ] Move `openjpeg_wrapper` → `internal.openjpegDecode` for oracle-only use
- [ ] Final cleanup: remove openjpeg from runtime dependency graph

## Phase 3 — jpegz integration

- [ ] In jpegz: replace `pub const jpeg2000` body with thin re-export shim to jp2z
- [ ] In jpegz: delete `src/ffi/openjpeg_wrapper.zig`
- [ ] In jpegz: remove openjpeg from `flake.nix`
- [ ] jpegz becomes "100% cleanroom JPEG family decoder at runtime — no exceptions"

## Completed

- (nothing yet — see commits)
