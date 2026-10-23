/* C FFI smoke test for jp2z. Exercises every public C ABI entry
 * point. Proves external C consumers can link against the static
 * library and call its public API.
 *
 * Phase 1: no JP2 fixture decoded (would require @embed at the C
 * level, which only works with C23 #embed — fine, we use C23).
 * Once we have a JP2 fixture in tests/unit/fixtures/, this will
 * round-trip it via jp2z_decode + jp2z_image_free.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "jp2z_core.h"

/* Substring search over a NON-NUL-terminated buffer (finding details are
 * length-delimited). Hand-rolled because memmem is GNU-only and this
 * suite is expected to build on all five target platforms. */
static int contains(const unsigned char *hay, size_t hay_len, const char *needle) {
    const size_t n = strlen(needle);
    if (n == 0 || hay_len < n) return 0;
    for (size_t i = 0; i + n <= hay_len; i++) {
        if (memcmp(hay + i, needle, n) == 0) return 1;
    }
    return 0;
}

/* Finding codes now come from the published jp2z_finding_code_t in
 * jp2z_core.h — no local #defines. The registry numbering is ABI, so
 * these static asserts fail the build if a value ever drifts (the codes
 * are shared with the sibling jpegz family's vocabulary). */
_Static_assert(JP2Z_FINDING_MISSING_SOI == 1, "finding registry: missing_soi");
_Static_assert(JP2Z_FINDING_MISSING_EOI == 2, "finding registry: missing_eoi");
_Static_assert(JP2Z_FINDING_TRUNCATED_STREAM == 3, "finding registry: truncated_stream");
_Static_assert(JP2Z_FINDING_BAD_MARKER_LENGTH == 4, "finding registry: bad_marker_length");
_Static_assert(JP2Z_FINDING_UNSUPPORTED_MARKER_IGNORED == 145, "finding registry: c145");
_Static_assert(JP2Z_FINDING_ENTROPY_OVER_READ == 251, "finding registry: c251");
_Static_assert(JP2Z_FINDING_ENTROPY_UNDER_READ == 252, "finding registry: c252");
_Static_assert(JP2Z_FINDING_CODING_PASS_OVERFLOW == 253, "finding registry: c253");
_Static_assert(JP2Z_FINDING_JP2_PACKETS_WALKED_TO_END == 254, "finding registry: c254");
_Static_assert(JP2Z_FINDING_ZERO_BITPLANE_OVERFLOW == 255, "finding registry: c255");
_Static_assert(JP2Z_FINDING_PACKED_HEADERS_MISMATCH == 256, "finding registry: c256");
_Static_assert(JP2Z_FINDING_JP2_TRAILING_BYTES == 257, "finding registry: c257");
_Static_assert(JP2Z_FINDING_SEGMENTATION_SYMBOL_MISMATCH == 258, "finding registry: c258");
_Static_assert(JP2Z_FINDING_PROFILE_VIOLATION == 259, "finding registry: c259");
_Static_assert(JP2Z_FINDING_REVERSIBLE_EXPONENT_MISMATCH == 260, "finding registry: c260");
_Static_assert(JP2Z_FINDING_CBLK_CONTRIBUTION_ENDS_FF == 261, "finding registry: c261");

#define ASSERT(cond, msg) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL: %s (line %d): %s\n", \
            msg, __LINE__, jp2z_last_error_message()); \
        return 1; \
    } \
} while (0)

int main(void) {
    /* version() returns a non-empty string. */
    const char *v = jp2z_version();
    ASSERT(v != NULL && v[0] != '\0', "jp2z_version returns non-empty");

    /* decode rejects empty input cleanly (no crash, clear status). */
    jp2z_image_t img = {0};
    int rc = jp2z_decode(NULL, 0, &img);
    ASSERT(rc == JP2Z_ERR_TRUNCATED_STREAM, "decode(NULL, 0) returns TRUNCATED_STREAM");

    /* decode rejects garbage with the right error code. */
    const char *garbage = "definitely not a JP2 file";
    rc = jp2z_decode((const uint8_t *)garbage, strlen(garbage), &img);
    ASSERT(rc == JP2Z_ERR_INVALID_JP2_CODESTREAM, "decode(garbage) returns INVALID_JP2_CODESTREAM");
    ASSERT(strlen(jp2z_last_error_message()) > 0, "last_error_message populated after failure");

    /* decode_ex with NULL options should behave like decode. */
    rc = jp2z_decode_ex((const uint8_t *)garbage, strlen(garbage), NULL, &img);
    ASSERT(rc == JP2Z_ERR_INVALID_JP2_CODESTREAM, "decode_ex(opts=NULL) matches decode");

    /* decode_ex with explicit threads option. */
    jp2z_decode_options_t opts = {0};
    opts.threads = 1;
    rc = jp2z_decode_ex((const uint8_t *)garbage, strlen(garbage), &opts, &img);
    ASSERT(rc == JP2Z_ERR_INVALID_JP2_CODESTREAM, "decode_ex(threads=1) matches decode");

    /* FindingsSink: create / count / free. */
    jp2z_findings_sink_t *sink = jp2z_findings_sink_create();
    ASSERT(sink != NULL, "findings_sink_create returns non-NULL");
    ASSERT(jp2z_findings_sink_count(sink) == 0, "fresh sink is empty");

    /* findings_sink_get with NULL sink is a soft error. */
    jp2z_sink_finding_t f = {0};
    rc = jp2z_findings_sink_get(NULL, 0, &f);
    ASSERT(rc != JP2Z_OK, "findings_sink_get(NULL) returns error");

    /* decode_with_findings on garbage: same code, sink stays empty
     * (Phase 1 wrapper doesn't emit findings). */
    rc = jp2z_decode_with_findings((const uint8_t *)garbage, strlen(garbage), &opts, sink, &img);
    ASSERT(rc == JP2Z_ERR_INVALID_JP2_CODESTREAM, "decode_with_findings on garbage = correct error");
    ASSERT(jp2z_findings_sink_count(sink) == 0, "Phase 1 wrapper doesn't emit findings");

    jp2z_findings_sink_free(sink);
    jp2z_findings_sink_free(NULL); /* free(NULL) is a no-op */

    /* deep_validate: garbage has no SOC -- structural walk reports a
     * severity (>= 0) and pushes findings; must not crash. */
    jp2z_findings_sink_t *dsink = jp2z_findings_sink_create();
    int dsev = jp2z_deep_validate((const uint8_t *)garbage, strlen(garbage), 1, dsink);
    ASSERT(dsev >= 0, "deep_validate returns a severity, not an error, on garbage");
    ASSERT(jp2z_findings_sink_count(dsink) > 0, "deep_validate emits a finding on garbage");
    int dsev2 = jp2z_deep_validate(NULL, 0, 0, NULL);
    ASSERT(dsev2 >= 0, "deep_validate(NULL, 0) doesn't crash");
    jp2z_findings_sink_free(dsink);

    /* ── Missing-EOC strict vs relaxed (T.800 A.4.4: EOC is mandatory) ──
     * Contract: strict deep_validate REJECTs a codestream missing its EOC
     * terminator; relaxed mode keeps it a WARN (the body is still decodable).
     * a1_mono.j2c is a valid control ending in FF D9 (EOC); the EOC-removed
     * mutant is the same bytes minus the trailing 2. */
    static const unsigned char a1[] = {
#embed "../unit/fixtures/conformance/a1_mono.j2c"
    };
    const size_t a1_len = sizeof a1;

    /* valid control: strict deep_validate must NOT reject a conforming file. */
    jp2z_findings_sink_t *vs = jp2z_findings_sink_create();
    int vsev = jp2z_deep_validate(a1, a1_len, 1, vs);
    ASSERT(vsev >= 0 && vsev < JP2Z_SEVERITY_FAIL, "valid a1_mono: strict deep_validate ACCEPTs");
    jp2z_findings_sink_free(vs);

    /* EOC-removed mutant, strict => FAIL and reports the missing-EOC finding. */
    jp2z_findings_sink_t *es = jp2z_findings_sink_create();
    int esev = jp2z_deep_validate(a1, a1_len - 2, 1, es);
    ASSERT(esev == JP2Z_SEVERITY_FAIL, "missing-EOC: strict deep_validate REJECTs (FAIL)");
    int found_eoc = 0;
    for (size_t i = 0; i < jp2z_findings_sink_count(es); i++) {
        jp2z_sink_finding_t fd = {0};
        if (jp2z_findings_sink_get(es, i, &fd) == JP2Z_OK
            && fd.code == JP2Z_FINDING_MISSING_EOI) found_eoc = 1;
    }
    ASSERT(found_eoc, "missing-EOC: strict reports missing_eoi finding");
    jp2z_findings_sink_free(es);

    /* Deep findings are offset-anchored and name their first offending
     * code-block: a C consumer can jump straight to the byte. Flip one
     * byte deep in the entropy data (halfway in) — the tier-2 headers
     * stay intact so the walk reaches tier-1 and the byte-budget checks
     * fire. (Truncating instead would trip the cheaper structural
     * truncated_stream check first and never reach a code-block.) */
    unsigned char *a1_mut = malloc(a1_len);
    ASSERT(a1_mut != NULL, "malloc for corrupt copy");
    memcpy(a1_mut, a1, a1_len);
    a1_mut[a1_len / 2] ^= 0xFF;
    jp2z_findings_sink_t *ds2 = jp2z_findings_sink_create();
    (void)jp2z_deep_validate(a1_mut, a1_len, 1, ds2);
    int saw_anchored_deep = 0;
    for (size_t i = 0; i < jp2z_findings_sink_count(ds2); i++) {
        jp2z_sink_finding_t fd = {0};
        if (jp2z_findings_sink_get(ds2, i, &fd) != JP2Z_OK) continue;
        if (fd.code == JP2Z_FINDING_ENTROPY_OVER_READ
            || fd.code == JP2Z_FINDING_ENTROPY_UNDER_READ
            || fd.code == JP2Z_FINDING_CODING_PASS_OVERFLOW) {
            ASSERT(fd.offset != INT64_MIN && fd.offset > 0, "deep finding carries a byte offset");
            ASSERT(contains(fd.detail, fd.detail_len, "first: tile "),
                   "deep finding names its first offending code-block");
            saw_anchored_deep = 1;
        }
    }
    ASSERT(saw_anchored_deep, "entropy-corrupted a1_mono produces an anchored deep finding");
    jp2z_findings_sink_free(ds2);
    free(a1_mut);

    /* relaxed mode preserves WARN — structural, not unconditionally fatal. */
    jp2z_findings_sink_t *rs = jp2z_findings_sink_create();
    int rsev = jp2z_deep_validate(a1, a1_len - 2, 0, rs);
    ASSERT(rsev >= 0 && rsev < JP2Z_SEVERITY_FAIL, "missing-EOC: relaxed deep_validate keeps WARN (no FAIL)");
    jp2z_findings_sink_free(rs);

    /* ── Over-read cap (T.800 C.3.4 normal MQ termination) ──
     * A conforming code-block synthesises a few past-end 0xFF bytes as the
     * arithmetic coder drains; the decoder's register lookahead bounds this at
     * ~4 (2 INITDEC pre-load + <=2 final-renorm byteins). The corruption alarm
     * must sit ABOVE that, not at the old too-tight >2. These two valid ISO
     * fixtures each have exactly one cblk that legitimately over-reads 3
     * (b1_mono decodes byte-exact vs openjpeg; p0_04 within max_abs<=1) — they
     * must ACCEPT under strict deep_validate, not REJECT as false positives. */
    static const unsigned char b1[] = {
#embed "../unit/fixtures/conformance/b1_mono.j2c"
    };
    jp2z_findings_sink_t *b1s = jp2z_findings_sink_create();
    int b1sev = jp2z_deep_validate(b1, sizeof b1, 1, b1s);
    ASSERT(b1sev >= 0 && b1sev < JP2Z_SEVERITY_FAIL, "b1_mono (valid, cblk over_read=3): strict ACCEPTs");
    jp2z_findings_sink_free(b1s);

    static const unsigned char p004[] = {
#embed "../unit/fixtures/conformance/p0_04.j2k"
    };
    jp2z_findings_sink_t *p4s = jp2z_findings_sink_create();
    int p4sev = jp2z_deep_validate(p004, sizeof p004, 1, p4s);
    ASSERT(p4sev >= 0 && p4sev < JP2Z_SEVERITY_FAIL, "p0_04 (valid, cblk over_read=3): strict ACCEPTs");

    /* p0_04's two QCC markers used to be the c145 carrier here; QCC is
     * APPLIED since 2026-09-06, so the unsupported-valid invariant now
     * rides on e1_colr's RGN markers below. */
    jp2z_findings_sink_free(p4s);

    /* ── POC progression-order change must be APPLIED, not ignored ──
     * e1_colr.j2c (ISO conformance): 8 tiles (4x2, origin (1,1)), 5/3+RCT,
     * 4 layers, 32x32 precincts; tile 1 spans two tile-parts whose headers
     * each carry a POC marker (T.800 A.6.6) resequencing that tile's packets
     * (a PCRL volume for layer 0, then an RLCP volume for the rest). A walker
     * that ignores POC walks tile 1 in COD's LRCP order and shreds the byte
     * accounting (mass c251/c252 + a phantom truncation). With POC applied,
     * this conforming file must ACCEPT under strict deep validation. */
    static const unsigned char e1[] = {
#embed "../unit/fixtures/conformance/e1_colr.j2c"
    };
    jp2z_findings_sink_t *e1s = jp2z_findings_sink_create();
    int e1sev = jp2z_deep_validate(e1, sizeof e1, 1, e1s);
    ASSERT(e1sev >= 0 && e1sev < JP2Z_SEVERITY_FAIL, "e1_colr (valid, POC-resequenced): strict ACCEPTs");

    jp2z_findings_sink_free(e1s);

    /* ── Unsupported-valid invariant (release lock, Einstein step 3) ──
     * c145 (jp2_unsupported_marker_ignored: COC/RGN seen but not applied)
     * marks a CONFORMING stream using a feature jp2z doesn't apply yet —
     * "unsupported-valid", never "invalid". It must stay WARN and must never
     * independently escalate a strict verdict to FAIL. Every marker the ISO
     * fixtures carry is applied now (QCC, tile COD, COC, RGN), so the
     * carrier is a crafted 4x4 stream: SIZ Rsiz 0x4000 (the HTJ2K
     * capability bit, T.814) on 17 components whose 17th descriptor is
     * 12-bit. The Rsiz bit is recognised-but-unverified: c145. The
     * component count and the odd descriptor are fully supported since
     * the 16-slot ceiling went. 17 empty packets, EOC. */
    static const unsigned char rgn_mini[] = {
        0xFF, 0x4F,
        0xFF, 0x51, 0x00, 0x59, 0x40, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x11, /* Csiz = 17 */
        0x07, 0x01, 0x01, 0x07, 0x01, 0x01, 0x07, 0x01, 0x01, 0x07, 0x01, 0x01,
        0x07, 0x01, 0x01, 0x07, 0x01, 0x01, 0x07, 0x01, 0x01, 0x07, 0x01, 0x01,
        0x07, 0x01, 0x01, 0x07, 0x01, 0x01, 0x07, 0x01, 0x01, 0x07, 0x01, 0x01,
        0x07, 0x01, 0x01, 0x07, 0x01, 0x01, 0x07, 0x01, 0x01, 0x07, 0x01, 0x01,
        0x0B, 0x01, 0x01, /* 17th: 12-bit — differs from the 16th */
        0xFF, 0x52, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x04, 0x04, 0x00, 0x01,
        0xFF, 0x5C, 0x00, 0x04, 0x40, 0x40,
        0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1F, 0x00, 0x01, /* Psot = 12 + 2 + 17 */
        0xFF, 0x93,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xFF, 0xD9,
    };
    jp2z_findings_sink_t *rgs = jp2z_findings_sink_create();
    int rgsev = jp2z_deep_validate(rgn_mini, sizeof rgn_mini, 1, rgs);
    ASSERT(rgsev >= 0 && rgsev < JP2Z_SEVERITY_FAIL, "17-component mini stream with the HTJ2K Rsiz bit (valid, capability unverified): strict ACCEPTs");
    {
        size_t n145 = 0;
        for (size_t i = 0; i < jp2z_findings_sink_count(rgs); i++) {
            jp2z_sink_finding_t fd = {0};
            if (jp2z_findings_sink_get(rgs, i, &fd) != JP2Z_OK) continue;
            if (fd.code == JP2Z_FINDING_UNSUPPORTED_MARKER_IGNORED) {
                n145++;
                ASSERT(fd.severity == JP2Z_SEVERITY_WARN,
                       "c145 unsupported-valid stays WARN, never FAIL, in strict mode");
            }
        }
        ASSERT(n145 >= 1, "the HTJ2K Rsiz bit exercises c145 so the invariant is non-vacuous");
    }
    jp2z_findings_sink_free(rgs);

    /* ── Per-tile QCD overrides must be APPLIED, not ignored ──
     * p1_04.j2k (ISO conformance, T.803 pass-case): 64 tiles, 9/7,
     * expounded quant, and 63 of the 64 tile-part headers carry their own
     * QCD overriding the main header's. Ignoring those made jz compute
     * tile 7's LL Mb from the main QCD (expn 8 -> Mb 9 -> numbps 6 ->
     * max 16 passes) and flag the encoder's 19 declared passes as c253 —
     * a false positive; tile 7's own QCD (expn 9 -> Mb 10 -> numbps 7)
     * allows exactly 19. With tile QCD applied this file must ACCEPT. */
    static const unsigned char p104[] = {
#embed "../unit/fixtures/conformance/p1_04.j2k"
    };
    jp2z_findings_sink_t *p1s = jp2z_findings_sink_create();
    int p1sev = jp2z_deep_validate(p104, sizeof p104, 1, p1s);
    ASSERT(p1sev >= 0 && p1sev < JP2Z_SEVERITY_FAIL, "p1_04 (valid, per-tile QCD): strict ACCEPTs");
    jp2z_findings_sink_free(p1s);

    /* ── PTERM tighter bound must not false-positive on a VALID PTERM stream ──
     * pterm_test.j2k: generated via `opj_compress -M 16` (64x64 gradient PGM),
     * cblksty=0x10 verified in its COD marker; openjpeg round-trips it. Under
     * PTERM the over-read cap tightens 4→2 (flush-terminated tail); a
     * conforming PTERM stream must still ACCEPT under strict deep_validate. */
    static const unsigned char ptermf[] = {
#embed "../unit/fixtures/pterm_test.j2k"
    };
    jp2z_findings_sink_t *pts = jp2z_findings_sink_create();
    int ptsev = jp2z_deep_validate(ptermf, sizeof ptermf, 1, pts);
    ASSERT(ptsev >= 0 && ptsev < JP2Z_SEVERITY_FAIL, "valid PTERM stream: strict ACCEPTs under the tightened cap");
    jp2z_findings_sink_free(pts);

    /* ── Encode through the C ABI, decode back, validate strictly ──
     * Samples use the jp2z_image_t.pixels layout, so what jp2z_decode
     * returns must equal what went in (lossless 5/3 path). */
    _Static_assert(sizeof(jp2z_encode_params_t) == 20, "jp2z_encode_params_t is 20 bytes");
    {
        enum { W = 13, H = 7, C = 3 };
        uint8_t rgb[W * H * C];
        for (size_t i = 0; i < sizeof rgb; i++) rgb[i] = (uint8_t)((i * 37u + (i / 39u) * 11u) & 0xFF);
        jp2z_encode_params_t ep = {0};
        ep.width = W; ep.height = H; ep.components = C; ep.precision = 8;
        ep.levels = JP2Z_LEVELS_DEFAULT; ep.format = JP2Z_FORMAT_JP2;
        jp2z_buffer_t enc = {0};
        ASSERT(jp2z_encode(rgb, sizeof rgb, &ep, &enc) == JP2Z_OK, "encode 13x7 RGB 8-bit as JP2");
        ASSERT(enc.data != NULL && enc.len > 12, "encode returns bytes");
        ASSERT(memcmp(enc.data, "\x00\x00\x00\x0CjP  \r\n\x87\n", 12) == 0, "JP2 output starts with the signature box");
        jp2z_findings_sink_t *es = jp2z_findings_sink_create();
        int esev = jp2z_deep_validate(enc.data, enc.len, 1, es);
        ASSERT(esev == JP2Z_SEVERITY_PASS || esev == JP2Z_SEVERITY_INFO, "encoded JP2 validates strict-clean");
        jp2z_findings_sink_free(es);
        jp2z_image_t back = {0};
        ASSERT(jp2z_decode(enc.data, enc.len, &back) == JP2Z_OK, "encoded JP2 decodes");
        ASSERT(back.width == W && back.height == H && back.channels == C && back.bits_per_sample == 8, "decoded geometry matches");
        ASSERT(back.pixels_len == sizeof rgb && memcmp(back.pixels, rgb, sizeof rgb) == 0, "decoded samples equal the input");
        jp2z_image_free(&back);
        jp2z_buffer_free(&enc);
        ASSERT(enc.data == NULL && enc.len == 0, "jp2z_buffer_free zeroes the buffer");
        jp2z_buffer_free(&enc);   /* second free is a no-op */
        jp2z_buffer_free(NULL);
    }
    {
        enum { W = 5, H = 4 };
        uint16_t grey[W * H];
        for (size_t i = 0; i < W * H; i++) grey[i] = (uint16_t)((i * 211u) & 0x0FFF);
        jp2z_encode_params_t ep = {0};
        ep.width = W; ep.height = H; ep.components = 1; ep.precision = 12;
        ep.levels = 2; ep.format = JP2Z_FORMAT_J2K;
        jp2z_buffer_t enc = {0};
        ASSERT(jp2z_encode((const uint8_t *)grey, sizeof grey, &ep, &enc) == JP2Z_OK, "encode 5x4 12-bit grey as J2K");
        ASSERT(enc.len > 4 && memcmp(enc.data, "\xFF\x4F\xFF\x51", 4) == 0, "J2K output starts with SOC SIZ");
        jp2z_image_t back = {0};
        ASSERT(jp2z_decode(enc.data, enc.len, &back) == JP2Z_OK, "encoded J2K decodes");
        ASSERT(back.bits_per_sample == 12 && back.pixels_len == sizeof grey && memcmp(back.pixels, grey, sizeof grey) == 0, "12-bit samples round-trip");
        jp2z_image_free(&back);
        jp2z_buffer_free(&enc);
    }
    {
        /* Refusals: each leaves the output zeroed and records a message. */
        uint8_t px[4] = { 0, 1, 2, 15 };
        jp2z_encode_params_t ok = {0};
        ok.width = 2; ok.height = 2; ok.components = 1; ok.precision = 4;
        ok.levels = JP2Z_LEVELS_DEFAULT; ok.format = JP2Z_FORMAT_J2K;
        jp2z_buffer_t enc = {0};
        ASSERT(jp2z_encode(px, sizeof px, &ok, &enc) == JP2Z_OK, "the baseline refusal input encodes");
        jp2z_buffer_free(&enc);

        jp2z_encode_params_t bad = ok;
        ASSERT(jp2z_encode(px, 3, &ok, &enc) == JP2Z_ERR_INVALID_ARGUMENT && enc.data == NULL, "short sample buffer refused");
        ASSERT(jp2z_last_error_message()[0] != '\0', "refusal records a message");
        ASSERT(jp2z_encode(NULL, 4, &ok, &enc) == JP2Z_ERR_INVALID_ARGUMENT, "NULL samples refused");
        ASSERT(jp2z_encode(px, 4, NULL, &enc) == JP2Z_ERR_INVALID_ARGUMENT, "NULL params refused");
        ASSERT(jp2z_encode(px, 4, &ok, NULL) == JP2Z_ERR_INVALID_ARGUMENT, "NULL output refused");
        bad.reserved[6] = 1;
        ASSERT(jp2z_encode(px, 4, &bad, &enc) == JP2Z_ERR_INVALID_ARGUMENT, "nonzero reserved byte refused");
        bad = ok; bad.format = 2;
        ASSERT(jp2z_encode(px, 4, &bad, &enc) == JP2Z_ERR_INVALID_ARGUMENT, "unknown format refused");
        bad = ok; bad.levels = 33;
        ASSERT(jp2z_encode(px, 4, &bad, &enc) == JP2Z_ERR_INVALID_ARGUMENT, "33 levels refused");
        bad = ok; bad.precision = 3;
        ASSERT(jp2z_encode(px, 4, &bad, &enc) == JP2Z_ERR_INVALID_ARGUMENT, "sample 15 at precision 3 refused");
        bad = ok; bad.precision = 17;
        ASSERT(jp2z_encode(px, 4, &bad, &enc) == JP2Z_ERR_UNSUPPORTED_PRECISION, "precision 17 refused");
        bad = ok; bad.width = 0;
        ASSERT(jp2z_encode(px, 0, &bad, &enc) == JP2Z_ERR_INVALID_ARGUMENT, "zero width refused");
        ASSERT(enc.data == NULL && enc.len == 0, "refusals leave the output zeroed");
    }

    /* ── Encode ownership and error contract (coordinator review) ── */
    {
        /* Status values are distinct: a duplicate makes these case labels
         * collide and the build fails. */
        jp2z_status_t probe = JP2Z_OK;
        switch (probe) {
        case JP2Z_OK: case JP2Z_ERR_NOT_IMPLEMENTED: case JP2Z_ERR_INVALID_MARKER:
        case JP2Z_ERR_UNSUPPORTED_PRECISION: case JP2Z_ERR_TRUNCATED_STREAM:
        case JP2Z_ERR_BACKEND: case JP2Z_ERR_INVALID_JP2_CODESTREAM:
        case JP2Z_ERR_OUT_OF_MEMORY: case JP2Z_ERR_CALLBACK_ABORTED:
        case JP2Z_ERR_INVALID_ARGUMENT: case JP2Z_ERR_ENCODE_FAILED:
            break;
        }
        _Static_assert(JP2Z_ERR_INVALID_ARGUMENT == -10 && JP2Z_ERR_ENCODE_FAILED == -11, "encode statuses are -10 and -11");

        /* Every failure zeroes `out`, whatever it held on entry. */
        uint8_t px[4] = { 0, 1, 2, 3 };
        jp2z_encode_params_t ep = {0};
        ep.width = 2; ep.height = 2; ep.components = 1; ep.precision = 2;
        ep.levels = JP2Z_LEVELS_DEFAULT; ep.format = JP2Z_FORMAT_J2K;
        jp2z_buffer_t stale = { (uint8_t *)px, 99 };
        ASSERT(jp2z_encode(px, 3, &ep, &stale) == JP2Z_ERR_INVALID_ARGUMENT, "short buffer refused");
        ASSERT(stale.data == NULL && stale.len == 0, "failure zeroes an output that held a stale pointer");
        stale.data = (uint8_t *)px; stale.len = 99;
        ASSERT(jp2z_encode(px, 4, NULL, &stale) == JP2Z_ERR_INVALID_ARGUMENT && stale.data == NULL && stale.len == 0, "NULL params: output zeroed");

        /* The byte count is computed with overflow checks before any sample
         * is read: 2^32-1 x 2^32-1 x 16384 x 2 bytes does not fit size_t. */
        jp2z_encode_params_t huge = {0};
        huge.width = 0xFFFFFFFFu; huge.height = 0xFFFFFFFFu; huge.components = 16384; huge.precision = 16;
        huge.levels = JP2Z_LEVELS_DEFAULT; huge.format = JP2Z_FORMAT_J2K;
        ASSERT(jp2z_encode(px, sizeof px, &huge, &stale) == JP2Z_ERR_INVALID_ARGUMENT && stale.data == NULL, "size_t overflow in the sample count is refused");
        ASSERT(contains((const unsigned char *)jp2z_last_error_message(), strlen(jp2z_last_error_message()), "overflow"), "overflow refusal says so");

        /* Native uint16_t samples may sit at any address: encode from an odd
         * offset and compare the decode against the same values. */
        enum { W = 3, H = 2 };
        uint16_t want[W * H] = { 0, 1, 1023, 2048, 4000, 4095 };
        uint8_t raw[sizeof want + 1];
        memcpy(raw + 1, want, sizeof want);
        jp2z_encode_params_t ep16 = {0};
        ep16.width = W; ep16.height = H; ep16.components = 1; ep16.precision = 12;
        ep16.levels = JP2Z_LEVELS_DEFAULT; ep16.format = JP2Z_FORMAT_J2K;
        jp2z_buffer_t enc = {0};
        ASSERT(jp2z_encode(raw + 1, sizeof want, &ep16, &enc) == JP2Z_OK, "unaligned 16-bit samples encode");
        jp2z_image_t back = {0};
        ASSERT(jp2z_decode(enc.data, enc.len, &back) == JP2Z_OK, "unaligned-input encode decodes");
        ASSERT(back.pixels_len == sizeof want && memcmp(back.pixels, want, sizeof want) == 0, "unaligned 16-bit samples round-trip");
        jp2z_image_free(&back);
        jp2z_buffer_free(&enc);

        /* Interleaving order: pixel-major, component-minor. Two components
         * with distinct constant planes come back in the same order. */
        uint8_t ia[2 * 2 * 2] = { 10, 200, 10, 200, 10, 200, 10, 200 };
        jp2z_encode_params_t ei = ep;
        ei.components = 2; ei.precision = 8;
        ASSERT(jp2z_encode(ia, sizeof ia, &ei, &enc) == JP2Z_OK, "two-component interleaved encode");
        ASSERT(jp2z_decode(enc.data, enc.len, &back) == JP2Z_OK && back.channels == 2 && memcmp(back.pixels, ia, sizeof ia) == 0, "component order is preserved");
        jp2z_image_free(&back);
        jp2z_buffer_free(&enc);
    }

    printf("PASS: jp2z C FFI smoke (version + decode + findings_sink + deep_validate + missing-EOC + over-read cap + c145-WARN invariant + POC + tile-QCD + PTERM + code-registry + anchored-diagnostics + encode round trip, refusals and ownership contract)\n");
    return 0;
}
