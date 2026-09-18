# corruption-probe coverage of jp2z strict validation

First run: 2026-09-16, jp2z at the commit that adds the `validate` verb.
Tool: sibling `corruption_probe` (`bin/corruption-probe`, mutation v1,
BLAKE3-XOF DRBG at seed 0x1234), an oracle jp2z's author did not write.
Validator command: `jp2z validate --strict {file}` with `--exit-map
2=warning`; a pristine copy must exit 0 first (all 27 fixtures do).
Per fixture: 100 rounds each of sniper (one bit), bolter (one byte XOR
0xFF), shotgun (a random window of min(4096, size/8) bytes, floor 64) and
truncation. Reports, per-trial events and run logs live under
`conformance/probe/<fixture>/`; the region breakdown below comes from the
events and the file's own marker map (scratch `probe_regions.lua`,
reproducible from the events file).

## What the numbers mean

"Rejected" means jp2z returned FAIL or WARN on the mutated copy. A
mutation that is accepted is not automatically a validator defect: JPEG
2000 carries no checksum, so some byte changes leave a codestream that is
fully self-consistent. The survivors were classified by hand into:

1. **Comment bodies** (COM text, ICC profile bytes, palette entries): the
   change is undetectable and harmless. p1_04's tile-part 29 carries a
   65 KB COM segment, which is why its raw rates were the lowest in the
   set; the table excludes comment bytes from the sniper/bolter
   denominators and lists those survivors separately.
2. **Semantically equivalent encodings**: a packed packet header whose
   "non-empty packet, no inclusions" bit becomes "empty packet" parses
   identically (g3/g4 PPM/PPT survivors); an XTsiz/YTsiz larger than the
   image still means one tile; a progression order change on a one-layer,
   one-component stream reorders nothing. Undetectable and harmless.
3. **Self-consistent field changes that alter the decoded image**: a SIZ
   precision or sub-sampling factor, a QCD exponent on an irreversible
   (9/7) stream, a POC volume that still sequences validly. No redundant
   information exists to detect these in a raw codestream. A JP2 wrapper
   adds one cross-check (ihdr BPC versus Ssiz, now enforced). For
   reversible (5/3) streams Annex E ties the QCD exponents to precision
   and band gain; whether that relation is normative is being confirmed
   against the text before it becomes a check (candidate).
4. **Entropy-data flips within the MQ over-read cap**: the byte-budget
   check tolerates up to 12 bytes of over-read on non-PTERM code-blocks
   (corpus-calibrated: p0_08 needs 10). Flips that move consumption by
   less than that survive. Files coded with SEGSYM/PTERM (c2_mono,
   pterm_test, p0_02, p1_01, p1_06) detect more. This is the genuine
   ceiling of a checksum-less format, and the cap is the trade against
   false positives on valid encoders.
5. **Real gaps.** One found in this run: an inflated Xsiz/Ysiz (p0_09,
   p0_10, pterm_test, p1_07) declared more tiles than the codestream
   delivered and validation said nothing. jp2z now reports "N of M tiles
   in the SIZ grid have no tile-part" (B.3 / A.4.2) with a regression and
   a full-grid control. The ISO conformance codestream b2_mono.j2c omits
   9 of its 25 tiles and both reference decoders accept it; the spec
   explains why: its component is sub-sampled 5×3 and every omitted tile
   has an empty tile-component rect (B.3), hence no precincts (B.6) and
   no packets. So the rule is: an absent tile that would carry samples in
   any component is a FAIL; an absent tile empty in every component is
   clean. b2_mono passes, the inflated-grid mutants fail.

Shotgun and truncation are rejected 100% on every fixture except p1_04's
shotgun, where 57 of 100 windows fell inside the comment segment.

## Results (seed 0x1234, 100 rounds per mode; one run, 2026-09-16 evening)

Every fixture was probed with the validator as of commit 449eb1d (profile
checks, absent-tile rule, PTERM over-read cap 3, no 16-component ceiling).
The first run of the day (before those changes) is in git history under
`conformance/probe/`; the same seed makes the two runs pair trial by
trial, and every flip between them is accounted for below the table.
Shotgun windows are min(4096, size/8) bytes, floor 64.

| Fixture | Rsiz | Bytes | Sniper rejected (non-comment) | Bolter rejected (non-comment) | Shotgun rejected | Truncation rejected | Sniper survivors: header / packet / comment | Bolter survivors: header / packet / comment |
|---|---|---:|---:|---:|---:|---:|---|---|
| a1_mono | 0x0000 | 33588 | 99/100 (99%) | 97/100 (97%) | 100/100 (100%) | 100/100 (100%) | 0/0 / 1/100 / - | 0/1 / 3/99 / - |
| a5_mono | 0x0000 | 34747 | 99/100 (99%) | 93/99 (94%) | 100/100 (100%) | 100/100 (100%) | 0/0 / 1/100 / - | 0/0 / 6/99 / 1/1 |
| b1_mono | 0x0000 | 34848 | 90/99 (91%) | 95/100 (95%) | 100/100 (100%) | 100/100 (100%) | 0/1 / 9/98 / 1/1 | 0/0 / 5/100 / - |
| balloon_eciRGB_icc | 0x0000 | 1864443 | 92/100 (92%) | 98/100 (98%) | 100/100 (100%) | 100/100 (100%) | 0/0 / 8/100 / - | 1/1 / 1/99 / - |
| c1_mono | 0x0000 | 33608 | 47/100 (47%) | 49/100 (49%) | 100/100 (100%) | 100/100 (100%) | 0/0 / 53/100 / - | 0/1 / 51/99 / - |
| c2_mono | 0x0000 | 34208 | 53/100 (53%) | 55/100 (55%) | 100/100 (100%) | 100/100 (100%) | 0/0 / 47/100 / - | 0/0 / 45/100 / - |
| d1_colr | 0x0000 | 60080 | 96/100 (96%) | 92/100 (92%) | 100/100 (100%) | 100/100 (100%) | 0/0 / 4/100 / - | 0/0 / 8/100 / - |
| d2_colr | 0x0000 | 67797 | 71/100 (71%) | 75/100 (75%) | 100/100 (100%) | 100/100 (100%) | 0/0 / 29/100 / - | 0/0 / 25/100 / - |
| e1_colr | 0x0000 | 67792 | 68/100 (68%) | 71/100 (71%) | 100/100 (100%) | 100/100 (100%) | 0/0 / 32/100 / - | 0/0 / 29/100 / - |
| f1_mono | 0x0000 | 35107 | 88/100 (88%) | 86/100 (86%) | 100/100 (100%) | 100/100 (100%) | 0/1 / 12/99 / - | 0/1 / 14/99 / - |
| g3_colr | 0x0000 | 67333 | 83/100 (83%) | 85/100 (85%) | 100/100 (100%) | 100/100 (100%) | 1/10 / 16/90 / - | 1/10 / 14/90 / - |
| g4_colr | 0x0000 | 67325 | 79/100 (79%) | 87/100 (87%) | 100/100 (100%) | 100/100 (100%) | 1/6 / 20/94 / - | 2/8 / 11/92 / - |
| p0_09 | 0x0000 | 594 | 44/97 (45%) | 43/100 (43%) | 100/100 (100%) | 100/100 (100%) | 3/19 / 50/78 / 3/3 | 10/21 / 47/79 / - |
| pterm_test | 0x0000 | 530 | 72/94 (77%) | 75/95 (79%) | 100/100 (100%) | 100/100 (100%) | 3/16 / 19/77 / 6/6 | 4/16 / 16/77 / 5/5 |
| file1 | 0x0001 | 650678 | 97/100 (97%) | 97/100 (97%) | 100/100 (100%) | 100/100 (100%) | 0/0 / 3/100 / - | 1/1 / 2/99 / - |
| file9 | 0x0001 | 300208 | 99/100 (99%) | 99/100 (99%) | 100/100 (100%) | 100/100 (100%) | 0/0 / 1/100 / - | 1/1 / 0/99 / - |
| p0_01 | 0x0001 | 7390 | 92/100 (92%) | 92/100 (92%) | 100/100 (100%) | 100/100 (100%) | 0/0 / 8/100 / - | 1/1 / 7/99 / - |
| p0_02 | 0x0001 | 6183 | 90/100 (90%) | 92/100 (92%) | 100/100 (100%) | 100/100 (100%) | 1/1 / 9/99 / - | 0/2 / 8/98 / - |
| p0_03 | 0x0001 | 12845 | 86/99 (87%) | 89/99 (90%) | 100/100 (100%) | 100/100 (100%) | 0/2 / 13/97 / 1/1 | 0/3 / 10/96 / 1/1 |
| p0_04 | 0x0001 | 264635 | 92/100 (92%) | 94/100 (94%) | 100/100 (100%) | 100/100 (100%) | 0/1 / 8/99 / - | 0/0 / 6/100 / - |
| p0_10 | 0x0001 | 14131 | 78/100 (78%) | 85/100 (85%) | 100/100 (100%) | 100/100 (100%) | 0/1 / 22/99 / - | 0/1 / 15/99 / - |
| p0_13 | 0x0001 | 2486 | 51/98 (52%) | 78/100 (78%) | 100/100 (100%) | 100/100 (100%) | 8/30 / 39/68 / 2/2 | 3/47 / 19/53 / - |
| p0_06 | 0x0002 | 33826 | 92/100 (92%) | 92/100 (92%) | 100/100 (100%) | 100/100 (100%) | 0/0 / 8/100 / - | 0/2 / 8/98 / - |
| p1_01 | 0x0002 | 4761 | 82/97 (85%) | 92/100 (92%) | 100/100 (100%) | 100/100 (100%) | 0/1 / 15/96 / 3/3 | 0/1 / 8/99 / - |
| p1_04 | 0x0002 | 101844 | 28/41 (68%) | 26/39 (67%) | 43/100 (43%) | 100/100 (100%) | 2/3 / 11/38 / 59/59 | 2/4 / 11/35 / 61/61 |
| p1_06 | 0x0002 | 3356 | 93/97 (96%) | 96/99 (97%) | 100/100 (100%) | 100/100 (100%) | 3/44 / 1/53 / 3/3 | 2/45 / 1/54 / 1/1 |
| p1_07 | 0x0002 | 569 | 75/93 (81%) | 85/99 (86%) | 100/100 (100%) | 100/100 (100%) | 1/17 / 17/76 / 7/7 | 1/15 / 13/82 / 1/1 |

### Flips against the first run (per trial, same seed)

Seventeen fixtures did not change a single outcome. The rest:

- p0_13: 34 trials WARN to FAIL. A SIZ descriptor byte of a component
  past the 16th used to trip the "differs from the 16th" c145, an
  unsupported-feature notice rather than a detection. The same bytes now
  FAIL as Profile 0 violations (c259: sub-sampling 254 or 65 is not 1, 2
  or 4). 4 trials accepted to FAIL: Profile 0 sub-sampling on components
  below the 16th and the tile-grid rule (XTsiz). 7 trials WARN to
  accepted, all sniper flips in the Ssiz byte of one component past the
  16th (its precision or sign). Profile 0 sets no bit-depth bound below
  Table A.10's 38, so the stream stays self-consistent and decodes; the
  old WARN was the slot-15 artefact. Peter then retrieved the T.800
  clauses (docs/T800_REVERSIBLE_QUANTIZATION_VERBATIM.md): the exponent
  formula E-10 is informative and ISO files p0_10/file1/file9 exceed it,
  so the equality cannot be checked; the bit-plane budget it implies (Mb
  ≥ R_I + log2(gain) + RCT growth) can, as WARN 260. A third run of
  p0_13 at that validator (the row above, same seed) turns 4 of the 7
  into WARN 260 (flips to 16-bit or 24-bit) and leaves 3 (flips to 4, 6
  or 7 bits, which fit the budget). Those 3 are undetectable by any
  codestream cross-check: an encoder fed 7-bit data under an 8-bit
  declaration writes the same bytes. Sniper on p0_13 is 52%.
- p1_07: 2 trials accepted to FAIL (XTsiz/YTsiz bytes leaving most of the
  SIZ grid without a tile-part: the absent-tile rule).
- p0_09: 4 trials accepted to FAIL; p0_10: 1 (the same absent-tile and
  profile rules).
- pterm_test: 3 trials FAIL to accepted and p1_01: 1, all c251 over-reads
  of exactly 3 bytes on PTERM code-blocks (cblksty 0x10 and 0x34). The
  PTERM over-read cap was raised from 2 to 3 earlier in the day because
  the ISO conformance codestream p1_05 has four blocks at 3 and openjpeg
  warns on the same four; a conformance file cannot FAIL. These four
  survivors are the price of that fix and are listed here rather than
  hidden in the rate. pterm_test also has 1 trial FAIL to WARN and p0_03
  1, both still rejections.

## Survivor labels from the oracle (2026-09-18)

An accepted trial is a probe the validator did not reject. Whether that
is a false negative was, until now, a judgement by region. `./probe-label`
(tools/probe_label.zig) replaces the judgement with an independent label:
each accepted sniper or bolter trial is replayed exactly (the events file
records mode, offset and bit) and the mutant is decoded by openjpeg, an
implementation jp2z's author did not write. A mutant that decodes to the
pristine pixels is **inert** (the byte carried no image information: a
comment, an unused field, a redundant encoding). One that decodes to
different pixels is **changed**: the corruption reached the image and
jp2z said nothing, a true false negative. **Wrapper refuses** counts
mutants the packed Image contract will not shape (mixed precision across
components); opj_decompress decodes them, so that column is a limit of
the Image type, not a detection. Shotgun and truncation trials carry
random windows the events do not record and cannot be replayed; the 57
unreplayable trials are p1_04's comment-window shotgun survivors and stay
labelled by region. Labels sit beside each report in
`conformance/probe/<fixture>/labels.ndjson`.

jp2z devShell — zig 0.16.0, openjpeg 2.5.4 (Phase 1 backend)
| Fixture | Accepted (sniper+bolter) | Inert | Changed (false negatives) | Wrapper refuses | Unreplayable (shotgun) |
|---|---:|---:|---:|---:|---:|
| a1_mono | 4 | 0 | 4 | 0 | 0 |
| a5_mono | 8 | 1 | 7 | 0 | 0 |
| b1_mono | 15 | 1 | 14 | 0 | 0 |
| balloon_eciRGB_icc | 10 | 3 | 7 | 0 | 0 |
| c1_mono | 104 | 1 | 103 | 0 | 0 |
| c2_mono | 92 | 0 | 92 | 0 | 0 |
| d1_colr | 12 | 0 | 12 | 0 | 0 |
| d2_colr | 54 | 3 | 51 | 0 | 0 |
| e1_colr | 61 | 2 | 59 | 0 | 0 |
| f1_mono | 26 | 0 | 26 | 0 | 0 |
| file1 | 6 | 1 | 5 | 0 | 0 |
| file9 | 2 | 0 | 2 | 0 | 0 |
| g3_colr | 32 | 2 | 30 | 0 | 0 |
| g4_colr | 34 | 4 | 30 | 0 | 0 |
| p0_01 | 16 | 1 | 15 | 0 | 0 |
| p0_02 | 18 | 2 | 16 | 0 | 0 |
| p0_03 | 25 | 5 | 20 | 0 | 0 |
| p0_04 | 14 | 0 | 14 | 0 | 0 |
| p0_06 | 16 | 1 | 15 | 0 | 0 |
| p0_09 | 113 | 45 | 68 | 0 | 0 |
| p0_10 | 37 | 0 | 37 | 0 | 0 |
| p0_13 | 71 | 27 | 40 | 4 | 0 |
| p1_01 | 26 | 8 | 18 | 0 | 0 |
| p1_04 | 146 | 120 | 26 | 0 | 57 |
| p1_06 | 11 | 7 | 4 | 0 | 0 |
| p1_07 | 40 | 16 | 24 | 0 | 0 |
| pterm_test | 53 | 16 | 37 | 0 | 0 |

Totals over the 27 fixtures: 1103 accepted sniper and bolter trials, of
which 266 inert (24%), 776 changed (70%), 4 wrapper refusals, 57
unreplayable. Against the 5245 non-comment sniper and bolter trials in
the results table, the 776 that corrupt the decoded image without a
finding are 14.8%. By region (scratch probe_regions.lua over the changed
trials only): 758 in packet data, 13 in the main header, 4 in tile-part
headers, 1 in a JP2 box. The 18 header bytes are 14 QCD step-size bytes
(an exponent or mantissa the decoder honours; a change that shrinks a
reversible budget is WARN 260, one that grows it or moves a 9/7 mantissa
has no invariant), the Ssiz sign bit of one component (p0_02 component
0, p0_13 component 55; a raw J2K carries nothing to cross-check it
against) and one pclr palette entry in file9. Packet-data bytes are the
checksum-less ceiling described under class 4 above.

The agreement column cross-tabulates cleanly: all 776 oracle-changed
mutants also change jp2z's own decode, all 266 inert ones leave it
pristine, and the 4 wrapper refusals are mixed-precision streams both
decoders' packed Image type declines. A surviving corruption is
therefore rendered the same way by jp2z and openjpeg; none is silently
normalised away by one and not the other.

Two fixtures dominate the false negatives: c1_mono and c2_mono (103 and
92 of 776), the ten-layer streams whose tiny per-layer contributions
leave most bytes free of any budget invariant. p0_09 and p1_04 carry the
most inert bytes (45 and 120), which is where their earlier low raw
rates came from.

## Honest summary

- Shotgun (whole-window garbage) and truncation: detected on every file,
  always, outside comment text.
- Single-bit and single-byte damage in packet data: detected between 47%
  (c1_mono, ten layers of tiny contributions, no SEGSYM/PTERM) and 99%
  (a1_mono, file9). The residue is class 4 above.
- Header damage outside comments: the accepted cases are classes 2, 3
  and the class-5 gap now closed. After the fix, the header survivors
  that remain are equivalent encodings or self-consistent field changes.
- Coverage by profile: fixtures exist only for Rsiz 0 (14), Profile 0
  (8) and Profile 1 (5). The Profile 0 and 1 rules (Table A.45) are
  validated and the probe exercises them (the p0_09/p0_10/p0_13/p1_07
  header catches above). The cinema, broadcast and IMF rules are
  implemented from Peter's transcribed tables and unit-tested on mini
  streams, but no such file is vendored, so no probe has run against one;
  their bitrate and level limits are reported as unverified (c145).

Rerunning is not implicit acceptance here: the seed is fixed, so a rerun
after a validator change is a paired comparison (`corruption-probe
compare`), and any accepted-to-rejected or rejected-to-accepted
transition must be explained.
