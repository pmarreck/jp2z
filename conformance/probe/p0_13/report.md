# Corruption Probe

## COMPLETE WITH EXCEPTIONS

Baseline: **accepted** · **SAFE: restoration verified**

| Evidence | Value |
| --- | --- |
| Input | p0\_13.j2k |
| Bytes | 2486 |
| Started | 2026-09-16T22:23:43Z |
| Attempted / planned | 400 / 400 |
| Conclusive outcomes | 337 |
| Warnings and failures | 63 |
| Not run | 0 |

## Mutation rejection

Rates and 95% Wilson intervals use conclusive trials only.

| Mode | Rejected/conclusive | Rate | 95% Wilson CI | Not run |
| --- | ---: | ---: | ---: | ---: |
| sniper | 28/74 | 37.8% | 27.6..49.2% | 0 |
| bolter | 37/63 | 58.7% | 46.4..70.0% | 0 |
| shotgun | 100/100 | 100.0% | 96.3..100.0% | 0 |
| truncation | 100/100 | 100.0% | 96.3..100.0% | 0 |

### Warnings and failures

| Mode | warning | error | crash | timeout | interrupted |
| --- | ---: | ---: | ---: | ---: | ---: |
| sniper | 26 | 0 | 0 | 0 | 0 |
| bolter | 37 | 0 | 0 | 0 | 0 |
| shotgun | 0 | 0 | 0 | 0 | 0 |
| truncation | 0 | 0 | 0 | 0 | 0 |

## Interpretation

Mutation rejection is not proof of corruption detection. Accepted changes may remain valid.

Intervals describe this input and sampling model. Warnings and failures are excluded from the rate, not from the report. Inspect unfinished trials before comparing percentages.

## Reproduce this experiment

| Setting | Value |
| --- | --- |
| Source SHA-256 | 12463d0c67e803fac6637d384263abbb6b546826419ecb725aed18fd45bcabb0 |
| Validator | ./zig-out/bin/jp2z validate --strict \{file\} |
| Seed | 0x0000000000000000000000000000000000000000000000000000000000001234 |
| Shotgun bytes | 310 |
| Workers | 8 |
| Algorithm | corruption\_probe mutation v1 |
| RNG | random BLAKE3 keyed XOF (random-luajit-lib @436f512eebf2ae705f852c9edeceb68e1d495519) |
