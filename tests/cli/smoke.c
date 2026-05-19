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

    printf("PASS: jp2z C FFI smoke (10 assertions, version + decode + findings_sink)\n");
    return 0;
}
