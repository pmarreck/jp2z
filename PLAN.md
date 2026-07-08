# jp2z — Plan

## In progress

> **WIND-DOWN STATE (fleet migration to Thelio, 2026-07-06).** All work GREEN +
> pushed: `yolo@origin = 2c0e8728`, 224/224 tests, Garnix 6/6, working copy clean
> (no uncommitted/WIP). Sweep baseline **PASS 14, NEAR 1, FAIL 20, skip 21, ERROR 1,
> CRASH 0**. This session shipped, in order: the conformance-sweep harness; the
> multi-tile 5/3 fix (origin-aware geometry + absolute cblk anchoring → a3+f1
> byte-exact, PASS 12→14); MIT license (Einstein-blessed); the reviewer-caught
> precinct-0 crash fix; and the README port-wording reconciliation. Cross-board loop
> fully settled (jp2z-reviewer ✅ audited the geometry clean, Einstein ✅ signed the
> license, replies sent + notes archived to `inbox/processed/`).
>
> **RESUME HERE (ranked next steps, all independent of the now-correct tiling):**
> 1. **SOP/EPH packet markers** (`csty=0x6`) — highest leverage, unblocks a5 +
>    several `g*`. Add SOP/EPH skipping in the packet walker (`codestream.zig`).
> 2. **Tier-1 VSC/RESET/SEGSYM coding styles** (`cblksty=0x2f`) — unblocks c2_mono
>    (single-tile, so pure tier-1). Peter had asked for this ("C") before wind-down.
> 3. **b1_mono** — non-zero IMAGE origin (XOsiz=3097)+tile-grid origin; improved
>    223→195 but still off. Needs image-origin handling in the tile geometry.
> 4. **Sweep `.pix`-oracle upgrade** (reviewer minor) — reclassifies p0_10 DECODED→PASS.
> 5. **>8-bit depth (p1_04, the tiffz gap)** + **p0_13 NoCodingParams** — lower priority.
> Method for all: TDD, differential-vs-openjpeg on valid files (the reviewer bar);
> run `./sweep` after each to confirm no PASS→FAIL drift.
- [x] **Conformance-sweep harness** (2026-06-30). `tools/sweep_one.zig` decodes
      one fixture per process with `internal.decodeCleanroom` and grades it vs
      the in-process openjpeg oracle; `./sweep` runs all 57 ISO 15444-4 fixtures
      and writes `conformance/sweep.ndjson` + `conformance/SCORECARD.md`. Result
      is deterministic (integer decoder + fixed oracle) so the committed
      artifacts are a regression net — `jj diff` after re-running surfaces drift.
      Baseline: **PASS 12, NEAR 1, FAIL 22, skip 21, ERROR 1, CRASH 0**.
- [x] **Multi-tile 5/3 origin-aware geometry + absolute cblk anchoring** (2026-06-30).
      Root-caused the FAIL cluster: geometry assumed tile origin (0,0). Two fixes, both
      matching openjpeg: (1) the whole subband/resolution geometry threads the
      tile-component origin — inverse-DWT parity `cas = res.x0 % 2` + the per-level
      `sn/dn` split (`subbands`/`dwt`/`reconstruct`/`codestream`.zig); (2) the code-block
      partition now anchors to ABSOLUTE band coords (`precinctCblkGeom`), so an interior
      tile whose band crosses a cblk boundary gets the correct cblk COUNT — the
      off-by-one that desynced packet parsing. **a3 + f1 now byte-EXACT** vs openjpeg
      (sweep PASS 12→14); f1 is the committed TDD test; 223 tests, no regressions.
      The other "cluster" fixtures each STACK another unimplemented feature (the M6 KEY
      LESSON), so they still FAIL on THAT, not tiling:
        - `a5`, some `g*`: SOP/EPH packet markers (`csty=0x6`).
        - `c2` (single-tile): VSC/RESET/SEGSYM coding styles (`cblksty=0x2f`).
        - `b1`: non-zero IMAGE origin (XOsiz=3097)+tile-grid origin — improved 223→195
          but still off; image-origin handling in tile geometry needs a look.
- [ ] **Next: unblock a stacked feature** — SOP/EPH markers (a5 + others) or tier-1
      VSC/RESET/SEGSYM (c2). Both independent of the now-correct tiling. TDD vs openjpeg.
- [x] **Reviewer catch — reject user-precinct PPx/PPy=0 at r>0** (2026-06-30, commit
      ba313895). jp2z-reviewer's audit of the multi-tile commit found a reachable crash
      on the shipped validate() path (u6 underflow in TileWalk.init). `parseCodBody` now
      flags `.jp2_invalid_codestream` + un-publishes coding_params; `precinctCblkGeom`
      guards pdx/pdy==0. TDD classifier fixture; 224 tests; existing code 141 (no registry
      change).
- [ ] **Sweep upgrade — prefer committed `.pix` planar oracle** (reviewer minor). The
      sweep's in-process wrapper oracle upsamples+interleaves, so sub-sampled byte-exact
      fixtures (p0_10) report DECODED not PASS → PASS is a conservative undercount. When a
      fixture has `tests/unit/fixtures/oracles/<name>.pix`, have `sweep_one` diff THAT
      (planar, component-res) instead. Reclassifies p0_10 as a true PASS.
- [ ] **>8-bit depth — p1_04** (max_abs 3782, the tiffz/pathology gap) and
      **p0_13** ERROR=NoCodingParams (header-parse gap) — both lower priority
      than the tile cluster but tracked.

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

## Phase 2 — pure-Zig decode milestones

Each milestone retires part of the openjpeg dependency. After M6 the
wrapper moves to `jp2z.internal.openjpegDecode` for byte-perfect
oracle tests.

### M1 — codestream walker + minimal headers
- [x] SOC / SIZ / SOT / SOD / EOC parse (structural)
- [x] Walk all main-header markers (COD/QCD/COC/QCC/RGN/POC/TLM/PLM/PPM/CRG/COM) — length validation, body skip
- [x] Tile-part walk via Psot through to EOC
- [x] JP2 file-format box walker (Annex I) — ihdr → width/height, dispatch jp2c to J2K walker
- [x] `validate(...)` pure-Zig (structural integrity, no decode-through)
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
        - Per-packet contribution length mismatch (when pure-Zig decode is complete)
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
- [x] Multi-tile decode (5/3 path) — **p0_10.j2k BYTE-PERFECT** (2026-06-28).
      DONE: SIZ comp_dx/comp_dy capture; per-tile/per-component walk geometry;
      TNsot>1 persistent per-tile packet iterator (TileWalk: iterator + tag-tree
      states keyed by Isot, resumed across tile-parts; completion by packet
      count, order-independent); cblk tile-tagging (real Isot in CblkKey.tile);
      sub-sampled reconstruction — decodeCleanroom loops tiles, reconstructs each
      tile-component at COMPONENT res, per-tile inverse-MCT + level-shift, then
      composites into the sub-sampled component planes (output at component dims,
      64×64×3 for p0_10). Single/non-sub-sampled tiles reduce to the old path
      (c1/a1/d1_colr stay byte-perfect). Oracle p0_10.pix regenerated PLANAR to
      match the fleet .pix convention.
      REMAINING multi-tile pieces (next fixtures):
        - cas≠0 inverse DWT for ODD tile origins. p0_10 has even origins (cas=0).
          idwt53Line HAS cas1; idwt97Line is cas0-only → add cas1 for 9/7
          multi-tile (p1_xx). Thread the tile resolution origin so cas=origin%2.
        - Marker semantics (RGN/COC/QCC/POC APPLY, not just flag) + tile-part-
          header marker scan. Needed for p0_03/p0_15 (RGN max-shift). NOTE those
          fixtures ALSO stack SOP/EPH + 4-bit-signed → multi-feature sequence.
        - SOP/EPH packet-marker skipping in the walker (no clean fixture uses it
          yet that we pass; p0_10 has csty=0).
      KEY LESSON (still true): every conformance multi-tile fixture stacks ≥2
      unimplemented features (subsampling / TNsot>1 / SOP+EPH / RGN / 9/7 /
      SEGSYM+VSC), so multi-tile is a multi-fixture sequence — land supporting
      features one at a time. p0_10 (subsampling + TNsot>1) is now fully landed.
- [ ] Move `openjpeg_wrapper` -> `internal.openjpegDecode` for oracle-only use.
- [ ] Final cleanup: remove openjpeg from runtime dependency graph (jpegz cutover).

### M7 — strict validation findings (THE `validate` differentiator)
Goal: report MORE error types and tolerate LESS than libopenjpeg/grok.
Typical libs decode permissively (silently paper over corruption); jp2z's
value in `validate` is to FLAG every spec deviation as a finding. The decode
(M3-M6) gives byte-exact correctness; this layer turns the decoder into a
strict validator. Thread a FindingsSink through tier-2 + tier-1 + dequant +
DWT and emit on:
- [x] MQ/RAW over-read: decoders count past-end 0xFF synthesis
      (end_of_stream_count); cblk.over_read aggregates per cblk;
      `deepValidate` (jp2z.internal.deepValidate) decodes every cblk and
      emits `entropy_over_read` when >2. Tested: clean files flag none;
      all-zero (degenerate) cblks flag 34/34. openjpeg only checks this
      under PTERM; jp2z checks always.
- [x] Byte-budget mismatch: under-read (declared-but-unconsumed bytes,
      cblk.under_read) complements over-read. `deepValidate` emits
      `entropy_under_read`. Together they catch ~97%% of single-byte
      (boltgun) and a strong majority of multi-position entropy
      corruptions that openjpeg silently accepts; clean files: 0 leftover.
- [ ] Coding-pass budget exceeded (> 3*numbps-2); coefficient magnitude bit
      above numbps (impossible value).
- [ ] Tag-tree monotonicity violations; inclusion/zero-bitplane anomalies.
- [ ] Marker field validation (reserved bits, out-of-range Scod/Sqcd/SIZ,
      impossible param combinations) beyond what's parsed today.
- [ ] SOT/Psot tile-part length + ordering consistency; EOC presence;
      trailing-garbage; PTERM predictable-termination check (always-on).
- [x] A `strict` mode: any deviation escalates to FAIL (vs lenient: warn).
- [x] FFI: jp2z_deep_validate(data,len,strict,sink) exposes it to `validate`.
- [ ] (Future M7 polish) tag-tree monotonicity + deeper marker-field validation.
Note: strictness comes from DETERMINISTIC integrity checks (independent of
the 9/7 float tolerance), so it is exact even on the lossy path.

## Phase 3 — jpegz integration

- [ ] In jpegz: replace `pub const jpeg2000` body with thin re-export shim to jp2z
- [ ] In jpegz: delete `src/ffi/openjpeg_wrapper.zig`
- [ ] In jpegz: remove openjpeg from `flake.nix`
- [ ] jpegz becomes "JPEG-family decoder with no third-party decoder at runtime — pure Zig, no exceptions"

## Completed
- Multi-tile decode (5/3): p0_10.j2k BYTE-PERFECT — TNsot>1 persistent
  per-tile packet iterator + sub-sampled per-tile reconstruction/compositing
  (2026-06-28 ~8:30pm EDT). 217 tests green.
- Reviewer C1 (CRITICAL): appendFinding `detail` OOM-leak fixed + FailingAllocator
  bite-proven test; stale Scod doc comment fixed (2026-06-28 ~8:33pm EDT).
- Housekeeping: deleted stale NEXT_SESSION.md; gitignored per-subdir .dirtree-state
  (kept root annotations) (2026-06-28 ~8:00pm EDT).

- Phase 1 wrapper backend + decode tests against vendored conformance fixtures
- Phase 1 C CLI binary + end-to-end test with byte-perfect oracle comparison vs opj_decompress
- Phase 2 M1 (core scope): pure-Zig codestream walker — J2K marker walk + JP2 box walk + tile-part walk to EOC; `validate()` returns structured findings for missing/malformed/truncated input
- Phase 2 M2 (tier-2 packet headers): walker BYTE-PERFECT against opj_t2 on every vendored ISO 15444-4 conformance fixture (c1_mono, d1_colr, file1, file9). All 5 progression orders + per-resolution variable precinct counts + reference-grid iteration for PCRL/CPRL + per-precinct SubbandState + T.800 A.6.1 cblk-cap-by-precinct.
- Phase 2 M3 (tier-1 EBCOT core): MQ arithmetic decoder (T.800 Annex C) + EBCOT context model (19 contexts, ZC/SC/MR formation per T.800 Table D-1/D-3/D.3.3) + three coding passes (SP/MR/CL with RLC sub-path) + bit-plane orchestrator (decodeCblk). 97 inline tests passing. Pending: walker integration to feed real cblk byte slices, then OpenJPEG oracle byte-perfect verification.
