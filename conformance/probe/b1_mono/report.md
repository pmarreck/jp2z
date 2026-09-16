# Corruption Probe

## COMPLETE WITH EXCEPTIONS

Baseline: **accepted** · **SAFE: restoration verified**

| Evidence | Value |
| --- | --- |
| Input | b1\_mono.j2c |
| Bytes | 34848 |
| Started | 2026-09-16T22:21:30Z |
| Attempted / planned | 400 / 400 |
| Conclusive outcomes | 399 |
| Warnings and failures | 1 |
| Not run | 0 |

## Mutation rejection

Rates and 95% Wilson intervals use conclusive trials only.

| Mode | Rejected/conclusive | Rate | 95% Wilson CI | Not run |
| --- | ---: | ---: | ---: | ---: |
| sniper | 89/99 | 89.9% | 82.4..94.4% | 0 |
| bolter | 95/100 | 95.0% | 88.8..97.8% | 0 |
| shotgun | 100/100 | 100.0% | 96.3..100.0% | 0 |
| truncation | 100/100 | 100.0% | 96.3..100.0% | 0 |

### Warnings and failures

| Mode | warning | error | crash | timeout | interrupted |
| --- | ---: | ---: | ---: | ---: | ---: |
| sniper | 1 | 0 | 0 | 0 | 0 |
| bolter | 0 | 0 | 0 | 0 | 0 |
| shotgun | 0 | 0 | 0 | 0 | 0 |
| truncation | 0 | 0 | 0 | 0 | 0 |

## Interpretation

Mutation rejection is not proof of corruption detection. Accepted changes may remain valid.

Intervals describe this input and sampling model. Warnings and failures are excluded from the rate, not from the report. Inspect unfinished trials before comparing percentages.

## Reproduce this experiment

| Setting | Value |
| --- | --- |
| Source SHA-256 | e4d59f0bf721bb9d0878f7d15a858e44f1c0d7b19449a6f7cdca2fb3cd586826 |
| Validator | ./zig-out/bin/jp2z validate --strict \{file\} |
| Seed | 0x0000000000000000000000000000000000000000000000000000000000001234 |
| Shotgun bytes | 4096 |
| Workers | 8 |
| Algorithm | corruption\_probe mutation v1 |
| RNG | random BLAKE3 keyed XOF (random-luajit-lib @436f512eebf2ae705f852c9edeceb68e1d495519) |
