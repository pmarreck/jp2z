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

| Family | Valid controls | False-positive rejects | Unsupported controls accepted | Known-invalid sniper misses | Known-invalid bolter misses | Known-invalid shotgun misses |
|---|---:|---:|---:|---:|---:|---:|
| Raw J2K/J2C codestream | 15 | 0 | 2 | 0/15 | 0/15 | 0/15 |
| JP2 container | 3 | 0 | 0 | 0/3 | 0/3 | 0/3 |

Known-invalid mutations damage the mandatory SOC marker at three scales:
one bit (sniper), one byte (bolter/boltgun), and up to 1 KiB (shotgun).
All 54 are rejected. All controls and mutations completed classification;
the indeterminate count is zero.

The same scales are also applied inside each first tile-part entropy body.
These are sensitivity probes rather than labeled corrupt files. An arbitrary
entropy change can still describe a conforming, different image, so an
undetected probe cannot honestly be called a false negative without an
independent semantic or specification-grounded label.

| Family | Entropy sniper detected | Entropy bolter detected | Entropy shotgun detected |
|---|---:|---:|---:|
| Raw J2K/J2C codestream | 11/15 | 11/15 | 15/15 |
| JP2 container | 3/3 | 3/3 | 3/3 |
| Total | 14/18 | 14/18 | 18/18 |

The test locks these values as minimum sensitivity floors. Higher detection
counts pass. The independent OpenJPEG oracle remains available only to the
development conformance sweep; it is absent from this public validation gate.
