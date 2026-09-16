# Corruption Probe

## COMPLETE

Baseline: **accepted** · **SAFE: restoration verified**

| Evidence | Value |
| --- | --- |
| Input | a1\_mono.j2c |
| Bytes | 33588 |
| Started | 2026-09-16T22:21:28Z |
| Attempted / planned | 400 / 400 |
| Conclusive outcomes | 400 |
| Warnings and failures | 0 |
| Not run | 0 |

## Mutation rejection

Rates and 95% Wilson intervals use conclusive trials only.

| Mode | Rejected/conclusive | Rate | 95% Wilson CI | Not run |
| --- | ---: | ---: | ---: | ---: |
| sniper | 99/100 | 99.0% | 94.6..99.8% | 0 |
| bolter | 97/100 | 97.0% | 91.5..99.0% | 0 |
| shotgun | 100/100 | 100.0% | 96.3..100.0% | 0 |
| truncation | 100/100 | 100.0% | 96.3..100.0% | 0 |

### Warnings and failures

| Mode | warning | error | crash | timeout | interrupted |
| --- | ---: | ---: | ---: | ---: | ---: |
| sniper | 0 | 0 | 0 | 0 | 0 |
| bolter | 0 | 0 | 0 | 0 | 0 |
| shotgun | 0 | 0 | 0 | 0 | 0 |
| truncation | 0 | 0 | 0 | 0 | 0 |

## Interpretation

Mutation rejection is not proof of corruption detection. Accepted changes may remain valid.

Intervals describe this input and sampling model. Warnings and failures are excluded from the rate, not from the report. Inspect unfinished trials before comparing percentages.

## Reproduce this experiment

| Setting | Value |
| --- | --- |
| Source SHA-256 | fcdef2e91367a6e2e94849e7fdc818f186eb9685d6e7cdeab6d49d4399c8064a |
| Validator | ./zig-out/bin/jp2z validate --strict \{file\} |
| Seed | 0x0000000000000000000000000000000000000000000000000000000000001234 |
| Shotgun bytes | 4096 |
| Workers | 8 |
| Algorithm | corruption\_probe mutation v1 |
| RNG | random BLAKE3 keyed XOF (random-luajit-lib @436f512eebf2ae705f852c9edeceb68e1d495519) |
