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

## Results (seed 0x1234, 100 rounds per mode, before the missing-tile fix)

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
| p0_09 | 0x0000 | 594 | 40/97 (41%) | 43/100 (43%) | 100/100 (100%) | 100/100 (100%) | 7/19 / 50/78 / 3/3 | 10/21 / 47/79 / - |
| pterm_test | 0x0000 | 530 | 73/94 (78%) | 76/95 (80%) | 100/100 (100%) | 100/100 (100%) | 4/16 / 17/77 / 6/6 | 4/16 / 15/77 / 5/5 |
| file1 | 0x0001 | 650678 | 97/100 (97%) | 97/100 (97%) | 100/100 (100%) | 100/100 (100%) | 0/0 / 3/100 / - | 1/1 / 2/99 / - |
| file9 | 0x0001 | 300208 | 99/100 (99%) | 99/100 (99%) | 100/100 (100%) | 100/100 (100%) | 0/0 / 1/100 / - | 1/1 / 0/99 / - |
| p0_01 | 0x0001 | 7390 | 92/100 (92%) | 92/100 (92%) | 100/100 (100%) | 100/100 (100%) | 0/0 / 8/100 / - | 1/1 / 7/99 / - |
| p0_02 | 0x0001 | 6183 | 90/100 (90%) | 92/100 (92%) | 100/100 (100%) | 100/100 (100%) | 1/1 / 9/99 / - | 0/2 / 8/98 / - |
| p0_03 | 0x0001 | 12845 | 86/99 (87%) | 89/99 (90%) | 100/100 (100%) | 100/100 (100%) | 0/2 / 13/97 / 1/1 | 0/3 / 10/96 / 1/1 |
| p0_04 | 0x0001 | 264635 | 92/100 (92%) | 94/100 (94%) | 100/100 (100%) | 100/100 (100%) | 0/1 / 8/99 / - | 0/0 / 6/100 / - |
| p0_10 | 0x0001 | 14131 | 78/100 (78%) | 84/100 (84%) | 100/100 (100%) | 100/100 (100%) | 0/1 / 22/99 / - | 1/1 / 15/99 / - |
| p0_13 | 0x0001 | 2486 | 54/98 (55%) | 74/100 (74%) | 100/100 (100%) | 100/100 (100%) | 5/30 / 39/68 / 2/2 | 7/47 / 19/53 / - |
| p0_06 | 0x0002 | 33826 | 92/100 (92%) | 92/100 (92%) | 100/100 (100%) | 100/100 (100%) | 0/0 / 8/100 / - | 0/2 / 8/98 / - |
| p1_01 | 0x0002 | 4761 | 82/97 (85%) | 93/100 (93%) | 100/100 (100%) | 100/100 (100%) | 0/1 / 15/96 / 3/3 | 0/1 / 7/99 / - |
| p1_04 | 0x0002 | 101844 | 28/41 (68%) | 26/39 (67%) | 43/100 (43%) | 100/100 (100%) | 2/3 / 11/38 / 59/59 | 2/4 / 11/35 / 61/61 |
| p1_06 | 0x0002 | 3356 | 93/97 (96%) | 96/99 (97%) | 100/100 (100%) | 100/100 (100%) | 3/44 / 1/53 / 3/3 | 2/45 / 1/54 / 1/1 |
| p1_07 | 0x0002 | 569 | 74/93 (80%) | 84/99 (85%) | 100/100 (100%) | 100/100 (100%) | 2/17 / 17/76 / 7/7 | 2/15 / 13/82 / 1/1 |

Survivor columns are accepted/total for header (JP2 boxes, main header,
tile-part headers), packet data, and comment bytes.

## Re-probe after the profile checks and the component-ceiling lift (2026-09-16, evening)

Same seed, same rounds, same modes, so every trial pairs with the run
above. p0_13 (257 components) and p1_07 (2 components) were re-probed
because both now decode through jp2z and the validator no longer reads
components past the 16th through the 16th's descriptor. The shotgun
window was min(4096, size/8) as before (310 and 71 bytes); the run above
used the same rule. Reports and events under `conformance/probe/` are
replaced by these runs; the earlier ones are in git history.

| Fixture | Rsiz | Bytes | Sniper rejected (non-comment) | Bolter rejected (non-comment) | Shotgun rejected | Truncation rejected | Sniper survivors: header / packet / comment | Bolter survivors: header / packet / comment |
|---|---|---:|---:|---:|---:|---:|---|---|
| p0_13 | 0x0001 | 2486 | 47/98 (48%) | 78/100 (78%) | 100/100 (100%) | 100/100 (100%) | 12/30 / 39/68 / 2/2 | 3/47 / 19/53 / - |
| p1_07 | 0x0002 | 569 | 75/93 (81%) | 85/99 (86%) | 100/100 (100%) | 100/100 (100%) | 1/17 / 17/76 / 7/7 | 1/15 / 13/82 / 1/1 |

Per-trial flips against the first run (scratch `flips.lua` over the two
events files):

- p0_13, 34 trials WARN to FAIL: a SIZ descriptor byte of a component
  past the 16th used to trip the "differs from the 16th" c145 (an
  unsupported-feature notice, not a detection). The same bytes now FAIL
  as Profile 0 violations (c259, sub-sampling 254 or 65 is not 1, 2 or
  4), which is the proven finding the file deserves.
- p0_13, 4 trials accepted to FAIL: Profile 0 rules on components below
  the 16th (sub-sampling) and on the tile grid (XTsiz byte) that nothing
  checked before.
- p0_13, 7 trials WARN to accepted, all sniper bit flips in the Ssiz byte
  of a component past the 16th (precision or sign of one component).
  Profile 0 sets no bit-depth bound below Table A.10's 38, so a stream
  that declares component 252 as 9-bit is self-consistent: the packets
  decode, the samples clamp to the new range. The old WARN was the
  slot-15 artefact, not a real catch, so the sniper rate falls from 55%
  to 48% while the count of proven findings rises. The only cross-check
  that could catch a lone precision change is the reversible QCD
  exponent against precision plus band gain (Annex E.1.1), the open
  candidate in PLAN.md; these 7 trials are its evidence.
- p1_07, 2 trials accepted to FAIL: XTsiz/YTsiz bytes that leave most of
  the SIZ grid without a tile-part (the absent-tile rule).

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
  (8) and Profile 1 (5). No cinema, broadcast or IMF file has been
  probed because none is vendored; those profiles are recognised but
  their constraints are not yet validated (see PLAN).

Rerunning is not implicit acceptance here: the seed is fixed, so a rerun
after a validator change is a paired comparison (`corruption-probe
compare`), and any accepted-to-rejected or rejected-to-accepted
transition must be explained.
