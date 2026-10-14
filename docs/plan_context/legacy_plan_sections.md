# Legacy PLAN.md section preambles (2026-06 to 2026-09)

Prose that introduced the retired PLAN.md sections, moved here verbatim on
2026-10-14 when the plan was reduced to one-line items (planning-work skill).
The items these paragraphs introduced are in docs/PLAN_LOG.md under the same
section titles. Nothing here is open work.

### entropy_under_read false positive on real lossy JP2 (2026-08-13 EDT)

Reported by jpegz 2026-08-12 (inbox), fixture offered by validate 2026-08-13.
Sole blocker on validate's JP2 cutover (jp2z → jpegz → tiffz → validate).

### M7 strictness surface — remaining gaps (2026-08-14 EDT) — DONE

Einstein's original 1.0-audit "embedded-stream bounds" item plus the
three follow-ups I'd parked. All four TDD-first (RED witnessed where
new behavior), `./test` green, sweep drift zero, pushed.

### Directive: exceed the oracle; profiles validated, not just recognised (Peter, 2026-09-16 EDT)

Peter: OpenJPEG stays as the oracle until jp2z exceeds it; recognised
profiles must also be validated; corruption-probe must be run on jp2z
honestly. Agreed order:

### Directive: validation coverage → 100% (Peter, 2026-09-06 EDT)

Overarching goal restated by Peter: any bit or byte corruption that is
theoretically catchable in a JPEG 2000 file SHALL be caught. Both slices
below must land; order is mine. PPM/PPT first (it is the one remaining
class of stream the deep validator cannot walk at all), then the decode
cluster (a wrong decode can neither confirm nor refute entropy findings on
those fixtures, and OpenJPEG retirement is gated on it).

### Mecha Validate v1 leaf gate (2026-08-04 EDT)


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

## Phase 1 — openjpeg wrapper (working v1)

## Phase 2 — pure-Zig decode milestones

Each milestone retires part of the openjpeg dependency. After M6 the
wrapper moves to `jp2z.internal.openjpegDecode` for byte-perfect
oracle tests.

### M7 — strict validation findings (THE `validate` differentiator)
Goal: report MORE error types and tolerate LESS than libopenjpeg/grok.
Typical libs decode permissively (silently paper over corruption); jp2z's
value in `validate` is to FLAG every spec deviation as a finding. The decode
(M3-M6) gives byte-exact correctness; this layer turns the decoder into a
strict validator. Thread a FindingsSink through tier-2 + tier-1 + dequant +
DWT and emit on:
Note: strictness comes from DETERMINISTIC integrity checks (independent of
the 9/7 float tolerance), so it is exact even on the lossy path.
