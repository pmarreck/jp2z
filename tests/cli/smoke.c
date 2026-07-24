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

/* Numeric finding codes the header exposes only as `int` (jp2z_finding_code_t
 * is not published in the C ABI). Kept in sync with src/core/errors.zig. */
#define JP2Z_FINDING_MISSING_EOI 2

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

    /* relaxed mode preserves WARN — structural, not unconditionally fatal. */
    jp2z_findings_sink_t *rs = jp2z_findings_sink_create();
    int rsev = jp2z_deep_validate(a1, a1_len - 2, 0, rs);
    ASSERT(rsev >= 0 && rsev < JP2Z_SEVERITY_FAIL, "missing-EOC: relaxed deep_validate keeps WARN (no FAIL)");
    jp2z_findings_sink_free(rs);

    printf("PASS: jp2z C FFI smoke (17 assertions, version + decode + findings_sink + deep_validate + missing-EOC strict/relaxed)\n");
    return 0;
}
