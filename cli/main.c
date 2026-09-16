/* jp2z — minimal C CLI. Dogfoods the C FFI: the Zig core is reached only
 * through the public ABI (include/jp2z_core.h).
 *
 * Usage:
 *   jp2z <input.jp2 | input.j2k | ->              decode → PPM/PGM on stdout
 *   jp2z decode <input | ->                        same, explicit verb
 *   jp2z validate [--strict|--lenient] [--json] <input | ->
 *   jp2z --version
 *   jp2z -h | --help
 *
 * validate exit codes (an external probe reads them as the verdict):
 *   0  pass or info        2  warn          1  fail
 *   64 usage (EX_USAGE)    74 I/O (EX_IOERR) 70 internal (EX_SOFTWARE)
 * Findings go to stderr as text, or the whole report to stdout as JSON
 * with --json (stderr stays silent). Later flags override earlier ones.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "jp2z_core.h"

#define EX_USAGE 64
#define EX_SOFTWARE 70
#define EX_IOERR 74

static void usage(FILE *out) {
    fputs(
        "jp2z — cleanroom JPEG 2000 decoder and validator\n"
        "\n"
        "Usage:\n"
        "  jp2z <input.jp2|input.j2k|-> > output.{ppm,pgm}\n"
        "  jp2z decode <input|->\n"
        "  jp2z validate [--strict|--lenient] [--json] <input|->\n"
        "  jp2z --version\n"
        "  jp2z -h | --help\n"
        "\n"
        "validate: strict by default (deep entropy findings FAIL); --lenient\n"
        "reports them as warnings. Exit 0 pass/info, 2 warn, 1 fail; 64 usage,\n"
        "74 I/O error. Findings on stderr, or a JSON report on stdout with --json.\n"
        "Input '-' or '@stdin' reads standard input.\n",
        out);
}

static int is_stdin(const char *path) {
    return strcmp(path, "-") == 0 || strcmp(path, "@stdin") == 0;
}

/* Read a whole file (or stdin) into memory. Returns 0, or EX_IOERR. */
static int read_all(const char *path, uint8_t **out_buf, size_t *out_len) {
    FILE *f = is_stdin(path) ? stdin : fopen(path, "rb");
    if (!f) { fprintf(stderr, "jp2z: open %s: failed\n", path); return EX_IOERR; }
    size_t cap = 1 << 16, len = 0;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (!buf) { if (f != stdin) fclose(f); return EX_IOERR; }
    for (;;) {
        if (len == cap) {
            cap *= 2;
            uint8_t *nb = (uint8_t *)realloc(buf, cap);
            if (!nb) { free(buf); if (f != stdin) fclose(f); return EX_IOERR; }
            buf = nb;
        }
        size_t got = fread(buf + len, 1, cap - len, f);
        len += got;
        if (got == 0) break;
    }
    int err = ferror(f);
    if (f != stdin) fclose(f);
    if (err) { free(buf); fprintf(stderr, "jp2z: read %s: failed\n", path); return EX_IOERR; }
    *out_buf = buf;
    *out_len = len;
    return 0;
}

static const char *severity_name(int s) {
    switch (s) {
    case JP2Z_SEVERITY_PASS: return "pass";
    case JP2Z_SEVERITY_INFO: return "info";
    case JP2Z_SEVERITY_WARN: return "warn";
    case JP2Z_SEVERITY_FAIL: return "fail";
    default: return "unknown";
    }
}

/* Write s as a JSON string body (no surrounding quotes), escaping per RFC 8259. */
static void json_escape(FILE *out, const uint8_t *s, size_t n) {
    for (size_t i = 0; i < n; i++) {
        unsigned char c = s[i];
        switch (c) {
        case '"': fputs("\\\"", out); break;
        case '\\': fputs("\\\\", out); break;
        case '\n': fputs("\\n", out); break;
        case '\r': fputs("\\r", out); break;
        case '\t': fputs("\\t", out); break;
        default:
            if (c < 0x20) fprintf(out, "\\u%04x", c);
            else fputc(c, out);
        }
    }
}

static int cmd_validate(int argc, char *argv[]) {
    int strict = 1, json = 0;
    const char *path = NULL;
    for (int i = 0; i < argc; i++) {
        const char *a = argv[i];
        if (strcmp(a, "--strict") == 0) strict = 1;
        else if (strcmp(a, "--lenient") == 0) strict = 0;
        else if (strcmp(a, "--json") == 0) json = 1;
        else if (strcmp(a, "--") == 0) { if (i + 1 < argc && !path) path = argv[i + 1]; break; }
        else if (a[0] == '-' && a[1] != '\0' && !is_stdin(a)) {
            fprintf(stderr, "jp2z validate: unknown option %s\n", a);
            usage(stderr);
            return EX_USAGE;
        } else if (!path) path = a;
        else { fprintf(stderr, "jp2z validate: one input only\n"); usage(stderr); return EX_USAGE; }
    }
    if (!path) { usage(stderr); return EX_USAGE; }

    uint8_t *data = NULL;
    size_t len = 0;
    int io = read_all(path, &data, &len);
    if (io != 0) return io;

    jp2z_findings_sink_t *sink = jp2z_findings_sink_create();
    if (!sink) { free(data); return EX_SOFTWARE; }
    int overall = jp2z_deep_validate(data, len, strict, sink);
    free(data);
    if (overall < 0) {
        fprintf(stderr, "jp2z validate: internal error (%d): %s\n", overall, jp2z_last_error_message());
        jp2z_findings_sink_free(sink);
        return EX_SOFTWARE;
    }

    size_t n = jp2z_findings_sink_count(sink);
    if (json) {
        printf("{\"overall\":\"%s\",\"strict\":%s,\"findings\":[", severity_name(overall), strict ? "true" : "false");
        for (size_t i = 0; i < n; i++) {
            jp2z_sink_finding_t f;
            if (jp2z_findings_sink_get(sink, i, &f) != JP2Z_OK) continue;
            printf("%s{\"severity\":\"%s\",\"code\":%d,\"offset\":", i ? "," : "", severity_name(f.severity), f.code);
            if (f.offset == INT64_MIN) fputs("null", stdout); else printf("%lld", (long long)f.offset);
            fputs(",\"detail\":", stdout);
            if (f.detail && f.detail_len) { fputc('"', stdout); json_escape(stdout, f.detail, f.detail_len); fputc('"', stdout); }
            else fputs("null", stdout);
            fputc('}', stdout);
        }
        puts("]}");
    } else {
        for (size_t i = 0; i < n; i++) {
            jp2z_sink_finding_t f;
            if (jp2z_findings_sink_get(sink, i, &f) != JP2Z_OK) continue;
            fprintf(stderr, "%-4s c%d", severity_name(f.severity), f.code);
            if (f.offset != INT64_MIN) fprintf(stderr, " @%lld", (long long)f.offset);
            if (f.detail && f.detail_len) { fputc(' ', stderr); fwrite(f.detail, 1, f.detail_len, stderr); }
            fputc('\n', stderr);
        }
        fprintf(stderr, "overall: %s (%zu finding%s, %s)\n", severity_name(overall), n, n == 1 ? "" : "s", strict ? "strict" : "lenient");
    }
    jp2z_findings_sink_free(sink);

    switch (overall) {
    case JP2Z_SEVERITY_PASS:
    case JP2Z_SEVERITY_INFO: return 0;
    case JP2Z_SEVERITY_WARN: return 2;
    default: return 1;
    }
}

static int cmd_decode(const char *path) {
    uint8_t *data = NULL;
    size_t len = 0;
    int io = read_all(path, &data, &len);
    if (io != 0) return io;

    jp2z_image_t img = {0};
    jp2z_status_t rc = jp2z_decode(data, len, &img);
    free(data);
    if (rc != JP2Z_OK) {
        fprintf(stderr, "jp2z: decode failed (%d): %s\n", rc, jp2z_last_error_message());
        return 1;
    }

    /* Only emit 8-bit PPM/PGM for now. */
    if (img.bits_per_sample != 8) {
        fprintf(stderr, "jp2z: %d-bit output not yet wired to CLI (image decoded OK)\n",
                img.bits_per_sample);
        jp2z_image_free(&img);
        return 1;
    }

    if (img.channels == 1) {
        printf("P5\n%u %u\n255\n", img.width, img.height);
    } else if (img.channels == 3) {
        printf("P6\n%u %u\n255\n", img.width, img.height);
    } else {
        fprintf(stderr, "jp2z: %d-channel output (CMYK?) not wired to CLI yet\n", img.channels);
        jp2z_image_free(&img);
        return 1;
    }
    fwrite(img.pixels, 1, img.pixels_len, stdout);

    jp2z_image_free(&img);
    return 0;
}

int main(int argc, char *argv[]) {
    if (argc < 2) { usage(stderr); return EX_USAGE; }
    if (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) { usage(stdout); return 0; }
    if (strcmp(argv[1], "--version") == 0) {
        printf("jp2z %s\n", jp2z_version());
        return 0;
    }
    if (strcmp(argv[1], "validate") == 0) return cmd_validate(argc - 2, argv + 2);
    if (strcmp(argv[1], "decode") == 0) {
        if (argc != 3) { usage(stderr); return EX_USAGE; }
        return cmd_decode(argv[2]);
    }
    if (argc != 2) { usage(stderr); return EX_USAGE; }
    return cmd_decode(argv[1]);
}
