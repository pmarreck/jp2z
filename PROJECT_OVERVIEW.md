# jp2z — Project Overview

## Goal

A pure-Zig cleanroom decoder for JPEG 2000 (ITU-T T.800 / ISO 15444-1
Part 1) with a stable C ABI surface, modeled after `jpegz`'s
architecture for the rest of the JPEG family.

## Scope

**In scope:**
- T.800 Part 1: codestream walker, tier-1 EBCOT, tier-2 packet
  decoding, inverse 5/3 and 9/7 wavelet transforms, MCT (RCT + ICT)
- JP2 file format (T.800 Annex I) for delivery
- J2K raw codestream
- Decode only (encode = follow-on if demand surfaces)

**Out of scope:**
- T.801 Part 2 / JPX extensions (murkier IP, less universal need)
- T.802 Part 3 / MJ2 (Motion JPEG 2000) — separate codec family
- T.803+ later parts (interactive protocols, secure JPEG 2000, etc.)
- Encoding (Phase 4+ if requested)

## Why a separate project from jpegz

T.800 (JPEG 2000) and T.81 (JPEG family) share virtually nothing
algorithmically:
- T.81 / T.87: DCT or predictive coding + Huffman or arithmetic
  coding + per-MCU scan structure
- T.800: wavelet transform + bit-plane EBCOT + tier-1 MQ coder +
  tier-2 packet decoding + multi-component transform

The shared infrastructure that *does* transfer (marker walkers,
`FindingsSink`, lenient-mode pattern, C-ABI parity conventions, the
`internal.*` oracle-test pattern) is small and gets copied as
patterns rather than imported live.

Separate-then-integrate gives:
1. Clean development isolation for the multi-month cleanroom work
2. jpegz stays sharp and 100% cleanroom-claimable at runtime today
3. Standalone JP2 consumers don't drag in jpegz's full surface
4. At jp2z v1, jpegz re-exports its API via a thin shim —
   unified consumer experience with zero code duplication

See jpegz's own commit `0b01ec9` (cleanroom-only public dispatcher)
for the architectural prize this enables.

## Terminology

- **Codestream**: the J2K bitstream itself (markers + entropy data).
  Distinct from the JP2 file format (which wraps a codestream plus
  metadata boxes).
- **Tile**: subdivision of the image; each tile decodes independently.
  Default = whole image as one tile.
- **Resolution level**: wavelet decomposition level (`0` = highest
  detail / full size; higher = coarser).
- **Code-block**: smallest unit of tier-1 entropy coding (e.g. 64×64).
- **Precinct**: spatial region within a resolution level; groups
  code-blocks for tier-2 packet construction.
- **Packet**: tier-2 unit; encodes one (layer, resolution, component,
  precinct) tuple.
- **EBCOT**: Embedded Block Coding with Optimized Truncation (Taubman).
  The tier-1 entropy coder.
- **MQ coder**: the underlying binary arithmetic coder used by EBCOT.
- **MCT**: Multiple Component Transform. RCT (5/3) or ICT (9/7),
  inverse-applied after wavelet reconstruction.

## Project conventions

Inherited from jpegz (and Peter's global preferences):
- Main branch: `yolo`
- Build via `./build` / test via `./test` / cross via `./build_all`
- Integer / fixed-point only (no `f32`/`f64` in production code paths;
  oracles in tests are OK). Same constraint that landed PASS1_BITS
  and asymmetric upsample fixes in jpegz.
- C FFI is the real public API; CLI calls through it (no Zig CLI
  importing the Zig core directly).
- Tests: byte-perfect comparison against the openjpeg oracle (early
  phases), then against itself (cleanroom regression once that lands).
- `FindingsSink` + `lenient: bool` decode option, same shape as jpegz.

## License

BSD-2. Compatible with openjpeg (BSD-2). Re-uses no openjpeg source —
only links the binary as the Phase 1 backend, retired by Phase 2.
