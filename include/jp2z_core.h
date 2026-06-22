/* jp2z_core.h — C ABI for the jp2z cleanroom JPEG 2000 decoder.
 *
 * Mirrors the shape of jpegz's `jpegz_jp2_*` symbols (jpegz_core.h)
 * so the planned jpegz integration shim (at jp2z M6) is trivial.
 * Consumers writing against this header today get a stable surface
 * that won't churn when the cleanroom replaces the openjpeg backend.
 *
 * License: BSD-2 (same as openjpeg, the Phase 1 backend).
 */

#ifndef JP2Z_CORE_H
#define JP2Z_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>
#include <stdint.h>

/* ── Status codes (matches jp2z's DecodeError, negative-coded) ──── */

typedef enum {
    JP2Z_OK                          =  0,
    JP2Z_ERR_NOT_IMPLEMENTED         = -1,
    JP2Z_ERR_INVALID_MARKER          = -2,
    JP2Z_ERR_UNSUPPORTED_PRECISION   = -3,
    JP2Z_ERR_TRUNCATED_STREAM        = -4,
    JP2Z_ERR_BACKEND                 = -6,
    JP2Z_ERR_INVALID_JP2_CODESTREAM  = -7,
    JP2Z_ERR_OUT_OF_MEMORY           = -8,
    JP2Z_ERR_CALLBACK_ABORTED        = -9,
} jp2z_status_t;

/* ── Color space / pixel layout ─────────────────────────────────── */

typedef enum {
    JP2Z_CS_UNKNOWN        = 0,
    JP2Z_CS_GRAYSCALE      = 1,
    JP2Z_CS_RGB            = 2,
    JP2Z_CS_YCBCR          = 3,
    JP2Z_CS_CMYK           = 4,
    JP2Z_CS_YCCK           = 5,
    JP2Z_CS_SRGB           = 6,    /* JP2 enumerated colorspace 16 */
    JP2Z_CS_GREYSCALE_JP2  = 7,    /* JP2 enumerated colorspace 17 */
} jp2z_color_space_t;

typedef enum {
    JP2Z_LAYOUT_GRAYSCALE = 0,
    JP2Z_LAYOUT_RGB       = 1,
    JP2Z_LAYOUT_CMYK      = 2,
} jp2z_pixel_layout_t;

/* ── jp2z_image_t — decoded image handle ─────────────────────────── */

typedef struct {
    uint8_t              *pixels;         /* C-heap allocated; free via jp2z_image_free */
    size_t                pixels_len;
    uint32_t              width;
    uint32_t              height;
    uint8_t               channels;
    uint8_t               bits_per_sample;
    jp2z_color_space_t    source_color_space;
    jp2z_pixel_layout_t   layout;
} jp2z_image_t;

void jp2z_image_free(jp2z_image_t *image);

/* ── Last-error message (thread-local) ──────────────────────────── */

/* NUL-terminated pointer to a per-thread static buffer. Valid until
 * the next public jp2z call on the same thread. Empty string means
 * no error has been recorded. */
const char *jp2z_last_error_message(void);

/* ── Version ────────────────────────────────────────────────────── */

const char *jp2z_version(void);

/* ── Decode ─────────────────────────────────────────────────────── */

/* Decode any JP2 file or J2K raw codestream into a fully-realized
 * 8/16-bit-per-channel image. Auto-detects the format from magic
 * bytes (JP2 signature box or `FF 4F FF 51` codestream marker).
 *
 * `data` must remain valid through the call. On success returns
 * JP2Z_OK and `out_image->pixels` is populated (free via
 * jp2z_image_free). On failure, returns a negative status and
 * jp2z_last_error_message() carries the detail. */
jp2z_status_t jp2z_decode(
    const uint8_t  *data,
    size_t          len,
    jp2z_image_t   *out_image
);

/* Caller-controlled decode parameters. Identical shape to jpegz's
 * `jpegz_decode_options_t`. Total size 8 bytes; layout stable
 * across versions (new fields append into `reserved`). */
typedef struct {
    /* Thread count for parallelizable stages. 1 = sequential
     * (default). 0 = library opt-in auto-detect. >1 = explicit
     * budget. (Phase 1 wrapper ignores this; Phase 2 plumbs it
     * through to opj_codec_set_threads / cleanroom worker pools.) */
    uint8_t threads;

    /* 0 = strict decode (default). non-0 = tolerant (Phase 2:
     * recover partial images, surface findings via the
     * jp2z_decode_with_findings entry point). Phase 1 wrapper
     * ignores this — kept on the surface so Phase 2 doesn't need
     * an ABI bump. */
    uint8_t lenient;

    /* Reserved; must be zero. */
    uint8_t reserved[6];
} jp2z_decode_options_t;

jp2z_status_t jp2z_decode_ex(
    const uint8_t                       *data,
    size_t                               len,
    const jp2z_decode_options_t         *options,
    jp2z_image_t                        *out_image
);

/* ── FindingsSink ───────────────────────────────────────────────── */

/* Side-channel collector for spec-deviation findings emitted by the
 * cleanroom decoder. Phase 1 wrapper does not yet emit findings
 * (openjpeg has its own tolerance posture); Phase 2 milestones wire
 * each tolerance site. Surface is here from day 1 so consumers can
 * write against it now and get Phase 2 findings for free.
 *
 * Usage (will become meaningful in Phase 2):
 *
 *     jp2z_findings_sink_t *sink = jp2z_findings_sink_create();
 *     jp2z_decode_options_t opts = {0};
 *     opts.lenient = 1;
 *
 *     jp2z_image_t img = {0};
 *     int rc = jp2z_decode_with_findings(data, len, &opts, sink, &img);
 *
 *     for (size_t i = 0; i < jp2z_findings_sink_count(sink); i++) {
 *         jp2z_sink_finding_t f = {0};
 *         jp2z_findings_sink_get(sink, i, &f);
 *         // ...
 *     }
 *
 *     jp2z_image_free(&img);
 *     jp2z_findings_sink_free(sink);
 */
typedef struct jp2z_findings_sink jp2z_findings_sink_t;

jp2z_findings_sink_t *jp2z_findings_sink_create(void);
void                  jp2z_findings_sink_free(jp2z_findings_sink_t *sink);
size_t                jp2z_findings_sink_count(const jp2z_findings_sink_t *sink);

typedef enum {
    JP2Z_SEVERITY_PASS = 0,
    JP2Z_SEVERITY_INFO = 1,
    JP2Z_SEVERITY_WARN = 2,
    JP2Z_SEVERITY_FAIL = 3,
} jp2z_severity_t;

typedef struct {
    jp2z_severity_t  severity;
    int              code;            /* jp2z_finding_code_t numeric */
    /* INT64_MIN means "no offset"; any other value is a byte offset
     * into the input data. */
    int64_t          offset;
    const uint8_t   *detail;          /* borrowed; NOT NUL-terminated */
    size_t           detail_len;
} jp2z_sink_finding_t;

jp2z_status_t jp2z_findings_sink_get(
    const jp2z_findings_sink_t  *sink,
    size_t                       idx,
    jp2z_sink_finding_t         *out_finding
);

jp2z_status_t jp2z_decode_with_findings(
    const uint8_t                       *data,
    size_t                               len,
    const jp2z_decode_options_t         *options,
    jp2z_findings_sink_t                *sink,
    jp2z_image_t                        *out_image
);

/* Deep strict validation: structural walk + full entropy decode, emitting
 * deep-integrity findings a permissive decoder never reports. strict != 0
 * escalates them to FAIL. Findings are pushed into sink (may be NULL).
 * Returns the overall severity (>= 0) or a negative status on error. */
int jp2z_deep_validate(
    const uint8_t        *data,
    size_t                len,
    int                   strict,
    jp2z_findings_sink_t *sink
);

#ifdef __cplusplus
}
#endif

#endif /* JP2Z_CORE_H */
