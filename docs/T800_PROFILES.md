# JPEG 2000 Part 1 profiles and Rsiz (reference for jp2z's profile checks)

Source: Peter, 2026-09-16, transcribed from ITU-T T.800 (11/2015) /
ISO/IEC 15444-1:2016 (consolidated) and its amendments: Amd.1 (digital
cinema), Amd.2 (extended cinema / production / archival), Amd.3
(broadcast), Amd.7 / ISO Amd.8 (IMF). The in-force edition is T.800
(07/2024) V4, which ITU marks as paid; anything it adds after these
tables is unknown here and flagged as such in code comments.

## Table A.10: Rsiz (SIZ capability field)

| Rsiz | Meaning |
|---|---|
| 0x0000 | unrestricted Part 1 |
| 0x0001 | Profile 0 (Table A.45) |
| 0x0002 | Profile 1 (Table A.45) |
| 0x0003 | 2K Digital Cinema |
| 0x0004 | 4K Digital Cinema |
| 0x0005 | Scalable 2K Digital Cinema |
| 0x0006 | Scalable 4K Digital Cinema |
| 0x0007 | Long-term Storage |
| 0x0100 \| ML | Broadcast Contribution Single Tile, Mainlevel ML (1..7) |
| 0x0200 \| ML | Broadcast Contribution Multi-tile, Mainlevel ML (1..7) |
| 0x0306, 0x0307 | Broadcast Contribution Multi-tile Reversible, Mainlevel 6 / 7 only |
| 0x0400 \| SL<<4 \| ML | 2K IMF Single Tile Lossy |
| 0x0500 \| SL<<4 \| ML | 4K IMF Single Tile Lossy |
| 0x0600 \| SL<<4 \| ML | 8K IMF Single Tile Lossy |
| 0x0700 \| SL<<4 \| ML | 2K IMF Single/Multi Tile Reversible |
| 0x0800 \| SL<<4 \| ML | 4K IMF Single/Multi Tile Reversible |
| 0x0900 \| SL<<4 \| ML | 8K IMF Single/Multi Tile Reversible |
| bit 15 | at least one Part-2 extension (T.801) |
| bit 14 | HTJ2K (T.814) |

IMF low byte: `yyyy xxxx` = Sublevel (bits 4-7), Mainlevel (bits 0-3).
Example: 2K lossy, Sublevel 4, Mainlevel 5 = 0x0445. All other values are
reserved. Rsiz is not an enum: broadcast and IMF values are families.

## Table A.45: Profile 0 and Profile 1 restrictions

| Restriction | Profile 0 (Rsiz 1) | Profile 1 (Rsiz 2) |
|---|---|---|
| Image size | Xsiz, Ysiz < 2^31 | same |
| Tiles | 128x128 tiles (XTsiz = YTsiz = 128) or one tile covering the image | square tiles meeting the >= 1024 sampling-normalised dimension rule, or one tile covering the image |
| Origins | XOsiz = YOsiz = XTOsiz = YTOsiz = 0 | origins < 2^31 |
| RGN | SPrgn <= 37 | same |
| Sub-sampling | XRsiz_i, YRsiz_i in {1, 2, 4} | unrestricted |
| Code-block size | xcb = ycb = 5 or xcb = ycb = 6 | xcb <= 6, ycb <= 6 |
| Code-block style | only TERMALL, PTERM, SEGSYM may vary; BYPASS, RESET, VSC prohibited | unrestricted |
| PPM / PPT | prohibited | unrestricted |
| COD, COC, QCD, QCC | main header only | unrestricted |
| Lowest resolution | <= 128x128 | each tile's LL <= 128x128 |
| POC | first entry RSpoc0 = 0 and CSpoc0 = 0 | unrestricted |
| Tile-part order | all TPsot = 0 parts first, in tile order | unrestricted |
| Precincts | one precinct per resolution <= 128x128 (PPx, PPy >= 7 suffices at origin 0) | unrestricted |

Profile 0 is a strict subset of Profile 1.

## Digital cinema and archival (Rsiz 3..7)

| Profile | Max image | Csiz | Sampling | Depth |
|---|---|---|---|---|
| Cinema 2K | 2048x1080 | 3 | 1x1 | 12-bit unsigned |
| Cinema 4K | 4096x2160 | 3 | 1x1 | 12-bit unsigned |
| Scalable 2K | 2048x1080 | 3 | 1x1 | 12-bit unsigned |
| Scalable 4K | 4096x2160 | 3 | 1x1 | 12-bit unsigned |
| Long-term Storage | 16384x8640 | <= 8 | unrestricted | unrestricted |

Cinema: origins zero, one tile covering the image, RGN prohibited.
Long-term Storage: one tile, or tiles with X >= 1024 and Y >= 512.
2K/4K cinema coding: CPRL, exactly 1 layer, 32x32 code-blocks (xcb = ycb
= 5), COD/COC/QCD/QCC main header only, PPM/PPT prohibited, at most 5 (2K)
or 6 (4K) decomposition levels. Scalable cinema: CPRL, 2 layers, SOP/EPH
prohibited, explicit precincts, otherwise as cinema. Long-term Storage:
CPRL, <= 5 layers, EPH required, SOP permitted, default or explicit
precincts.

## Broadcast contribution (0x0100 / 0x0200 + ML, 0x0306 / 0x0307)

| Mainlevel | Max sampling (MSamples/s) | Max bitrate (Mbit/s) |
|---|---|---|
| 1 | 65 | 200 |
| 2 | 130 | 200 |
| 3 | 195 | 200 |
| 4 | 260 | 400 |
| 5 | 520 | 800 |
| 6 | 520 | 1600 |
| 7 | 520 | unspecified |

Sampling rate = average components per pixel (4:2:2 -> 2, 4:4:4 -> 3,
4:2:2:4 -> 3, 4:4:4:4 -> 4) x pixels per line x lines per frame x frame
rate; max codestream size = max bitrate / frame rate. CPRL, TLM required,
single-tile profile uses one tile covering the image. Frame rate is not
in the codestream, so the rate limits are not checkable from a still
codestream alone; structural rules are.

## IMF (0x0400..0x0900 + SL<<4 + ML)

Lossy single tile (Table A.51): max Xsiz / Ysiz / levels = 2K 2048/1556/5,
4K 4096/3112/6, 8K 8192/6224/7. Common: one tile covering the image,
origins zero, Csiz <= 3, unsigned 8..16 bits (7 <= Ssiz <= 15), RGN
prohibited, PPM/PPT prohibited, COD/COC/QCD/QCC main header only, same
decomposition count on every component, XRsiz all 1 or (1, 2, 2...),
YRsiz = 1. Mainlevel/Sublevel carry throughput and size limits (Tables
A.53/A.54). Reversible variants use Table A.52 and allow multiple tiles.
