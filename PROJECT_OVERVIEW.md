# jp2z — Project Overview

## Goal

A pure-Zig **from-scratch reimplementation** of a JPEG 2000 decoder
(ITU-T T.800 / ISO 15444-1 Part 1) with a stable C ABI surface, modeled
after `jpegz`'s architecture for the rest of the JPEG family.

openjpeg is BSD-2 (permissive, attribution-only) — so this is **not** a
copyright-avoidance "cleanroom" exercise: we may freely read, reference,
and port openjpeg's algorithms. openjpeg's role here is a **build-time
differential-test oracle** (and the Phase-1 runtime backend, retired by
Phase 2), never a shipped runtime dependency at completion. The rewrite
earns its keep through four deliberate divergences — see "Why reimplement".

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

## Why reimplement instead of just using openjpeg

openjpeg is BSD-2: we could link it, fork it, or port it freely. We
reimplement in Zig because four deliberate capabilities are unreachable
any other way — openjpeg cannot provide them even forked:

1. **Integer-only, no float.** openjpeg's 9/7 path is floating-point.
   jp2z is fixed-point throughout → **bit-identical output on every
   platform**, which is itself a verification property. Lossless 5/3 is
   byte-exact vs openjpeg; lossy 9/7 converges to the *ideal* transform at
   PAE≤1 — conformant per ISO 15444-4 (lossy is graded by tolerance, not
   bit-exactness), so no-float costs no conformance.
2. **Rich validation diagnostics** for the `validate` project — report
   *more* error types and tolerate *less* than any permissive library
   (hostile-input SIZ findings, deep entropy-budget checks, etc.). Getting
   this from openjpeg would mean **forking and forever maintaining a
   deeply-patched C codebase**; here it is first-class.
3. **WASM + universal cross-compile.** A pure-Zig decoder drops natively
   into any Zig target — WASM (browser/edge pathology & medical viewers),
   all 5 OS/arch combos — small and C-dependency-free. openjpeg via
   emscripten is a heavy, awkward blob.
4. **Zig-fleet embeddability.** One Zig engine embeds into `tiffz`
   (JP2-in-TIFF — e.g. Aperio SVS whole-slide tiles, TIFF compression
   33003/33005), `jpegz` (re-export at feature-complete), and `validate` —
   no C runtime dependency, shared finding-code vocabulary.

**Faithfulness bar** (jp2z-reviewer's standing criterion): the port is
**faithful to openjpeg's algorithm** (differential-vs-openjpeg on valid
files) and the deliberate strict-error / integer-only **divergences are
sound and non-vacuous** — *not* "did we avoid the source."

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
1. Clean development isolation for the multi-month reimplementation work
2. jpegz sheds its openjpeg **runtime** dependency (the real win) — no
   third-party decoder in the shipped binary
3. Standalone JP2 consumers don't drag in jpegz's full surface
4. At jp2z v1, jpegz re-exports its API via a thin shim —
   unified consumer experience with zero code duplication

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
- **Oracle**: openjpeg, used at build/test time only for differential
  comparison (byte-exact for lossless, PAE for lossy). Never shipped.

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
  phases), then against itself (self-consistency regression once parity
  lands).
- `FindingsSink` + `lenient: bool` decode option, same shape as jpegz.
- Finding codes are a **shared cross-project registry** (validate / jpegz
  / jp2z) owned by the Einstein coordination layer — do not add or
  renumber codes without sign-off.

## License

BSD-2 — same as openjpeg. Because openjpeg is BSD-2 (permissive,
attribution-only), referencing or porting its algorithms is permitted;
jp2z nonetheless reaches feature-complete as an **independent Zig
implementation** whose value is the four divergences above, not a
"100%-original" claim. openjpeg is used as a **build-time test oracle**
and the **Phase-1 runtime backend** (linked binary, retired by Phase 2) —
it is not in the shipped dependency graph at completion.
