# jp2z — Plan

## In progress

### entropy_under_read false positive on real lossy JP2 (2026-08-13 EDT)

Reported by jpegz 2026-08-12 (inbox), fixture offered by validate 2026-08-13.
Sole blocker on validate's JP2 cutover (jp2z → jpegz → tiffz → validate).

- [x] Reproduce: confirmed byte-for-byte (FAIL 252, 26 cblks, first: tile 3
      comp 0 r0 band 0 prc 0). Probe evidence: offenders' plan buffers held
      MORE bytes than their declared segments (995B vs 881B) with under-reads
      of 75–698 bytes — not MQ-flush slop. (2026-08-13 ~4:20pm EDT)
- [x] Root-cause: NEITHER of jpegz's two candidates. `readPacketHeader`'s
      EMPTY-PACKET early return (leading flag bit 0, T.800 B.10.3) skipped
      the per-cblk `last_contribution_length` reset that only lives inside
      `readCodeBlockContribution`. After any empty packet — ubiquitous in
      8-layer RPCL streams — the extraction loop sliced phantom bytes for
      every previously-contributing cblk in the precinct, polluting plan
      buffers (and decoded coefficients) while the packet walk itself stayed
      in sync (`advance` uses the header's true length, so all 12 tiles
      still reported walked_to_end). Fix: clear the field for all cblks in
      the view on the empty-packet path. RED witnessed (expected 0, found
      2), then GREEN. Post-fix balloon: max under_read across 4336 cblks is
      1 byte; strict verdict INFO/ACCEPT. The `> 2` FAIL threshold was
      never the problem and is unchanged. (2026-08-13 ~4:25pm EDT)
- [x] Vendor the fixture: `tests/unit/fixtures/conformance/
      balloon_eciRGB_icc.jp2` (+ SOURCES.md provenance), 15th mutation-
      matrix control (jp2 family 2→3, floors raised to 3/3/3 — balloon
      detects all six mutation probes). Gate proven to BITE: matrix fails
      with the fix stashed. `./test` green; sweep drift zero. (2026-08-13
      ~4:35pm EDT)
- [x] Shipped `1b29e0c`; push verified (origin/yolo == HEAD); Mechatron
      SUCCESS 2026-08-13T20:37:10Z. SHA-chain notes delivered to jpegz
      (re-pin + propagate to tiffz) and validate (FYI, re-pin when the
      chain reaches them); both sessions notified; source notes archived
      to inbox/processed/. (2026-08-13 ~4:40pm EDT)
- [ ] Decode-correctness follow-up (NOT a validation blocker): balloon's
      differential grade vs openjpeg is FAIL max_abs=9 even post-fix — the
      cleanroom decode has a residual gap on this feature combo (custom
      precincts / 8 layers / SEGSYM / RPCL). Distinct from the sweep's
      existing 12 FAILs only in that balloon isn't in the sweep corpus.

### Carried threads (do not drop)

- [x] Sent jpegz the UBSan diagnosis note (vendored-openjpeg Debug/
      ReleaseSafe builds trap upstream fn-pointer-cast UB at
      openjpeg.c:225/:336; system-lib nix path uninstrumented). Delivered
      2026-08-13 to `jpegz/inbox/`. (2026-08-13 ~4:37pm EDT)
- [x] Archived the executed Einstein leaf-gate note (2026-08-04) to
      `inbox/processed/` (later Trashed wholesale per the 2026-08-14
      ephemeral-inbox rule change). Work had shipped as `0db0c51` +
      `d3754cf`. (2026-08-13 ~4:16pm EDT)
- [x] jp2z-reviewer orphan Trashed — verified already absent from
      `~/Code/` (2026-08-14 ~2:50pm EDT).

### M7 strictness surface — remaining gaps (2026-08-14 EDT) — DONE

Einstein's original 1.0-audit "embedded-stream bounds" item plus the
three follow-ups I'd parked. All four TDD-first (RED witnessed where
new behavior), `./test` green, sweep drift zero, pushed.

- [x] JP2 box-layer strictness (`7e3e0a2`): host-relative finding
      offsets for embedded codestreams (was jp2c-payload-relative — two
      coordinate systems in one report); first-jp2c-only per I.5.4;
      jp2h-before-jp2c ordering per I.5.3; jp2h sub-box bad-length +
      XLBox handling; ihdr/SIZ dimension cross-check (I.5.3.1).
- [x] Null-offset audit (`e214a95`): the only three null-offset emit
      sites (walkJp2 missing-box findings) now anchor at data.len; an
      invariant test rejects ANY null-offset finding on one-box-missing
      JP2s, keeping the class closed.
- [x] TLM/PLT length cross-checks (`738b3d7`): declared-vs-walked for
      both markers, FAIL on disagreement; varint/entry-width hardening
      (hostile >u32 length is bad_marker_length, not a shift-overflow).
- [x] Tag-tree invariants + zero_bitplane_overflow finding 255
      (`f9bc51b`): re-attributed the numbps==0 anomaly out of 253
      (empirically 0/7730 valid cblks); two MFIC monotonicity locks on
      tag_tree.read().

- [ ] Awaiting Peter: nothing pending on jp2z. Next natural blocks are
      decode-correctness (balloon max_abs=9, sweep's 12 FAIL) and the
      leaf-gate leftovers below (retire OpenJPEG from the decode
      artifacts; spec-grounded entropy-corruption labels).

### Mecha Validate v1 leaf gate (2026-08-04 EDT)

- [x] Promote the pure-Zig strict validator from an internal-only hook to the
      public `jp2z.deepValidate` API. Witnessed the consumer probe fail before
      implementation, then execute a valid entropy decode with no C/OpenJPEG
      dependency.
- [x] Add a deterministic set classifier over 14 conforming controls and
      sniper/bolter/shotgun mutations. Current evidence: 0/14 false-positive
      rejects; 0/42 misses for provably invalid SOC mutations; entropy-probe
      sensitivity 10/14, 11/14, and 14/14 respectively. See
      `conformance/MUTATION_SCORECARD.md` for the honest labeling boundary.
- [x] Run the exact Mechatron targets via `./test` (238 existing tests plus
      the mutation classifier), `./build`, the OpenJPEG-free import probe,
      and the 57-file differential sweep. Results: all build/test gates pass;
      sweep PASS 22, NEAR 2, FAIL 12, skip 20, ERROR 1, CRASH/TIMEOUT 0.
- [ ] Remove OpenJPEG from the standalone decode package and C decode path.
      The production strict-validation Zig module is clean, but the Phase-1
      decoder and bundled CLI still use OpenJPEG. Consumers must not select
      those artifacts when validating until the pure-Zig decoder cutover.
- [ ] Add specification-grounded labels for entropy mutations so undetected
      probes can be counted as true false negatives rather than merely lower
      mutation sensitivity.

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
> **DONE since this note:** SOP/EPH markers (`29eb483`), Tier-1 VSC/RESET/SEGSYM
> (`33c8c22`), and **b1_mono + b3_mono image-origin geometry** (2026-07-19 — the tier-2
> narrow-tile packet-iterator desync; see the checked box below). Sweep now PASS 21.
> **RESUME HERE (ranked next steps):**
> 1. **>8-bit depth (p1_04, the tiffz/16-bit gap)** + 9/7 multi-tile `p1_*` (needs cas/origin
>    for the 9/7 path like the 5/3 path has) + `p0_13` NoCodingParams header-parse gap.
> 5. **>8-bit depth (p1_04, the tiffz gap)** + **p0_13 NoCodingParams** — lower priority.
> Method for all: TDD, differential-vs-openjpeg on valid files (the reviewer bar);
> run `./sweep` after each to confirm no PASS→FAIL drift.

### 1.0 strict-validation audit — confusion matrix + gaps (2026-07-24)

Ran jp2z's OWN validator (`jp2z_deep_validate`, strict=1, via the C FFI) over a
labeled corpus (Einstein's library-first 1.0 program). **Blocker inverts: jp2z is
not too lenient — it's not yet trustworthy on VALID data.** Matrix: valid ISO
conformance **10/14 ACCEPT (4 false-positive REJECT)**; corrupt mutants **5/6
REJECT (1 false-negative)**; non-JPEG2000 3/3 REJECT. The deep byte-budget/
over-read checks (c251/c252) are the genuine stricter-than-OpenJPEG differentiator
(caught a deep entropy bit-flip). Ranked pre-1.0 gaps:

- [x] **Escalate missing-EOC to FAIL in strict mode** (2026-07-24). `deepValidate`
      now escalates the structural `missing_eoi` (code 2) finding to strict
      severity: strict → FAIL/REJECT, relaxed → WARN (body still decodable; T.800
      A.4.4 makes EOC mandatory but not unconditionally fatal for a decoder). TDD
      via the public C FFI `jp2z_deep_validate` (a1_mono valid control + EOC-removed
      mutant, proved RED first). Closes the confusion-matrix false-negative.
- [x] **unsupported-valid must NEVER become a strict FAIL** (2026-07-24). Release
      invariant locked in `tests/cli/smoke.c`: p0_04 (genuinely carries COC+POC →
      two c145 findings) proves each c145 is severity WARN and the file still
      ACCEPTs under strict. Existing behavior already satisfied it (deepValidate's
      escalation loop only touches missing_eoi; codestream emits c145 at fixed
      .warn) — test added as the lock, no implementation invented (per Einstein).
- [x] **b1_mono + p0_04 c251 false positives — over-read cap fix** (2026-07-24).
      Adjudicated per spec (not decoder consensus): both are CONFORMING (b1
      byte-exact vs openjpeg, p0_04 max_abs≤1); each has one valid cblk that
      legitimately over-reads **3** past-end 0xFF during normal MQ termination
      (T.800 C.3.4). jz's `over_read > 2` rested on a wrong "0-2" assumption. New
      cap = **4**, DERIVED from the decoder's register lookahead (2 INITDEC
      pre-load + ≤2 final-renorm byteins; `reconstruct.zig` deepValidate +
      `mq_coder.zig` doc). Not matrix-driven — b1/p0_04 (3) clear it on principle,
      e1 (12–21) + truncation still trip it. TDD via C FFI (b1/p0_04 must ACCEPT).
      Valid-set false positives 4→2.
- [x] **e1_colr — POC + interior-tile positional iteration** (2026-07-31, ~1:15 PM EST).
      The "MCT bug" label was WRONG. Two real causes, both fixed: (1) e1's tile 1
      carries POC markers (T.800 A.6.6) in both its tile-part headers; jp2z filed
      POC under c145 "ignored" but POC rewrites packet sequencing — now APPLIED:
      `parsePocBody` (main + tile-part headers, entries accumulate per tile à la
      openjpeg opj_j2k_read_poc) + `PocSequencer` (per-volume progression with
      shared include-set dedup per B.12.1, mid-walk volume append, passthrough
      replay). (2) POC's PCRL volume exposed a PRE-EXISTING origin-(0,0) bug in
      positional iteration (the honest NOTE in precinctIndexAt predicted it):
      RPCL/PCRL/CPRL now iterate the ABSOLUTE reference grid [tx0,tx1)×[ty0,ty1)
      with next-multiple stepping, openjpeg's tile-edge boundary special case,
      and origin-offset precinct indexing. Differential proof: tile-1 packet
      sequence byte-identical to patched-openjpeg JP2Z_DUMP_T2 trace (divergence
      was exactly 3 packets: l0 r3 c0-c2 p1 at ref x=128). Strict deep-validate
      e1: FAIL(c251×15+c252×56+phantom c3) → **ACCEPT** (all 8 tiles walk to
      end). Valid-set false-positive REJECTs now 1 (p1_04 only). TDD: witnessed
      RED via C FFI (smoke.c e1 embed), PocSequencer/parsePocBody/boundary unit
      locks, c145 classifier tests updated (POC out of the ignored set; malformed
      POC → c4/c142).
- [ ] **e1_colr tile-7 rendering residual (±2, NOT a validity issue).** Sweep
      max_abs 252 → 2: remaining diffs are ALL in tile 7 (bottom-right, 19×48,
      both-clipped), ±1/±2 both signs, ~63% of samples — a least-significant
      refinement deviation in cblk decode, PRE-EXISTING (masked by tile 1's 252
      before). Byte-budget accounting closes perfectly (no c251/c252/c253), so
      the validator is unaffected. Chase with the p1_04 multi-tile rendering
      block (needs the JP2Z_DUMP_T1 patch extended past its hardcoded tile 0).
- [x] **p1_04 — per-tile QCD + multi-tile 9/7** (2026-07-31, ~10:45 PM EST).
      The parked "4x = 2^half_bp paradox" and the c253 REJECT had ONE root
      cause neither investigation suspected: **63 of p1_04's 64 tile-part
      headers carry their own QCD** overriding the main header's quantization,
      and jz silently ignored them (not even flagged — QCD wasn't in the
      tile-scan c145 set). Tile 7's own LL expn=9 gives Mb=10 → numbps=7 →
      max passes 19 = exactly what the encoder declared; jz's main-QCD Mb=9
      made 19 look impossible (c253 false positive). Fixes: (1) tile-part
      QCD parsed (`parseQcdInto`) and applied to the owning tile's params
      (first tile-part only; later-part QCD → c145; tile COD added to the
      c145 flag set); (2) plans now carry tile-stamped `qcd_expn`/`qcd_mant`
      so dequant is per-tile-correct everywhere; (3) the 9/7 branch of
      decodeCleanroom restructured to the 5/3 branch's proven per-tile
      reconstruct→ICT→clamp→composite shape (origin-aware subband split +
      idwt97 parity). Sweep: p1_04 FAIL max_abs 3782 → **NEAR max_abs 1**;
      zero verdict drift elsewhere (sub-sampled 9/7 skips now report
      component dims, matching the 5/3 branch). Strict deep-validate p1_04:
      **ACCEPT** (TDD: witnessed RED via C FFI, 25 assertions).
      **Valid-set false-positive REJECTs: 0.** The multi-tile 9/7 "magnitude
      inflation" was never a DWT or scale bug — LEARNINGS updated.
- [x] **PTERM tighter over-read bound** (2026-07-24, Peter-endorsed). When
      `cblksty & 0x10` (predictable termination), every terminated pass ends with
      a full flush, so the legitimate past-end tail is bounded at 2 — openjpeg's
      `check_pterm` bound (t1.c:2152, enabled tcd.c:2056 only under PTERM + all
      layers), now applied WITH its precondition and as a strict finding rather
      than openjpeg's warning-only. `overReadCap(cblksty)`: 2 under PTERM, else
      the register-derived 4. TDD: classifier boundary-domain test (RED'd against
      flat-4) + generated `pterm_test.j2k` fixture (opj_compress -M 16,
      cblksty=0x10 verified) must ACCEPT via strict FFI. Future: a corrupt-PTERM
      whole-file mutant (over_read ∈ {3,4}) as an e2e detection proof — needs
      byte-level crafting since packet lengths must stay consistent.
- [ ] **Integration:** Validate deep-validates via stock OpenJPEG, not jp2z
      (Einstein's critical fact). Switch `validate/src/core/jpeg2000_validator.zig`
      to `jp2z_deep_validate` once false positives are cleared — jp2z's stricter
      c251/c252 checks are the product differentiator.
- [x] **Marker-field ranges + crash-class hardening** (2026-08-01). COD
      decomp>32 / cblk-exp>8 were warn-then-assign — downstream geometry sizes
      [33] arrays and computes `exp+2` in u8, so hostile values PANICKED
      ReleaseSafe (witnessed SEGV in the RED) and were UB in ReleaseFast. Now
      FAIL + un-publish coding_params (invalid-precinct containment). Also:
      layers=0 FAIL, xcb+ycb>12 area cap FAIL (T.800 A.6.1), reserved Scod/
      cblksty bits WARN (0x40 = HTJ2K HT flag, T.814), parseQcdInto subband
      count widened to u16.
- [x] **SOT/Psot/TPsot tile-part consistency** (2026-08-01). Per-tile
      structural ledger surviving TileWalk removal: Psot 1..13 (can't hold
      SOT+SOD) FAIL; Isot outside the SIZ tile grid FAIL; TPsot must start at 0
      and increment strictly per tile; parts beyond TNsot FAIL; conflicting
      TNsot WARN; a part arriving after its tile completed FAILs and no longer
      resurrects a fresh TileWalk over finished state. Unsound parts are
      excluded from the packet walk while traversal continues.
- [ ] **Remaining strictness surface**: tag-tree invariants (monotonicity /
      inclusion / zero-bitplane anomalies), embedded-stream base-offset+length
      bounds (payload-relative vs host-file offsets; no read may escape a
      bounded Source), PLT/TLM cross-checks vs actual tile-part lengths.
- [x] **Diagnostics: published code registry + anchored deep findings**
      (2026-08-01). `jp2z_finding_code_t` is now in `include/jp2z_core.h`
      (full registry with band comments), so C consumers stop hardcoding
      numbers; smoke.c dropped its local #defines and `_Static_assert`s the
      numbering through the ABI (drift fails the build). Aggregate deep
      findings (c251/c252/c253) now carry a byte OFFSET and name their first
      offending code-block in `detail` ("first: tile T comp C rR band B prc P")
      — plans gained `src_offset` (first-contribution byte). Motivation was
      concrete: the p1_04 c253 hunt needed a throwaway trace build purely
      because the finding identified nothing.
- [ ] **Diagnostics, remaining**: several structural findings still carry no
      offset where one is derivable; audit `emit` call sites for `null`
      offsets. Consider a per-finding cblk identity struct rather than
      free-text `detail` once a consumer needs to machine-read it.
- [x] **jpegz unblock — `@import("jp2z")` without openjpeg** (2026-07-31,
      ~8:30 PM EST; priority-bumped by Peter via jpegz: "fix U1, then U5" put
      it on jpegz's critical path, landed between the e1 and p1_04 blocks
      exactly as the ack predicted). The comptime C-ABI force-link moved from
      `src/jp2z.zig` to a new `src/lib_root.zig` (static-lib artifact root
      only); build.zig now has a PUBLIC bare `jp2z` module (zero C
      attachments — `addModule`) + an internal Phase-1 flavor carrying the
      openjpeg backend for in-repo decode artifacts (dissolves at Phase 3).
      Witnessed RED via `tests/import_probe.zig` — a validate-only consumer
      of the public module that must build+link with ZERO C deps — which
      reproduced jpegz's exact reference trace, then flipped green; the probe
      is now a permanent MFIC gate in `zig build test`. Fleet ruling recorded
      (Peter via jpegz 2026-07-31): jp2z's C-FFI dogfooding obligation is
      WAIVED — jpegz (facade + its U5 C CLI) carries it family-wide; our C
      CLI stays as the e2e vehicle only.
- [x] **Build hygiene: nested `libopenjp2.so` in `libjp2z.a`** (2026-07-31,
      fixed by the same slice): the lib artifact (lib_root) gets the include
      path only — NO linkSystemLibrary — so the archive no longer embeds the
      dynamic dep and the `ld.lld: neither ET_REL nor LLVM bitcode` warning
      is gone from every FFI link (verified: 0 warnings, 0 `.so` members via
      `ar t`). Executables linking libjp2z.a resolve `-lopenjp2` themselves,
      as all in-repo consumers already did.
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
- [x] **SOP/EPH packet markers** (2026-07-18, on Thelio). Walker now consumes the
      per-packet SOP (FF91 + Lsop + Nsop) and EPH (FF92) delimiters gated by
      `params.scod` bits 1/2 (`walkTilePartBody`, threading `eph_bytes` into
      `data_base`/`advance`). Per the corruption-detection mission it validates
      AGGRESSIVELY: FF91/Lsop==4 + **Nsop packet-sequence** (a check openjpeg
      explicitly TODOs and skips → a jp2z stricter-than-openjpeg differentiator) and
      FF92 presence, emitting `.fail jp2_invalid_codestream` on any mismatch. Fixture
      `a5_mono` added; TDD = byte-exact decode + a corrupted-Nsop detection classifier.
      **Sweep PASS 14→17** (a5 + 2 g*). 226 tests, no regressions.
- [x] **Tier-1 VSC/RESET/SEGSYM coding styles** (2026-07-18, Thelio). Implemented the
      three EBCOT flags c2 stacks over c1 (`cblksty=0x2f`): **RESET** (`ctxs.* =
      initContexts()` after each MQ pass), **VSC** (vertically-causal — a bottom-of-stripe
      coefficient `y%4==3` drops its 3 south neighbours from ZC/SC/MR/hasSig context;
      via a `Cblk.vsc` flag, no pass-signature churn), and **SEGSYM** (decode+verify the
      `0xA` symbol via UNI context after each cleanup pass; sets `cblk.segsym_error`).
      **c2_mono byte-EXACT**, sweep **PASS 17→19** (c2 + b3), 227 tests, no regressions.
      NOTE: `segsym_error` surfaces as a FINDING only once tier-1 feeds `validate()`
      (the Phase-2 dispatcher cutover); today validate is tier-2 (packet-walk) so the
      flag is staged for then. The corrupted-`Nsop` SOP path already emits in tier-2.
- [x] **b1_mono image-origin geometry — FIXED byte-EXACT** (2026-07-19, Thelio). Root cause
      was TWO coordinated bugs in the tier-2 packet iterator, NOT the DWT/subband math (which
      was already correct). (1) `PacketIterator.init` computed per-resolution precinct geometry
      with tile origin **(0,0)** instead of the real tile-component origin (tcx0,tcy0) —
      hardcoded `numPrecincts(0, 0, …)`. For a narrow interior tile (b1 col0 is 3px wide at
      abs X=3097) origin-0 gives width≥1 at every resolution, but the REAL origin collapses the
      coarse resolutions to zero extent (ceil(3097/32)==ceil(3100/32)). (2) `nextIndexed` (LRCP)
      emitted a packet for EVERY resolution, never skipping zero-precinct ones. Together they
      made the iterator emit phantom packets for empty resolutions → those consumed real
      packets' bytes → whole-tile byte-stream desync → every code-block decoded to zero (tile
      output = pure +128 DC shift). Latent for large tiles (origin-0 and real-origin give the
      same precinct COUNT); b1/b3's tiny clipped edge tiles exposed it. Fix: thread tcx0/tcy0
      through `PacketIterator`; skip zero-precinct resolutions in `nextIndexed` (the emitted-
      count == `total()` invariant). Diagnosed via the per-tile 3×5 mismatch-grid instrument
      (kept in the b1 test, prints only on failure) + plan-count/buffer-energy tracing.
      **b1_mono AND b3_mono both byte-EXACT** (max_abs 195/202 → 0); sweep **PASS 19→21**, no
      PASS→FAIL drift. Added a focused MFIC metamorphic test (iterator emits exactly total()
      packets, none in an empty resolution) + the b1 byte-exact differential test. 229 tests.
- [ ] **Next: p1_04 >8-bit** (tiffz gap), 9/7 multi-tile `p1_*` (needs cas/origin for the 9/7
      path like the 5/3 path has), p0_13. TDD vs openjpeg.
- [ ] **Minor (Thelio)**: benign `warning(link): unexpected LLD stderr` in the fast
      dev-loop build (`zig build test` in the devShell); `nix build`/`./test` are clean.
      Likely a new-machine LLD version quirk — investigate/silence for clean dev output.
- [x] **Reviewer catch — reject user-precinct PPx/PPy=0 at r>0** (2026-06-30, commit
      ba313895). jp2z-reviewer's audit of the multi-tile commit found a reachable crash
      on the shipped validate() path (u6 underflow in TileWalk.init). `parseCodBody` now
      flags `.jp2_invalid_codestream` + un-publishes coding_params; `precinctCblkGeom`
      guards pdx/pdy==0. TDD classifier fixture; 224 tests; existing code 141 (no registry
      change).
- [x] **Sweep upgrade — prefer committed `.pix` planar oracle** (2026-07-19, Thelio). The
      `./sweep` driver now passes `SWEEP_PIX=tests/unit/fixtures/oracles/<name>.pix` (via
      `env`, when the file exists); `sweep_one` diffs the cleanroom planes against that PLANAR
      per-component oracle (raw opj_decompress output) BEFORE falling back to the in-process
      wrapper. The `.pix` is component-resolution + causally-independent (opj CLI), so
      sub-sampled fixtures grade honestly instead of `skip:dim-mismatch`. Guarded: only used
      when `pix.len == Σ plane.len` (1 byte/sample u8) — a stale/wrong-size `.pix` falls
      through, never mis-grades. **p0_10 DECODED→PASS byte-exact** (sub-sampled 4× + 2×2
      multi-tile 5/3); a1/c1/d1/p0_04/p0_09 keep identical verdicts (now tagged `oracle:pix`).
      Sweep **PASS 21→22**, skip 21→20, no regressions.
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
