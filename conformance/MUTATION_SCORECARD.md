# Strict-validation mutation scorecard

Measured 2026-08-13 EDT (first measured 2026-08-04) through the public
`jp2z.deepValidate(..., true)` API in a module with no C headers, C
libraries, or OpenJPEG link dependency. The deterministic classifier is
`tests/mutation_matrix.zig` and runs in the canonical `./test` suite.

2026-08-13: added `balloon_eciRGB_icc.jp2` — a real-encoder multi-tile
lossy JP2 (12 tiles, 8 layers, RPCL, custom precincts, SOP+EPH, SEGSYM)
from validate's labeled known-GOOD corpus. Its empty-packet layout exposed
an extractor false positive (`entropy_under_read` on a valid file) that
the previous all-synthetic/small-dimension valid set could not catch; it
now guards that class on the must-accept side.

| Family | Valid controls | False-positive rejects | Unsupported controls accepted | Known-invalid sniper misses | Known-invalid bolter misses | Known-invalid shotgun misses |
|---|---:|---:|---:|---:|---:|---:|
| Raw J2K/J2C codestream | 12 | 0 | 2 | 0/12 | 0/12 | 0/12 |
| JP2 container | 3 | 0 | 0 | 0/3 | 0/3 | 0/3 |

Known-invalid mutations damage the mandatory SOC marker at three scales:
one bit (sniper), one byte (bolter/boltgun), and up to 1 KiB (shotgun).
All 45 are rejected. All controls and mutations completed classification;
the indeterminate count is zero.

The same scales are also applied inside each first tile-part entropy body.
These are sensitivity probes rather than labeled corrupt files. An arbitrary
entropy change can still describe a conforming, different image, so an
undetected probe cannot honestly be called a false negative without an
independent semantic or specification-grounded label.

| Family | Entropy sniper detected | Entropy bolter detected | Entropy shotgun detected |
|---|---:|---:|---:|
| Raw J2K/J2C codestream | 8/12 | 9/12 | 12/12 |
| JP2 container | 3/3 | 3/3 | 3/3 |
| Total | 11/15 | 12/15 | 15/15 |

The test locks these values as minimum sensitivity floors. Higher detection
counts pass. The independent OpenJPEG oracle remains available only to the
development conformance sweep; it is absent from this public validation gate.
