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
- [x] **d1_colr.j2c byte-perfect packet walk (PCRL + user-defined precincts)**
- [x] Per-precinct SubbandState (4D: component × resolution × subband × precinct)
- [x] cblksInPrecinctSubband matches OpenJPEG opj_tcd_init_tile (subband-internal
      coords + overlap-based cblk count + T.800 A.6.1 cblk-cap-by-precinct)
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
- [x] MQ arithmetic coder (T.800 Annex C) — 47-entry state table,
      INITDEC/DECODE/BYTEIN/RENORMD, full MPS/LPS exchange branches
- [x] EBCOT context model — 19 contexts; T.800 Table D-7 init:
      ZC ctx0=state 4, RLC ctx17=state 3 (ADAPTS, not pinned),
      UNIFORM ctx18=state 46 (pinned). Verified vs OpenJPEG.
- [x] Cblk coefficient state + ZC context formation (T.800 Table D-1)
      including HL ↔ V swap and HH-orientation diagonal table
- [x] SC context formation + sign prediction (T.800 Table D-3,
      symmetric-pair canonicalisation)
- [x] MR context formation (T.800 D.3.3) — CX 14/15 first refinement,
      CX 16 thereafter
- [x] SP (significance propagation) pass — T.800 D.3.1
- [x] MR (magnitude refinement) pass — T.800 D.3.2
- [x] CL (cleanup) pass with RLC sub-path — T.800 D.3.3 / D.3.4
- [x] Bit-plane orchestration (decodeCblk) — first bp CL-only,
      subsequent SP→MR→CL, .visited reset between bp, underflow-safe
- [x] Pass-level decodeCblkPasses for arbitrary pass counts (9a)
- [x] CodeBlockState.total_passes + last_contribution_length (9b)
- [x] CblkDecodePlan / CblkDecodePlanList types (9c)
- [x] subbands.cblkSubbandRect per-cblk geometry (9c+)
- [x] extractCblkPlans — walker accumulates per-cblk byte slices
      into plans; produces 34 cblks for c1_mono.j2c, histogram
      matches OpenJPEG dump 1:1 (9d)
- [x] decodePlan tier-1 dispatcher — runs decodeCblkPasses per
      plan; end-to-end through c1_mono.j2c yields 34 decoded
      cblks with sig coeffs (9e)
- [x] QCD parsing: per-band M_b = G_b + ε_b − 1 (style 0
      reversible + style 2 expounded) populated on CodingParams,
      `mbForSubband(r, band)` helper (10.1)
- [x] Coefficient → OpenJPEG i32 converter (`coeffToOpenJpegI32` +
      `halfBitPos` for partial-decode bit-plane truncation) — proven
      against hand-derived OpenJPEG values in unit tests (10.2)
- [x] Walker plumbs M_b through CblkExtractor → plan.numbps;
      dispatcher derives `msb_bp = numbps` (= OpenJPEG bpno_plus_one); verified end-to-end
      against the patched-openjpeg dump: jp2z's per-cblk numbps
      matches OpenJPEG 1:1 on c1_mono.j2c (10.3 — wiring)
- [x] Byte-perfect cblk coefficient comparison — **a1_mono.j2c**
      (cblksty=0 pure-MQ, numlayers=1, single precinct): ALL 34 cblks
      decode byte-identical to OpenJPEG (`tests/unit/validate.zig`).
      This validates the full tier-1 MQ + EBCOT path. Achieved by
      fixing 4 bugs found via a byte-perfect MQ differential trace vs
      patched OpenJPEG:
        1. MQ `mpsExchange` used `qe>0x8000` instead of `A<Qe` (T.800
           Fig C-17) — branches were effectively inverted.
        2. dispatcher `msb_bp` off-by-one: `numbps-1` should be `numbps`
           (OpenJPEG `bpno_plus_one = roishift + numbps`).
        3. `initContexts` wrong: RLC pinned at 46 (must be state 3,
           adapts) and ZC ctx0 left at 0 (must be state 4) — T.800 D-7.
        4. HH-orientation ZC table (`zcContext`) completely wrong vs
           T.800 Table D-1 HH column / OpenJPEG t1_init_ctxno_zc.
- [x] **BYPASS / LAZY mode (cblksty & 0x1) — c1_mono.j2c byte-perfect.**
      c1_mono (cblksty=0x1, 10 layers) now decodes byte-identical to
      OpenJPEG across all 34 cblks. Implemented as: tier-2 captures the
      per-segment {passes, byte_len} breakdown (LAZY allotments 10,2,1,2,1
      via maxPassesForSegment) into `CblkDecodePlan.segments`; a `RawDecoder`
      (MSB-first bits, 0xFF bit-stuffing); raw SP/MR pass variants
      (`spPassRaw`/`mrPassRaw`, no context/XOR); and `decodeCblkSegments`
      which iterates segments, re-inits the MQ registers per MQ segment
      (contexts persist; cleanup is always MQ) and switches to RAW for the
      bypassed SP/MR passes. **M3 tier-1 EBCOT is now byte-perfect on
      a1_mono (pure MQ), d1_colr (3-comp MCT + multi-precinct) and c1_mono
      (BYPASS).**
- [x] Multi-precinct + multi-component byte-perfect: d1_colr.j2c
      (cblksty=0, 3 components + MCT, user 64x64 precincts, 4 layers)
      decodes byte-identical to OpenJPEG across all 174 cblks. The
      4 a1_mono fixes generalised directly; the walker already
      produces correct per-precinct/per-component byte slices.

### M4 — inverse 5/3 wavelet (lossless) — DONE
- [x] 1D inverse 5/3 lifting (dwt.zig idwt53Line) — round-trip tested
- [x] 2D inverse DWT per-resolution (rows then cols, coarse->fine,
      Mallat quadrant layout, edge-clamp boundary) — dwt.zig idwt53
- [x] Coefficient assembly: cblk -> tile buffer by subband quadrant,
      reversible /2 pre-scale (truncating div), reconstruct.zig
- [x] DC level shift + clamp (reconstruct.zig levelShift)
- [x] **End-to-end byte-perfect vs opj_decompress**: a1_mono and
      c1_mono (incl. BYPASS) reconstructed pixels match the .pgm
      output exactly (decodeCleanroom). Quantization: none for 5/3.

### M5 — inverse 9/7 wavelet (lossy) — DONE
- [x] 1D inverse 9/7 lifting + scaling, FIXED-POINT Q16 (dwt.zig idwt97Line):
      even*K, odd*two_invK, then -delta/-gamma/-beta/-alpha lifts, edge-clamp.
- [x] Fixed-point integer arithmetic only (no f32/f64 on the hot path).
- [x] Dequantization per QCD: 0.5*stepsize, stepsize=(1+mant/2048)*2^(prec-expn),
      expn/mant captured for expounded (style 2) + scalar-derived (style 1).
- [x] **p0_09 (9/7 mono) BYTE-PERFECT vs opj_decompress** (max_abs=0).
      NOTE: openjpeg uses float 9/7; our fixed-point converges to the ideal,
      so non-trivial lossy images match within PAE<=1 (the JPEG2000 lossy
      conformance standard), not necessarily bit-exact. See p0_04 below.

### M6 — MCT inverse + final polish
- [x] RCT (reversible colour transform, 5/3) — d1_colr 3-comp BYTE-PERFECT.
- [x] ICT (irreversible colour transform, 9/7) — unit-tested; p0_04 end-to-end
      (9/7 + ICT + TERMALL + user precincts + 20 layers) PAE<=1 vs opj_decompress.
- [ ] Multi-tile decode (walker hardcodes tile 0; e1_colr / p1_xx are multi-tile).
      THE remaining decoder capability. Single-tile feature set is complete.
- [ ] Move `openjpeg_wrapper` -> `internal.openjpegDecode` for oracle-only use.
- [ ] Final cleanup: remove openjpeg from runtime dependency graph (jpegz cutover).

## Phase 3 — jpegz integration

- [ ] In jpegz: replace `pub const jpeg2000` body with thin re-export shim to jp2z
- [ ] In jpegz: delete `src/ffi/openjpeg_wrapper.zig`
- [ ] In jpegz: remove openjpeg from `flake.nix`
- [ ] jpegz becomes "100% cleanroom JPEG family decoder at runtime — no exceptions"

## Completed

- Phase 1 wrapper backend + decode tests against vendored conformance fixtures
- Phase 1 C CLI binary + end-to-end test with byte-perfect oracle comparison vs opj_decompress
- Phase 2 M1 (core scope): cleanroom codestream walker — J2K marker walk + JP2 box walk + tile-part walk to EOC; `validate()` returns structured findings for missing/malformed/truncated input
- Phase 2 M2 (tier-2 packet headers): walker BYTE-PERFECT against opj_t2 on every vendored ISO 15444-4 conformance fixture (c1_mono, d1_colr, file1, file9). All 5 progression orders + per-resolution variable precinct counts + reference-grid iteration for PCRL/CPRL + per-precinct SubbandState + T.800 A.6.1 cblk-cap-by-precinct.
- Phase 2 M3 (tier-1 EBCOT core): MQ arithmetic decoder (T.800 Annex C) + EBCOT context model (19 contexts, ZC/SC/MR formation per T.800 Table D-1/D-3/D.3.3) + three coding passes (SP/MR/CL with RLC sub-path) + bit-plane orchestrator (decodeCblk). 97 inline tests passing. Pending: walker integration to feed real cblk byte slices, then OpenJPEG oracle byte-perfect verification.
