# Encoder and the decode/encode/verify CLI

Decision (BDFN, 2026-10-23): jp2z gains an encoder, and its C CLI must at
least decode, encode and verify, calling jp2z only through the C ABI so the
CLI dogfoods it. This supersedes the overview's earlier "decode only"
scope. The CLI already decodes (`jp2z decode`, and the bare-file form) and
verifies (`jp2z validate`); encode is the missing verb.

## Defaults for the first encoder (assumptions, revisit on direction)

These were chosen without a design interview because the request named the
verbs but not the coding parameters; each is the conservative end of T.800
Part 1 and the cheapest to prove correct.

- Reversible path first: 5/3 wavelet, no quantization, RCT for three-
  component input, so the correctness oracle is exact: decode(encode(x)) == x.
- One tile, one quality layer, LRCP, 64x64 code-blocks, default precincts,
  code-block style 0, decomposition levels chosen so the coarsest resolution
  is at least one sample (cap 5, the common default).
- Input: PGM and PPM (P5/P6, 8- and 16-bit), the formats the decoder already
  writes; output: a J2K codestream, or JP2 with ihdr and a colr box (I.5.3)
  when the output name ends in `.jp2` or `--jp2` is given.
- Irreversible 9/7 with quantization and rate control (a target ratio or
  PSNR), multiple layers, tiling and the other progression orders are the
  follow-on item, not part of the first cut.

## Independence and proof

- Exact round trip through jp2z's own decoder, and through OpenJPEG (an
  implementation this project did not write) for every encoded test image.
- Every encoded file passes `jp2z validate --strict` with no findings
  above INFO, and OpenJPEG decodes it without warnings.
- The MQ coder currently lives in tests/unit/mq_encoder.zig as a
  spec-written test encoder; moving it into the library makes it the
  production encoder, so its round-trip tests stop being independent of
  the code under test. The OpenJPEG round trip stays the independent check.
- The encoded outputs join the specificity side of the mutation matrix and
  ./corruption-coverage as additional known-good inputs.

## C ABI and CLI shape

- `jp2z_encode(const uint8_t *pixels, size_t length, const
  jp2z_encode_params_t *params, uint8_t **out, size_t *out_length)` with an
  explicit free function, pointer-plus-length buffers per the fleet C ABI
  rule; image geometry, component count, precision and signedness in the
  params struct.
- `jp2z encode [--jp2|--j2k] <input.pgm|.ppm|-> [-o out|-]`, with `-`,
  `@stdin`, `@stdout` handled as the CLI rules require; `jp2z verify` is an
  alias of `jp2z validate`.
- The CLI is C and links only the static archive through
  `include/jp2z_core.h`; it must never import the Zig module.
