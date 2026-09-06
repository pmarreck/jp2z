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
     * independently escalate a strict verdict to FAIL. Every ISO fixture
     * that used to carry an ignored marker (p0_04 QCC, f1_mono tile COD) is
     * applied now, so the carrier is a crafted 4x4 stream: the mini-stream
     * shell plus a main-header RGN (ROI shift 8) — one empty packet, EOC. */
    static const unsigned char rgn_mini[] = {
        0xFF, 0x4F,
        0xFF, 0x51, 0x00, 0x29, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x07, 0x01, 0x01,
        0xFF, 0x52, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x04, 0x04, 0x00, 0x01,
        0xFF, 0x5C, 0x00, 0x04, 0x40, 0x40,
        0xFF, 0x5E, 0x00, 0x05, 0x00, 0x00, 0x08, /* RGN: Crgn=0, Srgn=0, SPrgn=8 */
        0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x00, 0x01,
        0xFF, 0x93, 0x00,
        0xFF, 0xD9,
    };
    jp2z_findings_sink_t *rgs = jp2z_findings_sink_create();
    int rgsev = jp2z_deep_validate(rgn_mini, sizeof rgn_mini, 1, rgs);
    ASSERT(rgsev >= 0 && rgsev < JP2Z_SEVERITY_FAIL, "RGN-bearing mini stream (valid, unsupported feature): strict ACCEPTs");
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
        ASSERT(n145 >= 1, "the RGN mini stream exercises c145 so the invariant is non-vacuous");
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

    printf("PASS: jp2z C FFI smoke (29 assertions, version + decode + findings_sink + deep_validate + missing-EOC + over-read cap + c145-WARN invariant + POC + tile-QCD + PTERM + code-registry + anchored-diagnostics)\n");
    return 0;
}
