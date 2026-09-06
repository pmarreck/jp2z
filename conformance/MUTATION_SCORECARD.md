# Strict-validation mutation scorecard

Measured 2026-09-06 EDT (first measured 2026-08-04) through the public
`jp2z.deepValidate(..., true)` API in a module with no C headers, C
libraries, or OpenJPEG link dependency. The deterministic classifier is
`tests/mutation_matrix.zig` and runs in the canonical `./test` suite.

2026-08-13: added `balloon_eciRGB_icc.jp2` — a real-encoder multi-tile
lossy JP2 (12 tiles, 8 layers, RPCL, custom precincts, SOP+EPH, SEGSYM)
from validate's labeled known-GOOD corpus. Its empty-packet layout exposed
an extractor false positive (`entropy_under_read` on a valid file) that
the previous all-synthetic/small-dimension valid set could not catch; it
now guards that class on the must-accept side.

2026-09-06: added `g3_colr.j2c`, `g4_colr.j2c`, `p1_06.j2k` — the ISO packed-
packet-header fixtures (PPM in 214 main-header segments; PPT in 214
tile-part-header segments; PPT per tile-part over 16 tiles), all with
SOP+EPH. Before this date the walker ignored PPM/PPT entirely, so these
valid files were REJECTED (3 false positives) and no PPM/PPT stream was
ever deep-validated. They now guard the packed-header walk on the
must-accept side; the c256 packed_headers_mismatch finding covers the
reject side (crafted tests in tests/unit/validate.zig).

2026-09-06 (later): added `p0_01.j2k` — QCD precedes COD in its main
header (legal, A.4.1). The per-subband M_b table was sized from COD's
decomposition count at QCD-parse time, so this order zeroed every
high-frequency M_b and strict mode rejected the file with a false
zero_bitplane_overflow. QCD parsing is now deferred until COD lands.

2026-09-06 (later still): QCC is applied (per-component quantization,
T.800 A.6.5, tile-part QCC > tile-part QCD > main QCC > main QCD), so
p0_04 no longer counts as an unsupported control; f1_mono (tile-part COD
override, still c145) is the one remaining unsupported-but-accepted
codestream control. Zero-byte code-block contributions now carry their
coding passes into the plan (e1_colr: seven tiny code-blocks).

2026-09-06 (evening): tile-part COD overrides are applied (A.6.1), so
f1_mono no longer counts as unsupported and `d2_colr.j2c` (tiles 1 and 3
switch progression) joins as control 17. No ISO control carries an
ignored marker any more; the C smoke test's c145 invariant now uses a
crafted RGN-bearing stream.

2026-09-06 (night): COC and RGN per-component overrides are applied
(A.6.2 / A.6.3), with per-component sub-sampled tile geometry throughout
the packet walk. Six more ISO fixtures join as controls (p0_02, p0_03,
p0_06, p0_13, p1_01, p1_07) — every one of them had been a strict FALSE
POSITIVE while the markers were ignored, as had the three large COC files
(p0_05, p0_08, p1_03; corpus-gated test). The MQ over-read cap without
PTERM is recalibrated 4 → 12 from a census over all 57 conformance files
(valid maxima: p0_08 10, file6 8, all others <= 3); per-fixture dumps show
the previous 17 controls keep exactly their 13/13/17 detections. p0_03 and
p0_13 are undetected by all three entropy probes (a signed 4-bit ROI file
and a 1×1 image: weak probes, not lost sensitivity).

| Family | Valid controls | False-positive rejects | Unsupported controls accepted | Known-invalid sniper misses | Known-invalid bolter misses | Known-invalid shotgun misses |
|---|---:|---:|---:|---:|---:|---:|
| Raw J2K/J2C codestream | 23 | 0 | 0 | 0/23 | 0/23 | 0/23 |
| JP2 container | 3 | 0 | 0 | 0/3 | 0/3 | 0/3 |

Known-invalid mutations damage the mandatory SOC marker at three scales:
one bit (sniper), one byte (bolter/boltgun), and up to 1 KiB (shotgun).
All 78 are rejected. All controls and mutations completed classification;
the indeterminate count is zero.

The same scales are also applied inside each first tile-part entropy body.
These are sensitivity probes rather than labeled corrupt files. An arbitrary
entropy change can still describe a conforming, different image, so an
undetected probe cannot honestly be called a false negative without an
independent semantic or specification-grounded label.

| Family | Entropy sniper detected | Entropy bolter detected | Entropy shotgun detected |
|---|---:|---:|---:|
| Raw J2K/J2C codestream | 15/23 | 15/23 | 21/23 |
| JP2 container | 3/3 | 3/3 | 3/3 |
| Total | 18/26 | 18/26 | 24/26 |

The test locks these values as minimum sensitivity floors. Higher detection
counts pass. The independent OpenJPEG oracle remains available only to the
development conformance sweep; it is absent from this public validation gate.

2026-09-06 (afternoon, day 2): JP2 palette boxes are validated (pclr
I.5.3.4, cmap I.5.3.5, cdef over cmap's output channels) and a palette
is reported as valid-but-unsupported (c145: decode delivers the
codestream component unmapped). `file9.jp2`, the ISO palette fixture, is
therefore the one unsupported JP2 control (`unsupported {0, 1}`); it is
still fully validated and never rejected. Surplus coding passes (beyond
3·numbps−2) are decoded by the openjpeg/JasPer convention and reported
as a WARN, so no control is affected; the entropy floors are unchanged.
