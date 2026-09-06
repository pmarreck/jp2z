# Conformance fixture provenance

All `.j2c` and `.jp2` files in this directory were copied verbatim from:

- Repo: https://github.com/uclouvain/openjpeg-data
- Path: `input/conformance/`
- Pinned commit: `39524bd3a601d90ed8e0177559400d23945f96a9` (2024-11-13)

The full bundle in that repo is the official ITU-T T.803 | ISO/IEC 15444-4
JPEG 2000 Part 4 conformance test suite, originally developed by
Algo Vision Technology GmbH, Aware Inc., Kodak Inc., and Ricoh
Innovations Inc. See the adjacent `COPYRIGHT` file for the full
permission text — redistribution for the purpose of testing
conformance to the JPEG 2000 Standard is explicitly permitted, and
the `COPYRIGHT` notice must travel with any copy (which it does, here).

## Why these curated files?

A curated subset that fits in ~1 MB while still covering the major
shapes the Phase 2 pure-Zig decoder will need to handle. The full
59-file conformance set is also pulled in at CI time as a Nix flake
input (see `flake.nix` → `inputs.openjpeg-data`) so the broader
oracle suite stays accessible without bloating the repo.

| File | Bytes | Notes |
|---|---:|---|
| `a1_mono.j2c` | 33,588 | Class A monochrome raw codestream |
| `b1_mono.j2c` | 34,848 | Class B monochrome — adds tier-2 packet variation |
| `c1_mono.j2c` | 33,608 | Class C monochrome — adds region-of-interest / scalable layers |
| `d1_colr.j2c` | 60,080 | Class D color — multi-component without MCT |
| `e1_colr.j2c` | 67,792 | Class E color — MCT (RCT or ICT) exercised |
| `f1_mono.j2c` | 35,107 | Class F monochrome — error-resilience markers |
| `a5_mono.j2c` | 34747 | Class A monochrome — SOP/EPH packet markers + 2×2 tiling |
| `c2_mono.j2c` | 34208 | Class C monochrome — tier-1 RESET+VSC+SEGSYM coding styles |
| `p0_04.j2k`, `p0_09.j2k`, `p0_10.j2k` | — | Profile-0 conformance (9/7+ICT, 9/7 mono, multi-tile sub-sampled) |
| `p1_04.j2k` | 101,844 | Profile-1: 12-bit mono, 9/7 lossy, 8×8 multi-tile (>8-bit + 9/7-multi-tile path) |
| `file1.jp2` | 650,678 | JP2 file format, first reference image — exercises box parser |
| `file9.jp2` | 300,208 | JP2 file format, exercises additional metadata box types |
| `g3_colr.j2c` | 67,333 | Class G color (T.803 packed-header class) — PPM in 214 main-header segments (Nppm chunks span segments), 2 tiles, SOP+EPH (EPH inside the packed store), 3 layers, 5/3. Must-accept guard for the PPM walk (added 2026-09-06). |
| `g4_colr.j2c` | 67,325 | Class G color — PPT in 214 tile-part-header segments over 2 tile-parts, otherwise as g3. Must-accept guard for the PPT walk. |
| `p0_01.j2k` | 7,390 | Profile-0 test 1: 128×128 mono 5/3, QCD BEFORE COD in the main header (legal, A.4.1). Guards per-subband M_b derivation against marker order — was a strict c255 false positive (2026-09-06). |
| `d2_colr.j2c` | 67,797 | Class D color (multi-component, no MCT): 4×2 tiles, 4 layers, tiles 1 and 3 carry tile-part COD overrides switching progression to RPCL/CPRL. Guards A.6.1 tile COD application (was max_abs 254). |
| `p0_13.j2k` | 2,486 | Profile-0 test 13: 1×1 image with 257 components, per-component COC/QCC, RGN roishift 11. Guards Csiz > 16 acceptance and per-component overrides. |
| `p1_06.j2k` | 3,356 | Profile-1: 16 tiles, one PPT per tile-part, SOP+EPH, 9/7, SEGSYM+VSC. Smallest real packed-header file; also the 9/7 multi-tile decode RED. |
| `balloon_eciRGB_icc.jp2` | 1,864,443 | Real-encoder JP2: 12 tiles, 8 layers, RPCL, custom precincts, SOP+EPH, SEGSYM, 9/7, eciRGB ICC. NOT from openjpeg-data — copied from validate's labeled known-GOOD corpus (`ground_truth_examples/jpeg2k/`, offered 2026-08-13) after its empty-packet layout exposed the `entropy_under_read` extractor false positive. Must-accept regression guard. |

Phase 1 (openjpeg wrapper) decode tests target these via
`@embedFile`. Phase 2 pure-Zig decode milestones use them as both
positive ("should decode") and oracle ("byte-perfect vs openjpeg")
fixtures.
