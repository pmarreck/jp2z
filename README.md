# jp2z

[![Mechatron Prime CI](https://img.shields.io/endpoint?url=https%3A%2F%2Fthelio-nixos.tail66c90.ts.net%2Fbadges%2Fjp2z.json&style=for-the-badge)](https://thelio-nixos.tail66c90.ts.net/mechatron-prime/)

A from-scratch, integer-only JPEG 2000 (T.800) decoder in pure Zig with a
C FFI surface. openjpeg (BSD-2) is used only as a build-time differential
oracle and the Phase-1 backend — never a shipped runtime dependency. See
PROJECT_OVERVIEW.md for why we reimplement (cross-platform integer
determinism, rich validation diagnostics, WASM, Zig-fleet embeddability).

Sister project to [`jpegz`](https://github.com/pmarreck/jpegz) — same
architecture (Zig core + C FFI + C CLI dogfooding the boundary, Nix
flake build, Mechatron Prime CI), focused exclusively on the wavelet-based
JPEG 2000 codec family that has no shared algorithmic surface with
T.81 baseline / extended / progressive / lossless / arithmetic JPEG
or T.87 JPEG-LS.

## Status

**Phase 1 (now)**: thin wrapper over [openjpeg](https://github.com/uclouvain/openjpeg)
(BSD-2). Decodes JP2 (file format) and J2K (raw codestream). Same
pattern jpegz used pre-rewrite — gets users a working library
today; the pure-Zig path retires the dependency milestone by milestone.

**Phase 2 (multi-month)**: pure-Zig from-scratch replacement, planned
in six sub-milestones (see `PLAN.md`):

| Milestone | Scope |
|-----------|-------|
| M1 | Codestream marker walker + SIZ/COD/QCD parse |
| M2 | Tier-2 (packet headers, layer/resolution/component/precinct) |
| M3 | Tier-1 EBCOT decode (MQ coder + code-block decode) |
| M4 | Inverse wavelet 5/3 (lossless) |
| M5 | Inverse wavelet 9/7 (lossy) |
| M6 | Multiple Component Transform (MCT) inverse |

At M6 jp2z decodes fully in pure Zig; the openjpeg wrapper moves to
`internal.*` as a build-time oracle for byte-perfect regression
testing (same pattern jpegz uses for libjpeg-turbo and charls today).

## Architecture

```
Any consumer ──► C FFI boundary ──► Zig core (pure logic, no I/O)
                                    │
                                    ├── ffi/openjpeg_wrapper.zig (Phase 1)
                                    └── decode/* (Phase 2 pure-Zig, milestone by milestone)
```

Mirrors jpegz's hexagonal layout. The C FFI is the real public
API; even the bundled `jp2z` CLI (C, not Zig) calls through it to
dogfood the boundary every test run.

## Integration with jpegz

Once jp2z reaches M6 (pure-Zig decode complete), jpegz's existing
`pub const jpeg2000 = struct { ... }` namespace becomes a thin
re-export shim:

```zig
pub const jpeg2000 = struct {
    const jp2z = @import("jp2z");
    pub const decode = jp2z.decode;
    pub const decodeWithOptions = jp2z.decodeWithOptions;
    pub const validate = jp2z.validate;
    pub const deepValidate = jp2z.deepValidate;
};
```

At that moment jpegz has no openjpeg (nor any third-party decoder) at runtime — pure Zig, no asterisks.
jp2z stays consumable on its own for callers that only need T.800.

## Patent posture

JPEG 2000 Part 1 (T.800) core patents have all expired (filed
~1995-2000, 20-year terms ended ~2015-2020). EBCOT (Taubman) was
patented but licensed RF for the standard. Part 2 / JPX extensions
have murkier IP — **jp2z targets Part 1 only**.

## Build

```bash
./build       # nix build, copies to zig-out/bin/jp2z
./test        # full test suite (Zig unit + C CLI)
./build_all   # native + cross for all 5 supported platforms
```

## Corruption coverage

`./corruption-coverage` measures how much corruption the strict validator
catches, using the sibling project corruption_reader as an oracle this
project did not write (its consumer CLI contract, `docs/consumer_cli.md`
there). For every known-good fixture (the pristine file must pass strict
validation) and each of the sniper (one bit), bolter (one byte), shotgun
(16 bits in a 32-byte window) and nuke (a 4 KiB pseudorandom overwrite)
profiles, corruption-reader draws seeded cases, and `jp2z validate --strict`
judges each corrupted copy: FAIL and WARN count as detected, exit 0 as
accepted, and a crash or timeout is counted on its own. The report
(`conformance/CORRUPTION_COVERAGE.md`) gives each cell's detection rate
with a Wilson 95% interval, and a one-sided two-proportion test against
the committed baseline (`conformance/corruption_coverage.ndjson`) flags a
significant drop; surviving cases are listed for replay. The statistics
live in `tools/coverage_stats.zig` and run under `./test`; the campaign
itself is a dedicated command.

```bash
./corruption-coverage                      # all vendored fixtures, 200 rounds per cell
./corruption-coverage --rounds 400 --seed 0x2a tests/unit/fixtures/conformance/p0_04.j2k
```

corruption_reader is a private repository, so its pin lives in
`tools/coverage/flake.nix` (fetched over SSH) rather than in the main
flake: building or developing jp2z never needs private access, only this
campaign does. `CORRUPTION_READER=<path>` or a `corruption-reader` on PATH
overrides the pin.

## Third-party attribution

jp2z is a pure-Zig **port** of [OpenJPEG](https://github.com/uclouvain/openjpeg)
(© its authors, BSD-2-Clause) and links it as the Phase-1 decode backend. Most of
the pure-Zig code is written from scratch against ITU-T T.800; functions actually
translated from OpenJPEG source carry a `ported from openjpeg <file>` provenance
note (currently `precinctCblkGeom` ← `opj_tcd.c` `opj_tcd_init_tile`). The full
upstream license text and copyright holders are retained verbatim in
[`THIRD_PARTY/openjpeg-LICENSE.txt`](THIRD_PARTY/openjpeg-LICENSE.txt); see also
[`NOTICE`](NOTICE).

## License

jp2z is licensed under the **MIT License** (© 2026 Peter Marreck) — see
[`LICENSE`](LICENSE). It is Peter's own pure-Zig implementation, developed as a
port of OpenJPEG: most code is written from scratch against T.800, with a few
algorithms translated from OpenJPEG source (BSD-2, marked in-file). OpenJPEG's
permissive BSD-2-Clause is fully compatible; its attribution above, in
[`THIRD_PARTY/openjpeg-LICENSE.txt`](THIRD_PARTY/openjpeg-LICENSE.txt), and in
[`NOTICE`](NOTICE) is retained as required.
