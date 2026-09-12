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

### Directive: validation coverage → 100% (Peter, 2026-09-06 EDT)

Overarching goal restated by Peter: any bit or byte corruption that is
theoretically catchable in a JPEG 2000 file SHALL be caught. Both slices
below must land; order is mine. PPM/PPT first (it is the one remaining
class of stream the deep validator cannot walk at all), then the decode
cluster (a wrong decode can neither confirm nor refute entropy findings on
those fixtures, and OpenJPEG retirement is gated on it).

- [x] PLAN.md stale-checkbox sweep (2026-09-06 ~11:00am EDT).
- [x] **PPM / PPT packed packet headers** (2026-09-06 ~11:30am EDT). Main-
      header PPM collector (Zppm-ordered merge, Nppm chunks split over the
      concatenation, one chunk per tile-part) + tile-part PPT store; the
      packet walk reads headers (and EPH) from the store, bodies (and SOP)
      from the tile-part. New finding c256 packed_headers_mismatch (store
      leftover / store dry with bodies remaining / missing or surplus PPM
      chunks); duplicate Zppm/Zppt, PPM+PPT together, Nppm overrun, Lppt<4
      all FAIL. 17 crafted RED tests + g3/g4/p1_06 vendored as must-accept
      controls (matrix 12→15 codestream, 0 false positives). Sweep PASS
      22→26, NEAR 2→3, FAIL 12→7.
- [x] **Decode 127/128 cluster** — was NOT a DC-shift bug: every fixture in
      it is a PPM/PPT user (marker census, see LEARNINGS 2026-09-06). Closed
      by the slice above: g1–g4 byte-exact, p1_02 NEAR. (2026-09-06)
- [x] **9/7 at odd tile origins (cas==1) + one-sample lines** (2026-09-06
      ~11:30am EDT). idwt97Line was cas==0-only (doc comment said so) yet
      received real parities from idwt97; interior tiles lifted with the
      wrong neighbours and 1-sample lines underflowed `bound-1` (ReleaseSafe
      panic / ReleaseFast OOB read). Now: cas==1 branch (low at odd
      positions), openjpeg-exact degenerate guards (lone sample untouched,
      no K scale, no halving — noted spec deviation), reflection
      metamorphic test pins cas1 == reverse(cas0(reverse)). p1_06 NEAR
      (max_abs 1), p1_05 255→18. Sweep PASS 26, NEAR 4, FAIL 6, ERROR 1.
- [x] **Per-coefficient reconstruction half-bit** (2026-09-06 ~11:45am EDT).
      p1_05's max_abs 18 was NOT the DWT: the new `zig build tile-hist`
      diagnostic (per-tile max_abs + JP2Z_DUMP_T1 per-cblk T1 diff) showed
      2235/7485 cblks differing only in the half-bit position, every one
      with a pass count ending after SP (2,5,8,11,14,17). jp2z applied one
      halfBitPos per cblk; openjpeg carries the half inside each
      coefficient (set at significance, moved by each refinement), so a
      mid-plane stop leaves unvisited coefficients one plane higher. Now
      Coeff.half_bp is stamped at all 6 sig/ref sites; halfBitPos retired.
      RED: vendored p1_06.t1.bin oracle (9.8 KB, 180 cblks, 2 mid-plane).
      Sweep: p1_05 18→NEAR 1, p1_06 NEAR→PASS (byte-exact 9/7), balloon
      9→0/12 tiles off. PASS 27, NEAR 4, FAIL 5, ERROR 1.
- [x] **e1_colr tile 7 ±2 = ZERO-BYTE CONTRIBUTIONS, not RGN** (2026-09-06
      ~12:20pm EDT). CORRECTION: the earlier "e1 carries 3 RGN markers"
      claim came from grepping raw `ff5e` bytes, not marker segments — e1
      has NO RGN. The T1 diff showed 7 tiny cblks where openjpeg carried
      extra low bits = more passes decoded. Cause: the extractor skipped
      any contribution with byte length 0, so passes signalled with zero
      bytes (legal, B.10.7) never reached the plan — decode stopped short
      AND the coding-pass budget was under-counted. CodeBlockState now
      records last_contribution_passes; the extractor keys on it. RED:
      crafted 1-pass/0-byte packet + the 7 e1 cblks vs oracle values.
- [x] **JP2 cdef channel order** (2026-09-06 ~1:40pm EDT). parseJp2HeaderBox
      parses cdef (I.5.3.6) into report.cdef (colour i ← channel order[i]);
      decodeCleanroom delivers planes in colour order when the map is a
      permutation. Cn beyond ihdr NC or two channels for one colour → FAIL.
      RED: crafted 3-component mini-JP2 with a 12-bit last component (DC
      2048 vs 128 makes the BGR permutation observable) + the two FAIL
      cases. file2 (BGR cdef) was the last sweep FAIL. Sweep: PASS 32, NEAR
      4, FAIL 0, ERROR 4 (all explicit UnsupportedMixedWavelets /
      TooManyComponents), skip 17.
- [x] **COC + RGN per-component overrides, per-component sub-sampled
      geometry** (2026-09-06 ~1:20pm EDT). Ten ISO fixtures use COC/RGN and
      EVERY one failed strict validation for it. Now: CompCoding (decomp,
      cblk, cbsty, wavelet, precincts) per component with tile COC > tile
      COD > main COC > main COD; RGN shift folded into numbps (coded planes
      = M_b + shift − zbp) and descaled after tier-1 (H.2); the packet
      iterator, POC sequencer index, tile-walk slot pool and extractor all
      key on (component, resolution) with each component's OWN sub-sampled
      tile rect (was component 0's for all — p1_07's 4:1 component). Also
      found on the way: reserved markers FF30..FF3F have no segment (p0_02:
      walker read the SOT as a length); quantization tables are now body-
      driven with a per-component coverage check (p0_08's QCC lengths),
      which retired the QCD-before-COD queue; the non-PTERM over-read cap
      was recalibrated 4→12 from a 57-file census (p0_08 10, file6 8).
      RED: crafted COC in LRCP/RPCL/CPRL, crafted RGN, 6 vendored fixtures
      (+3 corpus-gated), byte-perfect T1 oracles for p0_02/p0_03/p1_01/
      p1_07/p0_13. Census: tier-1 byte-perfect vs openjpeg on ALL 57
      conformance fixtures. Matrix 23 controls, 0 FP, floors 15/15/21.
- [x] **Fuzz-corpus hardening + tier-2 oracle** (2026-09-06 ~2:20pm EDT).
      Nonregression census (151 openjpeg-data files) found 7 panics on
      legal-but-extreme SIZ/COD values: geometry helpers shifted u5 (32
      decomposition levels overflow), numTilesXY/tileRect did the ceil in
      u32 (issue823: Ysiz 0xFFF60001 + YTsiz 0xF0000100 > 2^32). All widened
      to u64 with RED tests. TNsot under-declaration downgraded to WARN
      (walk continues; issue208/235/text_GBR/mem-b2b now accepted).
      Diagnostics: JP2Z_TRACE_CBLK per-contribution trace, the openjpeg
      patch now prints `jp2zCB ... passes= bytes=` per code-block under
      JP2Z_DUMP_T2, tile-hist prints the matching `oursCB` under
      JP2Z_DUMP_CB and decodes the layer-0 share alone under JP2Z_LAYER0
      (plan.first_passes/first_len). kodak_2layers_lrcp: tier-2 agrees
      with openjpeg on all 9768 blocks; layer 0 alone is budget-clean on
      all 7263 multi-layer blocks; every anomaly is in layer 2, and JasPer
      rejects the file (jpc_dec_decodepkt failed) — a TRUE positive that
      openjpeg decodes leniently. JasPer also rejects 15 more of the 22
      "openjpeg accepts / jp2z FAILs" files. tile-hist still panics on
      issue823 in decodeCleanroom (tool-only: the CLI refuses the file).
- [x] **Surplus coding passes (test_lossless.j2k, ClearCanvas DICOM
      OpenJPEG-1.x lineage)** (2026-09-06 ~2:25pm EDT). Blocks declare
      3·numbps−2 + {2,5,8} passes; the bytes are real (budget clean when
      all passes are decoded), and openjpeg + JasPer produce byte-identical
      full-range output by ignoring passes below plane 0. jp2z ran them at
      a clamped plane and wrote bit 0 (T1 diff: ours=±1 where oj=0). Now
      `codeMagnitudeBit` no-ops at bp==0 (MQ/state fidelity kept, so the
      budget still bites on garbage counts), coeffToOpenJpegI32 maps
      surplus-only significance to 0, finding 253 is a WARN in both modes
      for surplus (numbps>31 stays `sev`). RED: synthetic 8x8 plan 7 vs 10
      passes must reconstruct identically; crafted 4-pass/1-plane stream
      must WARN under strict. test_lossless: T1 diff 259/259 exact,
      overall warn; kodak: T1 exact, still FAIL on over/under-read.
      Observed on the way: 12-bit files reconstruct to saturated pixels
      where openjpeg has 0 — the known >8-bit rendering gap (p1_04).
- [x] **Nonregression triage: the three files only jp2z rejected**
      (2026-09-06 ~2:35pm EDT). After the JasPer cross-check, openjpeg AND
      JasPer accept Marrin.jp2, issue211.jp2 and htj2k/Bretagne1_ht.j2k.
      Marrin (Kakadu 5.2.1): COD says 2 layers, the tile-part holds only
      layer 0's 12 packets — openjpeg's packet dump puts all 12 layer-1
      packets at the tile-part end offset. TRUE positive; truncated_stream
      now carries "tile 0: 12 of 24 packets present … next expected: layer
      1 res 0 comp 0 prc 0". issue211: a CRLF after the last box — new
      finding 257 jp2_trailing_bytes, WARN in both modes (no image data
      affected). Bretagne1_ht: cblksty 0x40 (HT, T.814) is c145 now —
      WARN jp2_unsupported_marker_ignored, deep validation skipped
      (list.ht_unsupported), decodeCleanroom refuses with
      UnsupportedHtCodeBlocks; the 273 phantom under-reads are gone. bit 7
      stays the reserved-bit WARN. broken.jpc (JasPer 1.701 output, both
      decoders accept): tier-2 agrees with openjpeg on all 75 blocks, tier-1
      exact, yet component 2's r3–r5 budgets are off by hundreds of bytes
      — the file is what its name says; FAIL stands.
- [x] **CAP marker (FF50, Part 2 / T.814 capabilities)** read as
      unknown_marker; now a named valid-but-unsupported WARN (2026-09-06
      ~2:40pm EDT). RED: mini stream + minimal CAP (Lcap 6, Pcap 0).
- [x] **Structural false negatives from the census** (2026-09-06 ~2:50pm
      EDT). Five openjpeg-data files opj_decompress REFUSES were accepted
      with no FAIL. Now: main header without COD or QCD → FAIL (A.4 Table
      A.1; 1888.pdf.asan, issue408); SOD/EOC before any SOT → FAIL "no
      tile-part" (issue362-2863: a fuzzed SOT became a PPM marker and the
      walk returned silently); jp2h without a usable ihdr → FAIL (I.5.3.1;
      issue364-903); COD/COC/RGN exact segment lengths (A.6.1–A.6.3) →
      FAIL bad_marker_length. Four crafted-stream tests that relied on the
      old permissiveness (SIZ-then-SOT, no SOD) now carry COD+QCD+SOD.
      Refreshed census (151 files, 0 panics): opj-ok/jp2z-fail 22→17,
      of which JasPer also rejects all but issue412 (palette cdef) and
      the fuzz files; opj-fail/jp2z-accept 5→2 pending (edf_c2_1103421:
      tile-part header COC with Lcoc 521 runs past SOD and is accepted;
      mem-b2ace68c-1381: pclr with NE=1/NPC=4 but no entries).
- [x] **Tile-part without a reachable SOD → FAIL** (2026-09-06 ~2:55pm
      EDT). findSod returned null for a header segment running past the
      tile-part end (edf_c2_1103421's COC with Lcoc 521) or non-marker
      bytes after SOT, and the caller skipped the tile silently. Now FAIL
      jp2_invalid_codestream naming both causes (A.4.2/A.4.4). Six crafted
      streams in the suite that ended a tile-part at SOT→EOC gained SOD
      plus their due empty packets.
- [x] **JP2 palette (pclr/cmap) validation + cdef channel count**
      (2026-09-06 ~3:05pm EDT). pclr: NE 1..1024, NPC ≥ 1, box length =
      3 + NPC + NE × Σ ceil(depth_i/8) (I.5.3.4); cmap: 4-byte entries,
      CMP < ihdr NC, MTYP ∈ {0,1}, MTYP 1 needs PCOL < NPC, MTYP 0 needs
      PCOL 0 (I.5.3.5); pclr and cmap must come together. jp2h is now
      collected then validated (any sub-box order), and cdef's Cn indexes
      cmap's output channels when a palette exists. Palette not applied by
      decode → c145 WARN, so file9 (ISO palette fixture) is the matrix's
      one unsupported control. issue412 (Kakadu 7.3.3 palette) accepted;
      mem-b2ace68c-1381 (pclr NE=1/NPC=4 without entries) FAILs.
- [x] **Per-component wavelets in decode** (2026-09-06 ~3:15pm EDT). An
      all-5/3 image keeps the exact integer path; any other mix goes
      through the Q16 path where each component picks its own transform
      (5/3 output widened to Q16, RCT-on-Q16 when component 0 is 5/3 and
      MCT is on, per openjpeg's tccps[0].qmfbid rule). RED: p0_06 (three
      9/7 components + one 5/3 via COC, 12-bit, sub-sampled) vs the oracle:
      9/7 within 1, the 5/3 component exact. On the way: the oracle
      wrapper packs >8-bit samples as u16 in its byte buffer; tile-hist and
      the new test read them through pixelsU16, which erased the "p1_04
      >8-bit gap" (0/64 tiles off) — it was never a decode defect.
- [x] **PLM cross-check** (2026-09-06 ~3:20pm EDT). PLM (A.7.2) was
      recognised but never read. Now: Zplm-keyed segments concatenated in
      order (gap / duplicate → FAIL), split into per-tile-part Nplm runs of
      7-bit lengths (Nplm overrun, straddling code → FAIL), walked like
      PLT (a PLT present is walked and PLM must agree with it), with
      fewer/more tile-part entries than the codestream → FAIL. RED:
      matching PLM (also split across two segments) accepted; a wrong
      length and a surplus entry FAIL naming PLM.
- [x] **OpenJPEG retired from decode** (2026-09-06 ~3:35pm EDT).
      `decode`/`decodeWithOptions` → decode/image.zig: validate once,
      reconstruct (decodeFromReport), shape into the public Image (canvas
      at the finest sub-sampling with nearest-neighbour replication,
      pclr/cmap palette applied, unsigned clamp, u8/u16, colr enumcs →
      colour space, layout by channel count). The report now carries
      colr_enumcs, palette values and cmap entries. MFIC differential
      (tests/unit/decode.zig): the cleanroom route equals the wrapper
      byte-for-byte on c1_mono, file1, file9 (palette) and within 1 on
      d1_colr, a5_mono, e1_colr, p1_04 (12-bit), p0_06 (mixed + sub-
      sampled), balloon; dims/channels/prec/layout/colour space equal. The
      CLI, the archive and the C smoke link no openjpeg (ldd clean); the
      wrapper lives on only behind internal.openjpegDecode for the tools
      and tests. Unsupported-but-valid streams (>16 comps, HT, tile COD
      override) decode as NotImplemented (C: -1).
- [x] **Segmentation-symbol finding c258** (2026-09-06 ~3:40pm EDT). The
      EBCOT decoder set Cblk.segsym_error on a wrong 1010 marker (SEGSYM,
      D.5) but deepValidate never reported it. Now finding 258
      segmentation_symbol_mismatch (strict FAIL / lenient WARN), the one
      in-stream integrity hook the standard offers. RED: p1_06 (VSC+SEGSYM)
      clean → none; one byte flipped mid-stream → c258. 0/57 conformance
      files report it; matrix codestream bolter 15 → 16, floor ratcheted.
- [x] **JP2 container checks: ftyp, ihdr fields, colr, box order**
      (2026-09-06 ~3:45pm EDT). ftyp must follow the signature box and
      carry brand 'jp2 ' or list it (I.5.2) — FAIL; ihdr NC vs Csiz and
      BPC vs every Ssiz (BPC 0xFF needs a bpcc box whose entries match)
      (I.5.3.1/2) — FAIL, C != 7 — WARN (decoders ignore it); colr METH 1
      exactly 7 bytes for a Part-1 EnumCS (CIELab 14 and Part-2 spaces
      append parameters: min 7), METH 2 with a profile — FAIL; METH 3/4
      and non-Part-1 EnumCS — valid-but-unsupported WARN; jp2h before
      jp2c (I.5.3) — FAIL. Corpus: no conformance JP2 or fixture trips
      any of it; every nonregression hit is a file openjpeg rejects. The cdef test's
      crafted 8/8/12 container now declares BPC 0xFF + bpcc.
- [x] **Quantization-table shape + duplicate JP2 boxes** (2026-09-06
      ~3:55pm EDT). Style 1 (scalar derived) must carry exactly one 2-byte
      entry, style 2 entries must be whole pairs (A.6.4) — FAIL
      bad_marker_length; a second ftyp or jp2h box — FAIL (I.5.2/I.5.3).
      Audit on the way: Isot range, TPsot sequencing and PPx/PPy ≥ 1 above
      r0 were already enforced.
- [x] **Severity policy corrected to Peter's rule: proven nonconformance
      FAILs and is reported** (2026-09-12 ~12:00pm EDT; jpegz inbox note
      relaying Peter: "our priority is not tolerance for error, it is
      failing and reporting it"). Reverted this round's downgrades:
      more tile-parts than TNsot declares → FAIL with "tile T: tile-part
      N exceeds the declared TNsot M (A.4.2)", walk continues (no early
      abort); conflicting TNsot across a tile's parts → FAIL; surplus
      coding passes → strict FAIL / lenient WARN; trailing bytes after
      the last JP2 box → FAIL; ihdr C ≠ 7 → FAIL. `decode` now refuses a
      stream whose validation FAILs (never reconstructs nonconformance;
      also closes the issue1438/issue823 CLI panics), and the two
      reconstruction sites guard against fuzzed geometry. Controls:
      TNsot=2 and TNsot=0 two-part streams walk clean. Proposed, NOT
      done (reported to jpegz/Peter for a decision): the remaining
      reserved-value WARNs are the same class — Scod reserved bits,
      cblksty bit 7, Rsiz undefined values, TLM Stlm reserved bits, COM
      Rcom > 1, QCD/QCC with fewer subband entries than the
      decomposition needs, ihdr/SIZ dimension mismatch already FAILs.
      Valid-but-unsupported (c145: HT, CAP, palette in decode, Part-2
      colr, >16 components) stays WARN: those are conformant streams.
- [x] **Nonregression census, final for this round** (2026-09-06 ~3:15pm
      EDT): 151 files, 0 panics, 0 files openjpeg rejects that jp2z
      accepts, 17 files jp2z FAILs that openjpeg decodes — JasPer rejects
      every one except the asan fuzz file, and each FAIL names its cause.
- [ ] **Phase-1 openjpeg wrapper panics on valid inputs** (oracle-only
      code, scheduled for retirement): 257 components → 16-bit output cast
      overflow (openjpeg_wrapper.zig:208); 2-component image → colour-space
      switch `unreachable` (:150). Guard both (error, not panic) or retire.
- [x] **Tile-part COD overrides** (2026-09-06 ~12:30pm EDT). A.6.1: a
      first-tile-part COD is the tile's coding style (progression, layers,
      MCT, decomp, cblk, wavelet, precincts). parseCodBody → parseCodInto
      (any params target); TileOverrides.cod span applied FIRST at tile
      init (QCD/QCC sizing depends on its decomp). An unwalkable tile COD
      skips that tile's walk (ledger broken); a later-part COD → c145. A
      tile changing decomp/wavelet/MCT is validated but decode refuses
      (error.UnsupportedTileCodingOverride) rather than mis-render. RED:
      crafted 1→2 layers, f1_mono (tile 4: 7 layers, previously 3 layers
      unwalked = silent under-validation), d2 byte-exact vs openjpeg. d2 is
      Sweep: d2 254→PASS; PASS 31, NEAR 4, FAIL 1 (file2 cdef), ERROR 1.
      matrix control 17; NO ISO control carries an ignored marker any more
      (unsupported 0/17); smoke.c c145 invariant uses a crafted RGN stream.
- [x] **QCC per-component quantization** (2026-09-06 ~12:15pm EDT). QCC
      (main + tile-part) applied with A.6.5 precedence; CodingParams grew
      `quant: QuantTable` + `comp_quant[16]`; mbForSubband/quantFor take
      the component. p0_04 comp-1 numbps now 6 (was 8: QCD table used for
      a QCC component → pass budget 2 planes too lenient). Cqcc >= Csiz →
      FAIL; Cqcc >= 16 → c145. smoke.c's c145 invariant rides on f1_mono
      (tile-part COD) now that p0_04 has no ignored marker. Sweep after both
      fixes: e1 → PASS byte-exact; PASS 30, NEAR 4, FAIL 2 (d2 tile-COD,
      file2 cdef), ERROR 1 (p0_13 COC/RGN/>16).
- [x] **QCD-before-COD marker order** (2026-09-06 ~12:00pm EDT). p0_01 and
      file8 put QCD first (legal, A.4.1); the M_b table was sized from COD's
      decomp count at QCD-parse time → every HF band M_b=0 → numbps 0 →
      cblks skipped AND a strict c255 FALSE POSITIVE on a valid ISO file.
      Main-header QCD is now held until COD lands. RED: marker-order
      metamorphic test + p0_01 vendored (control 16, T1 oracle byte-exact).
      Sweep: p0_01 149→PASS, file8 216→PASS. PASS 29, NEAR 4, FAIL 3, ERROR 1.
- [x] **Csiz > 16 accepted** (2026-09-06). p0_13's 257 components were a
      jp2_invalid_siz FAIL (valid file). Csiz up to 16384 now; components
      past the 16th read through slot 15 and must repeat its descriptor
      (else c145 unsupported, never invalid). decodeCleanroom refuses >16
      with error.TooManyComponents instead of indexing past its arrays.
- [ ] Remaining sweep FAILs, attributed by tile-hist / T1 diff:
- [x] **Residual catchable-corruption audit** (2026-09-06 ~1:30pm EDT).
      Severity policy made explicit and applied: an UNDECODABLE value is
      FAIL (progression order > 4, MCT > 1, wavelet id > 1, quantization
      style > 2, precision > 38 bits, > 65535 tiles, CRG length != 4·Csiz);
      a RESERVED-but-decodable value is WARN (Rsiz undefined profile, COM
      Rcom > 1, TLM Stlm reserved bits); a DEFINED-but-unsupported feature
      is c145 (Rsiz Part-2/HTJ2K bits). COC/QCC/RGN ranges landed with
      their slices; SOP Nsop + EPH presence were already FAIL. POC bounds
      vs SIZ/COD deliberately NOT checked: T.800 B.12.1.3 lets REpoc/CEpoc
      exceed the actual counts (clamped), so a high value is legal.
      Eight crafted RED tests (byte-patched mini-streams); corpus Rsiz
      census: only 0/1/2 occur. Not done: PLM cross-check (rare; mirrors
      PLT, needs a fixture or a crafted multi-tile-part stream).

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
- [x] Remove OpenJPEG from the C decode path (2026-09-06 ~3:35pm EDT): `decode` runs decode/image.zig over the cleanroom reconstruction; the CLI and libjp2z.a link no openjpeg (ldd clean, 0 `opj_` symbols). The flake package still builds the oracle tools (sweep-one, tile-hist) against openjpeg; a runtime-only package output is a follow-up.
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
- [x] **Remaining strictness surface**: tag-tree invariants (monotonicity /
      inclusion / zero-bitplane anomalies), embedded-stream base-offset+length
      bounds (payload-relative vs host-file offsets; no read may escape a
      bounded Source), PLT/TLM cross-checks vs actual tile-part lengths. (all four landed 2026-08-14: `7e3e0a2` `e214a95` `738b3d7` `f9bc51b`)
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
- [x] **Diagnostics, remaining**: several structural findings still carry no
      offset where one is derivable; audit `emit` call sites for `null`
      offsets. Consider a per-finding cblk identity struct rather than
      free-text `detail` once a consumer needs to machine-read it. (null-offset audit done `e214a95` 2026-08-14; the cblk identity struct stays deferred until a consumer needs it)
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

- [x] `flake.nix` with openjpeg dependency wired (mirror jpegz's libjpeg-turbo setup)
- [x] `src/ffi/openjpeg_wrapper.zig` — port from jpegz's existing wrapper
- [x] `src/jp2z.zig` — public API surface (`decode`, `decodeWithOptions`, `validate`, `FindingsSink`)
- [x] `src/core/{errors, types, last_error}.zig` — adopt jpegz's vocabulary so future jpegz integration is a re-export shim
- [x] `src/decode/findings.zig` — `FindingsSink` (mirror jpegz)
- [x] `src/ffi/c_api.zig` — `jp2z_*` C exports matching jpegz's `jpegz_jp2_*` shape
- [x] `include/jp2z_core.h` — C header with usage example
- [x] `cli/main.c` — minimal C CLI that decodes JP2/J2K and emits PPM/PGM
- [x] `tests/unit/{smoke, decode, validate}.zig` — Zig test suite
- [x] `tests/cli/smoke.c` — C FFI smoke test
- [x] `tests/unit/fixtures/` — small JP2/J2K test fixtures
- [x] CI green (Garnix originally; Mechatron Prime since 2026-07-15)

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
- [x] COD/QCD body field-level validation (prog. order, wavelet filter, decomp. levels) — optional refinement (done 2026-08-01, marker-field ranges)
- [x] Known-bad fixtures (truncations, bad markers, garbage fields) — defensive coverage (tests/mutation_matrix.zig + validate.zig crafted-stream tests)

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
- [x] Findings vocabulary enrichment for corruption-detection consumers
      (primary downstream use case is data integrity, not pixel decode).
      Track every spec deviation; never silently smooth issues. Specifics (done: registry 250-255 published through the C ABI, 2026-08-14)
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
- [x] Move `openjpeg_wrapper` -> `internal.openjpegDecode` for oracle-only use. (2026-09-06)
- [x] Final cleanup: openjpeg is out of the runtime artifacts (CLI, archive, C smoke link) — 2026-09-06. Remaining: flake `packages.default` builds the oracle tools too.

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
- [x] Coding-pass budget exceeded (> 3*numbps-2); coefficient magnitude bit
      above numbps (impossible value). (c253 + c255, `f9bc51b`; a magnitude bit above numbps is unreachable by construction since the decoder only visits numbps planes)
- [x] Tag-tree monotonicity violations; inclusion/zero-bitplane anomalies. (`f9bc51b` 2026-08-14)
- [x] Marker field validation (reserved bits, out-of-range Scod/Sqcd/SIZ,
      impossible param combinations) beyond what's parsed today. (Scod/cblksty reserved bits, SIZ ranges, COD caps: 2026-08-01. Residual: Rsiz capability value unchecked, see "toward 100%" below)
- [x] SOT/Psot tile-part length + ordering consistency; EOC presence;
      trailing-garbage; PTERM predictable-termination check (always-on). (Psot vs TLM `738b3d7`; EOC + post-EOC tail check; PTERM tail bound in reconstruct.zig)
- [x] A `strict` mode: any deviation escalates to FAIL (vs lenient: warn).
- [x] FFI: jp2z_deep_validate(data,len,strict,sink) exposes it to `validate`.
- [x] (Future M7 polish) tag-tree monotonicity + deeper marker-field validation. (2026-08-14)
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
