# Strict-validation mutation scorecard

Measured 2026-08-04 EDT through the public `jp2z.deepValidate(..., true)`
API in a module with no C headers, C libraries, or OpenJPEG link dependency.
The deterministic classifier is `tests/mutation_matrix.zig` and runs in the
canonical `./test` suite.

| Family | Valid controls | False-positive rejects | Unsupported controls accepted | Known-invalid sniper misses | Known-invalid bolter misses | Known-invalid shotgun misses |
|---|---:|---:|---:|---:|---:|---:|
| Raw J2K/J2C codestream | 12 | 0 | 2 | 0/12 | 0/12 | 0/12 |
| JP2 container | 2 | 0 | 0 | 0/2 | 0/2 | 0/2 |

Known-invalid mutations damage the mandatory SOC marker at three scales:
one bit (sniper), one byte (bolter/boltgun), and up to 1 KiB (shotgun).
All 42 are rejected. All controls and mutations completed classification;
the indeterminate count is zero.

The same scales are also applied inside each first tile-part entropy body.
These are sensitivity probes rather than labeled corrupt files. An arbitrary
entropy change can still describe a conforming, different image, so an
undetected probe cannot honestly be called a false negative without an
independent semantic or specification-grounded label.

| Family | Entropy sniper detected | Entropy bolter detected | Entropy shotgun detected |
|---|---:|---:|---:|
| Raw J2K/J2C codestream | 8/12 | 9/12 | 12/12 |
| JP2 container | 2/2 | 2/2 | 2/2 |
| Total | 10/14 | 11/14 | 14/14 |

The test locks these values as minimum sensitivity floors. Higher detection
counts pass. The independent OpenJPEG oracle remains available only to the
development conformance sweep; it is absent from this public validation gate.
