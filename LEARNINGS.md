---
purpose: Environment/tooling learnings discovered while working on jp2z
audience: agent
maintained_by: agent
---

# Learnings

## nix flake `./test` only sees git-tracked files (2026-06-21)

`./test` runs `nix build .#checks.<system>.test`, whose source is the
flake source (`src = ./.`). nix flakes resolve that from the **git**
working tree and **exclude untracked files**. So a newly created
fixture referenced via `@embedFile` (e.g. a new
`tests/unit/fixtures/oracles/*.t1.bin`) fails to compile in the
sandbox with `error: unable to open '<path>': FileNotFound`, even
though `nix develop -c zig build test` (which reads the real working
dir) builds fine.

Fix: make the file visible to git before `./test`. Under the **jj-only**
policy you cannot `git add` (the file is staged only by jj's snapshot,
and raw `git` is hook-blocked) — the reliable way is to **commit it**
(`jj describe` / advance `yolo`), which writes it into a git tree the
flake reads. A pure-git workflow could `git add` it without committing;
jj has no separate staging step, so just commit.

Symptom to recognize: `zig build test` (devshell) passes but `./test`
(nix) fails with `FileNotFound` on a path that exists on disk → the
path is untracked.

## Zig 0.16: non-test executables need their own `Io` context (2026-06-30)

Tests use `std.testing.io`, but that symbol is `@compileError` outside
`builtin.is_test`. A non-test exe doing file I/O must build its own context:

    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

Then file ops take that `io`: `std.Io.Dir.openFileAbsolute(io, path, .{})`,
`file.reader(io, &.{}).interface.allocRemaining(alloc, .limited(n))`. The gpa
passed to `.init` must be threadsafe but is only touched by `Io.async` (which
plain file reads never call) — `page_allocator` is fine.

Also removed in 0.16 (all bit `tools/sweep_one.zig` during the sweep-harness
port): `std.process.argsAlloc` (read args/env via `std.c.getenv` + `std.mem.span`
with link_libc, exactly like `tests/unit/decode.zig` reads OPENJPEG_DATA), and
`std.io.getStdOut` / `std.io.fixedBufferStream` (route simple output through
`std.debug.print`, which writes stderr — have the consumer grep for it).

## codescan edits: line hashes recompute on EVERY edit (2026-06-30)

`codescan replace-lines --from <line:hash>` validates the target by hashline,
but a single edit anywhere in the file **re-salts every line's hash** (not just
changed lines). So you cannot pre-fetch a batch of `line:hash` pairs and chain
`replace-lines` calls — the second call fails "hashline mismatch". Two working
patterns for multi-site mechanical edits in one file:
  - Prefer **`replace-content '<needle>'`** (content-addressed, needs only
    `--version`, not per-line hashes). Chain by capturing the new `version:`
    from each call's output. Use `--all` for intended duplicates.
  - `replace-symbol <name>` for whole-function swaps (also `--version`).
Both `replace-lines` and `replace-content`/`replace-symbol` REQUIRE `--version`
(re-fetch after every edit). `replace-content` takes the replacement on **stdin**
(`printf '%s' "$repl" | codescan replace-content ...`) — omitting stdin deletes
the match.

## Decoder debugging: constant-DC tile output ⇒ tier-2 desync, not the DWT (2026-07-19)

When a decoded tile comes out a FLAT constant equal to the DC level shift
(`2^(prec-1)`, e.g. 128 for 8-bit), its coefficient buffer is ALL ZERO before
the level shift — so the inverse DWT is almost never the culprit (a wrong DWT
would spread nonzero energy, not erase it). Trace UP the pipeline instead:
plans present? → coeffs nonzero after tier-1? → pre-DWT buffer energy? The
fast instrument chain that cracked b1: (1) per-tile `sum|buf|` after
reconstruct, (2) per-plan `coeff_e` after tier-1 decode, (3) which resolutions
the packet iterator actually *yields*. Zero coeff energy from plans that have
real `numbps`/`data` ⇒ the DATA is wrong ⇒ a tier-2 packet-byte desync, which
localises per-tile because tiles parse independently.

Root-cause pattern worth remembering: **geometry helpers that hardcode tile
origin `(0,0)` are LATENT** — origin-0 and the real origin give the same
precinct/cblk COUNT for any tile big enough that no resolution collapses to
zero extent. Only a degenerate small/clipped edge tile (b1 col0 is 3px wide at
abs X=3097 → coarse resolutions have zero width) exposes the divergence. Grep
for `numPrecincts(0, 0` / `precinctIndexAt(0, 0` / any `subbandX(0, 0, …)` when
a multi-tile fixture with non-zero image/tile origin decodes wrong.

## Multi-tile 9/7 renders with per-tile magnitude inflation — PARKED (2026-07-23)

**Status: off the 1.0 critical path** (Einstein/Peter reprioritization: jp2z is
a *validator*, not a renderer — decoder polish that doesn't change validity
decisions is deprioritized). Deep-investigated then parked. `p1_04.j2k`
(1024×1024, 128×128 tiles = 64 tiles, 12-bit mono, 9/7 lossy) is the **only
multi-tile 9/7 fixture** — p0_04 (640×480) and p0_09 (17×37) are both
*single-tile* despite their tile-size declarations, so this path was untested.

**Symptom:** tile 0 (canvas origin) reconstructs perfectly; non-origin tiles get
a per-tile DC offset (~±900 on 12-bit) + AC distortion. jz vs the ISO reference
PGX (`c1p1_04_0.pgx`): PAE=954 (limit 624). openjpeg vs same ref: PAE=253 — so
the **reference is valid and jz is the outlier**.

**Ruled out with hard evidence** (do not re-chase these):
- *Integer vs IEEE754*: built a full f32 DWT mirror → PAE identical (954). Not
  fixed-point. (Peter's "avoiding IEEE754 causes divergence" hypothesis: FALSE.)
- *Tier-2*: hand-decoded the res-1 packet-header bits — zbp, coding-passes,
  length all match jz exactly. Packet walk is correct.
- *Mb / expn / guard*: raw QCD decode gives Mb=11,10,9 = jz's values.
- *Dequant scale_q*: = openjpeg's `0.5·stepsize` to the bit (2.413 for r1 HL).
- *Mallat placement*: all 10 subbands land in the right quadrants (tile-local
  base_x/base_y, origin-independent via `prev.width`).
- *idwt97 origin-independence*: empirical test — same buffer through idwt97 at
  tile_x0=0 vs 256 gives **byte-identical** output.

**The paradox (unresolved):** jz's per-coefficient magnitude reads exactly
2^half_bit_pos larger than openjpeg's dumped `t1->data` (jz stores magnitudes at
absolute bitplane positions; openjpeg's dumped value is compacted). openjpeg's
**decode** path applies no `T1_NMSEDEC_FRACBITS` shift (that's encode-only) and
dequants `datap * 0.5·stepsize` directly — implying jz's multi-tile buffer is 4×
too large for *truncated* code-blocks. BUT shifting jz's coefficient down by
half_bit_pos made p1_04 *worse* (954→2550) AND broke the passing single-tile
p0_04/p0_09 — proving jz's absolute-scale buffer is what its dequant correctly
expects. So "buffer is 4× openjpeg's dumped value" and "buffer is correct"
are both true, which means openjpeg applies its 2^hbp scaling somewhere between
the `t1->data` dump point (end of `opj_t1_decode_cblk`) and the DWT input that I
never located.

**Decisive next experiment (if ever resumed):** patch openjpeg to dump the
*post-dequant* tile-component buffer (the actual float coefficients fed to the
inverse DWT, in `opj_t1_clbl_decode_processor` after the `datap * 0.5·stepsize`
loop) and diff byte-for-byte against jz's dequantized buffer for tile 18. That
bypasses all representation ambiguity and pinpoints the divergence, or forces
the bug into the compositing stage.

The `openjpeg-cblk-dump.patch` dumps `t1->data` *inside* `opj_t1_decode_cblk`
(pre-dequant) — that is NOT the value the DWT sees. Also: openjpeg's post-T1
`cblk->numbps`/`cblk->Mb` are *significance* values (max decoded bitplane), NOT
the tier-2 `band->numbps - zbp` — do not compare jz's tier-2 numbps to them.

### Closure update (2026-07-23, decoded_data dump)

Two findings that close the loop enough to pivot:
1. **The 4× is real, not a buffer artifact.** The openjpeg dump was reading
   `t1->data` (scratch, restored to `original_t1_data` before the dump). Re-ran
   dumping `cblk->decoded_data ? cblk->decoded_data : t1->data` — the buffer the
   dequant actually consumes (`datap * 0.5·stepsize`, no bpno shift) — and it
   STILL shows the compacted value (`3 -7` for tile-18 r1 HL). So jz genuinely
   decodes `12` (absolute bitplane scale) where openjpeg's DWT input is `3`.
2. **The multi-tile 9/7 refactor was never committed.** HEAD calls
   `idwt97(buf, tile_w, 0, 0, …)` — the single-tile path. The 954-PAE
   investigation ran on uncommitted refactor code. So p1_04 multi-tile *decode*
   is currently unimplemented in HEAD (fine for the validator mission: tier-2
   packet-walk multi-tile correctness — the b1/b3 fixes — IS committed and is
   what corruption detection needs; pixel reconstruction is not).

Remaining paradox for a future resume: shifting jz's coefficient to the
compacted value made single-tile p0_04/p0_09 *worse*, implying openjpeg's
single-tile decode feeds the DWT an absolute-scale buffer while its multi-tile
path feeds a compacted one — likely a `decoded_data` (partial/multi) vs
`t1->data` (full single-tile) distinction. Confirm by dumping openjpeg's
POST-dequant float for a single-tile fixture and comparing to the multi-tile
case. Decoder-rendering only — off the 1.0 validation critical path.

## POC + interior-tile positional iteration: the e1_colr dig (2026-07-31)

Three lessons from converting e1_colr's strict REJECT into an ACCEPT:

1. **JP2Z_DUMP_T2 is the tier-2 differential oracle.** The openjpeg patch
   (`patches/openjpeg-cblk-dump.patch`) now also instruments
   `opj_t2_decode_packets`: with `JP2Z_DUMP_T2` set, every packet prints
   `jp2zT2 tile=T pino=P lL rR cC pP @offset` to stderr (offset is into the
   tile's CONCATENATED tile-part bodies). Diffing that against a walker-side
   trace pinned a 504-packet divergence to exactly 3 packets in minutes,
   after static analysis of pi.c had matched my sequencer on every axis.
   Use `nix develop -c opj_decompress` (devShell openjpeg = patched build).

2. **"Byte-perfect on all fixtures" only covers the geometry the fixtures
   exercise.** The positional iterators (RPCL/PCRL/CPRL) were byte-perfect —
   on single-tile origin-(0,0) streams, where tile-local == absolute
   coordinates and `x += stride` == next-multiple stepping. e1's tile 1
   (origin 80,1, PCRL via POC) broke all three latent assumptions at once:
   absolute-grid iteration span, next-multiple stepping (80→96→128, not
   80→112→144), and openjpeg's tile-edge emission special case (an interior
   tile owns a partial first precinct when its r-level origin is unaligned).
   The in-code NOTE in `precinctIndexAt` had predicted exactly this. When a
   NOTE says "revisit with a failing fixture," the fixture eventually shows.

3. **The jp2z CLI is NOT the cleanroom.** `jp2z_decode` (FFI/CLI) still
   routes through the openjpeg wrapper (Phase 1), so CLI-vs-opj_decompress
   byte-equality proves nothing about `decodeCleanroom`. Only the sweep
   (`tools/sweep_one.zig`) and inline tests exercise the cleanroom. (Cost me
   one false "byte-identical!" conclusion this session.)

Residual parked: e1 tile 7 (bottom-right, both-clipped) renders ±1/±2 on
~63% of samples — pre-existing, masked by tile 1's old 252, zero effect on
byte-budget validation. Chase it with the p1_04 multi-tile rendering block;
the T1 dump patch hardcodes tile 0 and needs extending first.

## The multi-tile 9/7 "paradox" was per-tile QCD all along (2026-07-31, RESOLVED)

The parked investigation above ("per-tile magnitude inflation", "4x =
2^half_bp") is closed, and the answer embarrasses both prior sessions: p1_04
carries a QCD marker in 63 of its 64 tile-part headers, each overriding the
main header's quantization for that tile. jz ignored them silently (QCD was
not even in the tile-header c145 flag set), so every non-origin tile was
dequantized against the wrong (expn, mant) table AND had the wrong Mb for
pass budgets. Everything observed follows:

- "tile 0 reconstructs perfectly, non-origin tiles get DC offset + AC
  distortion": tile 0 is the ONE tile without an override.
- the "4x = 2^2" magnitude ratio on tile 18: an expn delta between that
  tile's QCD and the main header's — a stepsize difference, not a
  coefficient-representation difference. The "compacted vs absolute
  bitplane" framing was a red herring; both decoders' t1 buffers were fine.
- the c253 REJECT: tile 7's own LL expn=9 makes Mb=10 → numbps=7 → 19
  passes legal; the main header's expn=8 made jz think the cap was 16.
- shifting coefficients made single-tile fixtures worse: of course — the
  bug was never in the coefficient scale.

Diagnostic lesson: when a per-tile-shaped error appears (clean origin tile,
corrupt interiors), scan the TILE-PART HEADERS for override markers before
theorizing about DWT/fixed-point/compositing. `opj_dump` does not list
tile-part-header markers; a 10-line awk over `od` output does (see the
session's SOT/QCD scan). The decisive-experiment recipe above (post-dequant
float dump) was never needed.

Status after the fix: p1_04 sweep NEAR max_abs=1 (9/7 lossy tolerance),
strict deep-validate ACCEPT, valid-set false-positive REJECTs now ZERO.
Still open in this family: e1_colr tile-7 +-1/2 rendering residual (5/3
path, unrelated to QCD — e1's tile headers carry only POC).

## 2026-08-13 — the balloon 252 false positive: "the right code never ran"

The `entropy_under_read` FAIL on validate's known-good balloon_eciRGB_icc.jp2
(real encoder: 12 tiles, 8 layers, RPCL, SEGSYM) was neither of the reporter's
two hypotheses (accounting formula wrong / severity policy wrong). The per-cblk
`last_contribution_length` reset existed, was correct, and was UNIT-TESTED —
but it lived inside `readCodeBlockContribution`, and `readPacketHeader`'s
EMPTY-packet early return (T.800 B.10.3 leading flag bit 0) bypassed it
entirely. jpegz named the category well: "the logic is wrong" and "the policy
is wrong" do not exhaust the space; "the right code never ran" is its own kind.

Corollaries proven by this bug:
- A tested invariant is only as good as the set of control-flow paths that
  reach its enforcement point. The reset's test pulled it through the per-cblk
  reader; no test pulled the empty-packet path against stale state.
- Two true signals can mask one lie: every tile reported walked_to_end (the
  walk advances by the header's true length) while the extractor's plans
  rotted (it advances by per-cblk stale lengths). When two subsystems consume
  the same stream by different bookkeeping, their AGREEMENT is the invariant
  to test — here, plan.data.len == sum(segments.byte_len) would have caught
  it years early. That check is cheap and now implicitly enforced by the
  balloon must-accept control.
- The diagnostic tell was an internal inconsistency, not the finding itself:
  buffers holding MORE bytes than their declared segment budgets (995 vs 881)
  with residues of 75-698 bytes — far outside any legal MQ-flush explanation
  (post-fix max residue: 1 byte). Magnitude histograms beat verdicts.
- Synthetic small-dimension valid corpora cannot represent "empty packet"
  layouts: single-layer fixtures never emit one. One real-encoder multi-layer
  file was worth 14 synthetics on the must-accept side.

## 2026-09-06 — PPM/PPT: the "decode bug cluster" was a validation hole

The sweep's 127/128 max_abs cluster (g2/g3/g4, p1_05/p1_06) read like one
sign or DC-shift bug on a specific path. It was nothing of the kind: every
fixture in it (plus g1 and p1_02 at 254/255) carries packed packet headers
(PPM in the main header, PPT in tile-part headers, T.800 A.7.4/A.7.5), and
the walker had never implemented either. PPM sat in the "known main-header
marker" set, so its body was skipped WITHOUT a c145 unsupported finding;
the packet walk then parsed packet BODIES as headers, desynced, and the
decode came out as flat mid-grey (exactly half-range: DC shift of nothing).

What generalises:
- Diagnose a decode-divergence cluster by fixture FEATURE first, pixel
  symptom second. One 40-line marker census (which fixtures carry which
  markers) reclassified a "decode correctness" item into a "validation
  coverage" item and merged two PLAN slices into one.
- A silently-skipped marker is worse than an unsupported-marker finding: the
  finding would have named the gap on day one. Every marker the walker
  recognises but does not apply must emit c145 (COC/QCC/RGN do; PPM did not).
- Read the oracle's merge semantics before designing the store: openjpeg
  concatenates PPM segments in Zppm order and then splits Nppm chunks over
  the concatenation (a chunk may straddle segments; g3 spreads 3 KB over 214
  segments). It then consumes headers sequentially with no per-tile-part
  boundary check. The spec's Nppm-per-tile-part rule is a catchable
  invariant openjpeg ignores, so jp2z checks it (c256 packed_headers_mismatch:
  leftover bytes at tile-part end, or a store that runs dry with bodies
  remaining). Strictness lives where the spec is stricter than the reference.
- The one ambiguity is honest: a store short by whole packets with an empty
  body is indistinguishable mid-walk from "more tile-parts follow", so that
  verdict lands at EOC via the existing incomplete-tile finding. The test
  says so rather than pretending c256 covers it.
- `packed` is a Zig keyword. A parameter named `packed` fails to parse with
  "expected a struct, enum or union, found ':'" — an error message that
  points nowhere near the cause.

## 2026-09-06 — 9/7 at odd tile origins: the "cas==0 only" comment was a bug report

Once packed headers walked, p1_06 (12×12, 3×3 tiles, 5 resolutions) went
from flat grey to a ReleaseSafe panic in `idwt97Line`: `integer overflow`
in the β step. The line routine's own doc comment said "cas==0 only
(single-tile origin (0,0))", and `idwt97` had been passing real `cas`
values into it since the multi-tile branch landed. Two defects hid there:
- cas==1 swaps the roles (low samples at ODD interleaved positions) but
  the lifting still indexed `tmp[2i]` as low, so interior tiles were
  transformed with the wrong neighbours (p1_05: max_abs 255).
- Degenerate lines (sn=0,dn=1 at odd origin; sn=1,dn=0 at even) hit
  `bound - 1` with bound 0 in the edge-clamp helpers: a usize underflow
  panic in ReleaseSafe, an out-of-bounds read in ReleaseFast. Tiny tiles
  with many resolution levels make these lines routine, not exotic.

What generalises:
- A "only handles X" comment on a function that receives non-X inputs is a
  latent crash, not documentation. Grep call sites when you see one.
- openjpeg's one-sample rules are NOT the literal spec: T.800 F.3.7 says an
  odd-origin single sample is halved; opj_v8dwt_decode returns it untouched
  (and skips the K scale on the even-origin one). jp2z mirrors the oracle
  and says so in the comment; a second oracle (Kakadu .pix) could revisit.
  The pre-existing test asserting "single low sample passes K scale"
  encoded the bug — it disagreed with BOTH the spec and the oracle.
- Reflection is a free metamorphic oracle for parity: for even lengths,
  idwt(cas=1, L, H) == reverse(idwt(cas=0, reverse(L), reverse(H))) holds
  exactly in Q16 because every lifting step is a position-independent
  neighbour update. It pinned the cas==1 branch without a forward 9/7.

## 2026-09-06 — p1_05's "diffuse small error" was tier-1, found by ruling stages out

max_abs 18 across 198 of 225 tiles, all components, no spatial structure.
Two hypotheses tested and rejected in minutes each: exact (single-rounding)
dequantisation changed 198→196 tiles; the 9/7 line was already proven by
the reflection test. What settled it was a stage-attribution tool, not more
thinking: `zig build tile-hist` with JP2Z_DUMP_T1 compares every code-block's
T1 output against the patched-openjpeg dump, so a divergence is either
"tier-1 differs" or "tier-1 matches, look downstream". It differed: 2235
code-blocks, each off only in the reconstruction half-bit, each with a pass
count ≡ 2 (mod 3) — decoding stopped right after a significance pass.

The bug: jp2z placed the "+0.5 of last bin" half-bit at ONE position per
code-block, derived from the pass count. openjpeg keeps it per coefficient
(set at significance, moved down by every refinement), which only agrees
when the last pass is a cleanup pass. Stop after SP or MR and the
coefficients that partial plane never visited keep their half one plane
higher. Every earlier fixture happened to end on cleanup passes; p1_05's
two layers and balloon's eight did not (balloon 9→0, e1's ±2 turned out to
be the unrelated RGN case).

What generalises:
- When a divergence is diffuse and small, attribute it to a STAGE before
  hypothesising a cause. The T1 differential took 10 minutes to build and
  answered in one run what two experiments could not.
- The mod-3 pattern in the pass counts was the fingerprint. Histogram the
  metadata of the failing set (pass counts, cbsty, sizes) before reading
  code; a shared residue class points straight at the schedule.
- The oracle dump patch hardcodes tile 0 and records absolute band
  coordinates; jp2z plans are tile-relative. Multi-tile matching needs the
  B-15 band-origin translation (now `subbands.bandOrigin`), not a patch
  fix — the vendored single-tile dumps stay valid.

## 2026-09-06 — two false positives on valid ISO files, both "the table was sized too early"

p0_01 (QCD before COD) tripped a strict c255; p0_13 (257 components)
tripped jp2_invalid_siz. Neither file is corrupt. Both came from the same
shape of mistake: a per-item table sized from a value another marker
supplies, checked or filled at the wrong moment.
- The M_b table was filled while parsing QCD, using COD's decomposition
  count — zero when QCD comes first. Fix: hold a QCD seen before COD and
  parse it once COD lands (or at the end of the main header).
- The component descriptor arrays hold 16, so Csiz>16 was declared invalid.
  T.800 allows 16384. Fix: accept, read the tail through slot 15 when its
  descriptors repeat slot 15's, flag c145 when they do not; the decoder
  refuses >16 explicitly rather than indexing past its scratch arrays.
Both were found by the same instrument (tile-hist prints the strict
findings before the pixel diff), and both are now must-accept controls.
Any "invalid" verdict that comes from an implementation limit rather than
the spec is a false positive waiting for a conformance file; grep for
array lengths in validation branches.

## 2026-09-06 — a wrong attribution, caught by the test that was supposed to lean on it

I wrote "e1's ±2 residual is its RGN tile" into a commit message and PLAN.
It was false: the evidence was `od | grep -c ff5e` over the whole file,
which counts any two bytes that happen to be FF 5E, not RGN marker
segments. e1 has no RGN. The mistake surfaced only when the C smoke test's
"c145 must be non-vacuous" invariant was re-pointed at e1 and failed —
the marker census tool (which walks segments) had been available the
whole time and said so. Two rules:
- Count markers with a segment walker, never with a byte grep. FF xx
  appears inside entropy data constantly.
- Before writing an attribution into a commit or PLAN, re-run the tool
  that produces it; a claim about a fixture must come from a segment walk,
  a T1 diff, or a sweep record — never from an inference chain.

The real cause was smaller and more general: a packet may include a
code-block with N new passes and ZERO bytes (B.10.7), and the extractor
skipped every zero-length slice — so those passes never reached the plan.
openjpeg runs them over the exhausted stream (extra low bits); the
validator's pass budget was under-counted. Keep "included this packet"
(passes) separate from "bytes this packet" in the code-block state.

Tooling note: perl `s|...|...|` with `|` as the delimiter turns every
escaped `\|` in the pattern into an ALTERNATION once the delimiter is
stripped. Two files were mangled that way today (`|*b|` captures). Use a
delimiter that cannot occur in Zig (`s#...#...#` is not safe either — Zig
has none that is universally absent), or use the exact-match Edit tool for
anything containing `|`.

## 2026-09-06 — "unsupported" reached zero across the ISO controls, and what that cost

Applying tile-part COD (A.6.1) closed the last c145 on the vendored ISO
set: p0_04 (QCC), f1_mono (tile COD), and every packed-header file now
walk with the parameters the stream actually declares. f1 is the
instructive one — its tile 4 declares 7 layers against the main header's
4, so three layers of packets were never walked, and the validator
reported a clean file with a WARN-level under-read. An ignored override
does not only mis-decode; it silently shrinks the surface the validator
checks. The rule for the remaining ones (COC, RGN): a marker in the
c145 set is a hole in coverage, not a footnote.

Mechanics worth keeping: parse-into-any-params (parseCodInto/parseQcdInto/
parseQccBody) with the tile's copy as the target, applied in dependency
order (COD first, then QCD, then QCC), and a per-tile "broken" ledger so an
unwalkable tile COD cannot let a later tile-part build a walk over the main
header's geometry.

## 2026-09-06 — COC/RGN: ten false positives, one census, and a cap that was never derived

Every ISO fixture carrying COC or RGN (ten of 57) failed strict validation.
The markers were "surfaced but ignored" (c145), which sounds safe and was
not: a component walked with the main header's decomposition count and
component 0's tile rect desyncs its packets, and a ROI shift the pass
budget does not know about turns a valid 25-pass code-block into a c253.
Applying them meant threading (component, resolution) through the packet
iterator, the POC sequencer's canonical index, the tile-walk slot pool and
the extractor, and giving each component its OWN sub-sampled tile rect —
p1_07's 4:1 component had been laid out on component 0's grid.

Three things fell out of the same fixtures that were not COC/RGN at all:
- p0_02 puts a reserved marker (FF30) after its COM. T.800 Table A.2 says
  FF30..FF3F have no segment; every jp2z walker (and my own marker census
  script) read the next two bytes as a length. One conformance file exists
  to test exactly this.
- p0_08's QCC lengths differ per component. Sizing a quantization table by
  the main COD's decomposition count was the QCD-before-COD bug in a new
  coat; the fix is body-driven parsing plus a coverage check once every
  COD/COC is known, which also retired the marker-order queue.
- The MQ over-read cap of 4 had a derivation ("register lookahead") that
  two conformant encoders falsify (p0_08 over-reads 10, file6 8, tier-1
  byte-identical to openjpeg). T.800 allows codeword truncation with 0xFF
  fill, so no hard bound exists without PTERM. The honest cap is
  corpus-calibrated: a census over all 57 files, the cap at the observed
  maximum plus a margin, and the per-fixture matrix dump proving the
  previous 17 controls kept every detection. A bound with a story is not a
  bound; a bound with a census is.

The census itself is the result to keep: tier-1 output is now byte-perfect
against openjpeg on all 57 ISO conformance fixtures, oracle dumps included
for the COC/RGN/ROI cases so it stays that way.

Process notes, again: two files were mangled by perl `s|...|...|` on text
containing `|` capture syntax — the exact failure LEARNINGS already
recorded this morning. The rule is now absolute: any edit whose text
contains `|` goes through the exact-match Edit tool, never a regex.

## 2026-09-06 — a severity policy, written down

The audit of "fields the walker reads but never judges" needed one rule to
stop each case being argued separately:
- A value that makes the stream UNDECODABLE is FAIL: an undefined
  progression order, MCT, wavelet id or quantization style; a precision
  past 38 bits; more than 65535 tiles; a CRG whose length is not 4·Csiz.
  Nothing downstream can proceed correctly, and a flipped byte producing
  such a value is exactly the corruption the validator exists to catch.
- A RESERVED value the decoder can ignore is WARN: Rsiz outside the
  defined profiles, COM Rcom > 1, TLM Stlm reserved bits. Surfaced, never
  blocking — a future amendment may define them.
- A DEFINED feature jp2z does not implement is c145 (unsupported-valid):
  Rsiz Part-2 / HTJ2K capability bits join COC-past-slot-16 and the
  non-uniform Csiz tail there.
And one deliberate omission, recorded so it is not "found" again: POC
REpoc/CEpoc may legally exceed the real resolution/component counts
(B.12.1.3 clamps them), so no bounds check is added for them.
