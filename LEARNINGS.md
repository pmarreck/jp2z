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
