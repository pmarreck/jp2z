# Corruption Probe

## COMPLETE WITH EXCEPTIONS

Baseline: **accepted** · **SAFE: restoration verified**

| Evidence | Value |
| --- | --- |
| Input | p1\_07.j2k |
| Bytes | 569 |
| Started | 2026-09-16T22:23:50Z |
| Attempted / planned | 400 / 400 |
| Conclusive outcomes | 398 |
| Warnings and failures | 2 |
| Not run | 0 |

## Mutation rejection

Rates and 95% Wilson intervals use conclusive trials only.

| Mode | Rejected/conclusive | Rate | 95% Wilson CI | Not run |
| --- | ---: | ---: | ---: | ---: |
| sniper | 73/99 | 73.7% | 64.3..81.4% | 0 |
| bolter | 83/99 | 83.8% | 75.3..89.8% | 0 |
| shotgun | 100/100 | 100.0% | 96.3..100.0% | 0 |
| truncation | 100/100 | 100.0% | 96.3..100.0% | 0 |

### Warnings and failures

| Mode | warning | error | crash | timeout | interrupted |
| --- | ---: | ---: | ---: | ---: | ---: |
| sniper | 1 | 0 | 0 | 0 | 0 |
| bolter | 1 | 0 | 0 | 0 | 0 |
| shotgun | 0 | 0 | 0 | 0 | 0 |
| truncation | 0 | 0 | 0 | 0 | 0 |

## Interpretation

Mutation rejection is not proof of corruption detection. Accepted changes may remain valid.

Intervals describe this input and sampling model. Warnings and failures are excluded from the rate, not from the report. Inspect unfinished trials before comparing percentages.

## Reproduce this experiment

| Setting | Value |
| --- | --- |
| Source SHA-256 | 59576c42568098e4e5d9967eefb0a59b0002fedd7776c201c2c9f9aeb3cf1949 |
| Validator | ./zig-out/bin/jp2z validate --strict \{file\} |
| Seed | 0x0000000000000000000000000000000000000000000000000000000000001234 |
| Shotgun bytes | 71 |
| Workers | 8 |
| Algorithm | corruption\_probe mutation v1 |
| RNG | random BLAKE3 keyed XOF (random-luajit-lib @436f512eebf2ae705f852c9edeceb68e1d495519) |
