//! Decode test suite. Empty harness until fixtures are added.
//!
//! NEXT STEPS (for the LLM picking this up):
//!
//! 1. Generate a tiny JP2 fixture. Easiest: `opj_compress` on a
//!    4×4 PGM or PPM, save as tests/unit/fixtures/4x4_gray.jp2 and
//!    4x4_rgb.jp2. Mirror jpegz's `scratch/gen_*_fixtures.{c,sh}`
//!    pattern.
//!
//! 2. Embed via `@embedFile("fixtures/4x4_gray.jp2")` and write
//!    Phase-1 decode tests asserting dimensions + channels match
//!    expected (the openjpeg wrapper handles them today).
//!
//! 3. Once Phase 2 M1 (codestream walker) lands, mirror jpegz's
//!    `internal.cleanroomDecode` vs `internal.openjpegDecode`
//!    byte-perfect comparison pattern.

const std = @import("std");
const jp2z = @import("jp2z");

test "decode: empty harness — fixtures TBD" {
    _ = jp2z;
    return error.SkipZigTest;
}
