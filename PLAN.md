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
- [x] SOC / SIZ / SOT / SOD / EOC parse (structural)
- [x] Walk all main-header markers (COD/QCD/COC/QCC/RGN/POC/TLM/PLM/PPM/CRG/COM) — length validation, body skip
- [x] Tile-part walk via Psot through to EOC
- [x] JP2 file-format box walker (Annex I) — ihdr → width/height, dispatch jp2c to J2K walker
- [x] `validate(...)` cleanroom (structural integrity, no decode-through)
- [x] Known-good fixtures: 8 vendored ISO 15444-4 + full corpus via openjpeg-data flake input
- [ ] COD/QCD body field-level validation (prog. order, wavelet filter, decomp. levels) — optional refinement
- [ ] Known-bad fixtures (truncations, bad markers, garbage fields) — defensive coverage

### M2 — tier-2 (packet headers)
- [x] Progression order syntax: LRCP / RLCP / RPCL / PCRL / CPRL
      (PacketIterator covers all 5 with per-r variable precinct counts
      and reference-grid iteration for non-indexed orders)
- [x] Packet header decode (inline; PPM / PPT deferred)
- [x] Layer / resolution / component walk
- [x] c1_mono.j2c byte-perfect packet walk
- [x] file1.jp2 byte-perfect packet walk
- [x] file9.jp2 byte-perfect packet walk
- [ ] Per-precinct SubbandState — currently `packet_header.SubbandState`
      is per-(component, resolution, subband) but multi-precinct
      streams need per-(precinct) tag trees + per-precinct cblk
      sub-grids. d1_colr.j2c (PCRL + user-defined precincts) over-reads
      until this lands. walkPackets passes (1, 1) to PacketIterator
      as a degenerate-mode workaround.
- [ ] Findings vocabulary enrichment for corruption-detection consumers
      (primary downstream use case is data integrity, not pixel decode).
      Track every spec deviation; never silently smooth issues. Specifics
      to add (FindingCode numeric values must be NEW and APPEND-ONLY —
      see core/errors.zig):
        - Per-COD-field range findings (split `jp2_invalid_codestream`
          into specific codes for prog order / num_layers / decomp depth
          / cblk dims / cblksty bits / qmfbid)
        - Per-QCD-field range findings (split quant style / guard bits /
          per-subband step sizes)
        - Per-SIZ-field findings (Csiz=0, Xsiz<=XOsiz, Ssiz reserved
          bits set, XRsiz=0 / YRsiz=0, Rsiz reserved)
        - Per-tile-part `Psot` mismatch (declared vs actual SOT-to-next
          distance)
        - Per-packet contribution length mismatch (when fully cleanroom)
        - `jp2_trailing_data_after_eoc` (currently partial — warn only)
        - Per-component descriptor info findings (sign / precision /
          sample period) so consumers can show per-component metadata
        - Once M3-M6 land: cblk-level integrity (segment termination
          marker presence / MQ-coder predictable-termination violations)
- [ ] PPM / PPT marker support (packed packet headers in main /
      tile-part header rather than inline) — separate slice

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

- Phase 1 wrapper backend + decode tests against vendored conformance fixtures
- Phase 1 C CLI binary + end-to-end test with byte-perfect oracle comparison vs opj_decompress
- Phase 2 M1 (core scope): cleanroom codestream walker — J2K marker walk + JP2 box walk + tile-part walk to EOC; `validate()` returns structured findings for missing/malformed/truncated input
