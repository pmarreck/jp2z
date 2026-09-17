# Corruption Probe

## COMPLETE WITH EXCEPTIONS

Baseline: **accepted** · **SAFE: restoration verified**

| Evidence | Value |
| --- | --- |
| Input | p0\_09.j2k |
| Bytes | 594 |
| Started | 2026-09-17T00:55:26Z |
| Attempted / planned | 400 / 400 |
| Conclusive outcomes | 387 |
| Warnings and failures | 13 |
| Not run | 0 |

## Mutation rejection

Rates and 95% Wilson intervals use conclusive trials only.

| Mode | Rejected/conclusive | Rate | 95% Wilson CI | Not run |
| --- | ---: | ---: | ---: | ---: |
| sniper | 42/98 | 42.9% | 33.5..52.7% | 0 |
| bolter | 43/100 | 43.0% | 33.7..52.8% | 0 |
| shotgun | 89/89 | 100.0% | 95.9..100.0% | 0 |
| truncation | 100/100 | 100.0% | 96.3..100.0% | 0 |

### Warnings and failures

| Mode | warning | error | crash | timeout | interrupted |
| --- | ---: | ---: | ---: | ---: | ---: |
| sniper | 2 | 0 | 0 | 0 | 0 |
| bolter | 0 | 0 | 0 | 0 | 0 |
| shotgun | 11 | 0 | 0 | 0 | 0 |
| truncation | 0 | 0 | 0 | 0 | 0 |

## Interpretation

Mutation rejection is not proof of corruption detection. Accepted changes may remain valid.

Intervals describe this input and sampling model. Warnings and failures are excluded from the rate, not from the report. Inspect unfinished trials before comparing percentages.

## Reproduce this experiment

| Setting | Value |
| --- | --- |
| Source SHA-256 | 409c62a227497e7f2fc7e49055c02530cce742b6b385800b8a5aa4ae5bfab1a4 |
| Validator | zig-out/bin/jp2z validate --strict \{file\} |
| Seed | 0x0000000000000000000000000000000000000000000000000000000000001234 |
| Shotgun bytes | 74 |
| Workers | 1 |
| Algorithm | corruption\_probe mutation v1 |
| RNG | random BLAKE3 keyed XOF (random-luajit-lib @436f512eebf2ae705f852c9edeceb68e1d495519) |
