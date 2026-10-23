/* jp2z — C CLI. Dogfoods the C FFI: the Zig core is reached only through
 * the public ABI (include/jp2z_core.h).
 *
 * Usage:
 *   jp2z <input.jp2 | input.j2k | ->               decode → PNM on stdout
 *   jp2z decode [-o OUT] <input | ->               same, explicit verb
 *   jp2z encode [--jp2|--j2k] [--levels N] [-o OUT] <input.pgm|.ppm|.pam | ->
 *   jp2z validate [--strict|--lenient] [--json] <input | ->
 *   jp2z verify ...                                 alias of validate
 *   jp2z --version | --about | -h | --help
 *
 * Exit codes: 0 success (validate: pass or info), 1 decode failure or
 * validate FAIL, 2 validate WARN, 64 usage (EX_USAGE), 65 bad input data
 * (EX_DATAERR), 70 internal (EX_SOFTWARE), 74 I/O (EX_IOERR).
 * Inputs take '-' or '@stdin'; outputs take '-' or '@stdout'. Later flags
 * override earlier ones.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

#include "jp2z_core.h"

#define EX_USAGE 64
#define EX_DATAERR 65
#define EX_SOFTWARE 70
#define EX_IOERR 74

/* Build platform for --about, from the compiler's predefined macros. */
#if defined(__APPLE__)
#define JP2Z_PLATFORM "macos"
#elif defined(_WIN32)
#define JP2Z_PLATFORM "windows"
#elif defined(__linux__)
#define JP2Z_PLATFORM "linux"
#else
#define JP2Z_PLATFORM "unknown-os"
#endif
#if defined(__aarch64__) || defined(_M_ARM64)
#define JP2Z_ARCH "aarch64"
#elif defined(__x86_64__) || defined(_M_X64)
#define JP2Z_ARCH "x86_64"
#else
#define JP2Z_ARCH "unknown-arch"
#endif

static void usage(FILE *out) {
    fputs(
        "jp2z — cleanroom JPEG 2000 codec and validator\n"
        "\n"
        "Usage:\n"
        "  jp2z <input.jp2|input.j2k|-> > output.{pgm,ppm,pam}\n"
        "  jp2z decode [-o OUT] <input|->\n"
        "  jp2z encode [--jp2|--j2k] [--levels N] [-o OUT] <input.pgm|.ppm|.pam|->\n"
        "  jp2z validate [--strict|--lenient] [--json] <input|->\n"
        "  jp2z verify ...   (same as validate)\n"
        "  jp2z --version\n"
        "  jp2z --about\n"
        "  jp2z -h | --help\n"
        "\n"
        "decode: writes binary PNM (P5 grey, P6 RGB, P7 PAM otherwise), 16-bit\n"
        "big-endian samples above 8 bits, MAXVAL 2^precision - 1.\n"
        "encode: lossless JPEG 2000 (reversible 5/3 wavelet, RCT for 3+ components)\n"
        "from binary PNM (P5, P6, P7); MAXVAL m is coded at the bits m needs.\n"
        "JP2 by default; --j2k writes a raw codestream. --levels sets the wavelet\n"
        "decomposition levels (0..32; default min(5, log2 of the larger side)).\n"
        "validate / verify: strict by default (deep entropy findings FAIL); --lenient\n"
        "reports them as warnings. Exit 0 pass/info, 2 warn, 1 fail. Findings on\n"
        "stderr, or a JSON report on stdout with --json.\n"
        "Input '-' or '@stdin' reads standard input; -o '-' or '@stdout' (the\n"
        "default) writes standard output. Exit 64 usage, 65 bad input data,\n"
        "74 I/O error.\n",
        out);
}

static int is_stdin(const char *path) {
    return strcmp(path, "-") == 0 || strcmp(path, "@stdin") == 0;
}

static int is_stdout(const char *path) {
    return path == NULL || strcmp(path, "-") == 0 || strcmp(path, "@stdout") == 0;
}

/* Image bytes must pass through stdio untranslated on Windows. */
static void binary_stdio(void) {
#ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
#endif
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

/* Write head then body to path (NULL/'-'/'@stdout' = stdout). A file that
 * could not be completely written is removed. Returns 0, or EX_IOERR. */
static int write_out(const char *path, const uint8_t *head, size_t head_len, const uint8_t *body, size_t body_len) {
    int to_stdout = is_stdout(path);
    FILE *f = to_stdout ? stdout : fopen(path, "wb");
    if (!f) { fprintf(stderr, "jp2z: open %s for writing: failed\n", path); return EX_IOERR; }
    int ok = fwrite(head, 1, head_len, f) == head_len && fwrite(body, 1, body_len, f) == body_len;
    ok = (to_stdout ? fflush(f) == 0 : fclose(f) == 0) && ok;
    if (!ok) {
        fprintf(stderr, "jp2z: write %s: failed\n", to_stdout ? "standard output" : path);
        if (!to_stdout) remove(path);
        return EX_IOERR;
    }
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

/* Decode to binary PNM. */
static int cmd_decode(int argc, char *argv[]) {
    const char *in = NULL, *out = NULL;
    for (int i = 0; i < argc; i++) {
        const char *a = argv[i];
        if (strcmp(a, "-o") == 0) {
            if (i + 1 >= argc) { fputs("jp2z decode: -o needs a path\n", stderr); return EX_USAGE; }
            out = argv[++i];
        } else if (strcmp(a, "--") == 0) { if (i + 1 < argc && !in) in = argv[i + 1]; break; }
        else if (a[0] == '-' && a[1] != '\0' && !is_stdin(a)) {
            fprintf(stderr, "jp2z decode: unknown option %s\n", a); usage(stderr); return EX_USAGE;
        } else if (!in) in = a;
        else { fputs("jp2z decode: one input only\n", stderr); usage(stderr); return EX_USAGE; }
    }
    if (!in) { usage(stderr); return EX_USAGE; }

    uint8_t *data = NULL;
    size_t len = 0;
    int io = read_all(in, &data, &len);
    if (io != 0) return io;
    jp2z_image_t img = {0};
    jp2z_status_t rc = jp2z_decode(data, len, &img);
    free(data);
    if (rc != JP2Z_OK) {
        fprintf(stderr, "jp2z: decode failed (%d): %s\n", rc, jp2z_last_error_message());
        return 1;
    }

    unsigned maxval = (1u << img.bits_per_sample) - 1u;
    char head[160];
    int hl;
    if (img.channels == 1) hl = snprintf(head, sizeof head, "P5\n%u %u\n%u\n", img.width, img.height, maxval);
    else if (img.channels == 3) hl = snprintf(head, sizeof head, "P6\n%u %u\n%u\n", img.width, img.height, maxval);
    else
        /* Any other channel count: PAM (P7), whose DEPTH is unbounded. CMYK
         * gets its tuple type; the rest carry no colour semantics. */
        hl = snprintf(head, sizeof head, "P7\nWIDTH %u\nHEIGHT %u\nDEPTH %u\nMAXVAL %u\nTUPLTYPE %s\nENDHDR\n",
                      img.width, img.height, (unsigned)img.channels, maxval,
                      img.layout == JP2Z_LAYOUT_CMYK ? "CMYK" : "MULTICHANNEL");
    /* PNM stores samples above 8 bits big-endian; the ABI hands them native. */
    if (img.bits_per_sample > 8) {
        for (size_t i = 0; i + 1 < img.pixels_len; i += 2) {
            uint16_t v;
            memcpy(&v, img.pixels + i, 2);
            img.pixels[i] = (uint8_t)(v >> 8);
            img.pixels[i + 1] = (uint8_t)(v & 0xFF);
        }
    }
    int w = write_out(out, (const uint8_t *)head, (size_t)hl, img.pixels, img.pixels_len);
    jp2z_image_free(&img);
    return w;
}

/* A parsed binary PNM: geometry plus the offset of its sample bytes. */
typedef struct {
    uint32_t width, height, depth, maxval;
    size_t body;
} pnm_t;

static int pnm_space(uint8_t c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f'; }

/* Next unsigned decimal header field of a P5/P6 header, skipping
 * whitespace and '#' comments. Returns 0 on success. */
static int pnm_uint(const uint8_t *b, size_t n, size_t *pos, uint32_t *out) {
    size_t p = *pos;
    for (;;) {
        while (p < n && pnm_space(b[p])) p++;
        if (p < n && b[p] == '#') { while (p < n && b[p] != '\n') p++; continue; }
        break;
    }
    if (p >= n || b[p] < '0' || b[p] > '9') return 1;
    uint64_t v = 0;
    while (p < n && b[p] >= '0' && b[p] <= '9') {
        v = v * 10 + (uint64_t)(b[p++] - '0');
        if (v > UINT32_MAX) return 1;
    }
    *out = (uint32_t)v;
    *pos = p;
    return 0;
}

/* Parse a P5, P6 or P7 header. On failure writes a reason and returns 1. */
static int pnm_parse(const uint8_t *b, size_t n, pnm_t *img, char *why, size_t why_len) {
    if (n < 2 || b[0] != 'P') { snprintf(why, why_len, "not a PNM file"); return 1; }
    char kind = n >= 2 ? (char)b[1] : 0;
    size_t p = 2;
    if (kind == '5' || kind == '6') {
        img->depth = kind == '5' ? 1 : 3;
        if (pnm_uint(b, n, &p, &img->width) || pnm_uint(b, n, &p, &img->height) || pnm_uint(b, n, &p, &img->maxval)) {
            snprintf(why, why_len, "malformed P%c header", kind); return 1;
        }
        if (p >= n || !pnm_space(b[p])) { snprintf(why, why_len, "P%c header must end in one whitespace byte", kind); return 1; }
        img->body = p + 1;
    } else if (kind == '7') {
        int have = 0; /* bit 0 WIDTH, 1 HEIGHT, 2 DEPTH, 3 MAXVAL */
        for (;;) {
            while (p < n && pnm_space(b[p])) p++;
            if (p >= n) { snprintf(why, why_len, "P7 header has no ENDHDR"); return 1; }
            if (b[p] == '#') { while (p < n && b[p] != '\n') p++; continue; }
            size_t s = p;
            while (p < n && !pnm_space(b[p])) p++;
            size_t kl = p - s;
            if (kl == 6 && memcmp(b + s, "ENDHDR", 6) == 0) {
                if (p >= n || b[p] != '\n') { snprintf(why, why_len, "ENDHDR must end its line"); return 1; }
                img->body = p + 1;
                break;
            }
            if (kl == 8 && memcmp(b + s, "TUPLTYPE", 8) == 0) { while (p < n && b[p] != '\n') p++; continue; }
            uint32_t *dst = NULL;
            int bit = 0;
            if (kl == 5 && memcmp(b + s, "WIDTH", 5) == 0) { dst = &img->width; bit = 1; }
            else if (kl == 6 && memcmp(b + s, "HEIGHT", 6) == 0) { dst = &img->height; bit = 2; }
            else if (kl == 5 && memcmp(b + s, "DEPTH", 5) == 0) { dst = &img->depth; bit = 4; }
            else if (kl == 6 && memcmp(b + s, "MAXVAL", 6) == 0) { dst = &img->maxval; bit = 8; }
            else { snprintf(why, why_len, "unknown P7 header token %.*s", (int)(kl > 32 ? 32 : kl), (const char *)(b + s)); return 1; }
            while (p < n && (b[p] == ' ' || b[p] == '\t')) p++;
            if (p >= n || b[p] < '0' || b[p] > '9' || pnm_uint(b, n, &p, dst)) { snprintf(why, why_len, "P7 header field without a number"); return 1; }
            have |= bit;
        }
        if (have != 15) { snprintf(why, why_len, "P7 header lacks WIDTH, HEIGHT, DEPTH or MAXVAL"); return 1; }
    } else {
        snprintf(why, why_len, "P%c is not supported (binary P5, P6 and P7 only)", kind >= 0x20 && kind < 0x7F ? kind : '?');
        return 1;
    }
    if (img->width == 0 || img->height == 0 || img->depth == 0) { snprintf(why, why_len, "zero width, height or depth"); return 1; }
    if (img->depth > 16384) { snprintf(why, why_len, "depth %u exceeds 16384 components", img->depth); return 1; }
    if (img->maxval == 0 || img->maxval > 65535) { snprintf(why, why_len, "MAXVAL %u is outside 1..65535", img->maxval); return 1; }
    return 0;
}

/* Encode a binary PNM to JPEG 2000. */
static int cmd_encode(int argc, char *argv[]) {
    const char *in = NULL, *out = NULL;
    int format = JP2Z_FORMAT_JP2;
    unsigned levels = JP2Z_LEVELS_DEFAULT;
    for (int i = 0; i < argc; i++) {
        const char *a = argv[i];
        if (strcmp(a, "--jp2") == 0) format = JP2Z_FORMAT_JP2;
        else if (strcmp(a, "--j2k") == 0) format = JP2Z_FORMAT_J2K;
        else if (strcmp(a, "-o") == 0) {
            if (i + 1 >= argc) { fputs("jp2z encode: -o needs a path\n", stderr); return EX_USAGE; }
            out = argv[++i];
        } else if (strcmp(a, "--levels") == 0) {
            if (i + 1 >= argc) { fputs("jp2z encode: --levels needs a number\n", stderr); return EX_USAGE; }
            const char *v = argv[++i];
            char *end = NULL;
            unsigned long lv = strtoul(v, &end, 10);
            if (v[0] < '0' || v[0] > '9' || *end != '\0' || lv > 32) {
                fprintf(stderr, "jp2z encode: --levels %s is not a number in 0..32\n", v);
                return EX_USAGE;
            }
            levels = (unsigned)lv;
        } else if (strcmp(a, "--") == 0) { if (i + 1 < argc && !in) in = argv[i + 1]; break; }
        else if (a[0] == '-' && a[1] != '\0' && !is_stdin(a)) {
            fprintf(stderr, "jp2z encode: unknown option %s\n", a); usage(stderr); return EX_USAGE;
        } else if (!in) in = a;
        else { fputs("jp2z encode: one input only\n", stderr); usage(stderr); return EX_USAGE; }
    }
    if (!in) { usage(stderr); return EX_USAGE; }

    uint8_t *data = NULL;
    size_t len = 0;
    int io = read_all(in, &data, &len);
    if (io != 0) return io;

    pnm_t pnm = {0};
    char why[160];
    if (pnm_parse(data, len, &pnm, why, sizeof why)) {
        fprintf(stderr, "jp2z encode: %s: %s\n", is_stdin(in) ? "standard input" : in, why);
        free(data);
        return EX_DATAERR;
    }
    unsigned precision = 0;
    while ((1u << precision) - 1u < pnm.maxval) precision++;
    size_t bps = pnm.maxval > 255 ? 2 : 1;
    size_t count = (size_t)pnm.width * pnm.height;
    if (pnm.height != 0 && count / pnm.height != pnm.width) count = SIZE_MAX;
    size_t need = count > SIZE_MAX / pnm.depth / bps ? SIZE_MAX : count * pnm.depth * bps;
    size_t avail = len - pnm.body;
    if (need == SIZE_MAX || avail != need) {
        if (need != SIZE_MAX && avail > need)
            fprintf(stderr, "jp2z encode: %zu bytes follow the image (multi-image PNM is not supported)\n", avail - need);
        else
            fprintf(stderr, "jp2z encode: image body is %zu bytes; %ux%ux%u at MAXVAL %u needs %zu\n",
                    avail, pnm.width, pnm.height, pnm.depth, pnm.maxval, need);
        free(data);
        return EX_DATAERR;
    }
    /* PNM's big-endian 16-bit samples become the ABI's native uint16_t; a
     * sample above MAXVAL is malformed input, never silently coded. */
    uint8_t *samples = data + pnm.body;
    for (size_t i = 0; i < need; i += bps) {
        unsigned v = bps == 2 ? ((unsigned)samples[i] << 8) | samples[i + 1] : samples[i];
        if (v > pnm.maxval) {
            fprintf(stderr, "jp2z encode: sample %zu is %u, above MAXVAL %u\n", i / bps, v, pnm.maxval);
            free(data);
            return EX_DATAERR;
        }
        if (bps == 2) { uint16_t nv = (uint16_t)v; memcpy(samples + i, &nv, 2); }
    }

    jp2z_encode_params_t ep = {0};
    ep.width = pnm.width;
    ep.height = pnm.height;
    ep.components = (uint16_t)pnm.depth;
    ep.precision = (uint8_t)precision;
    ep.levels = (uint8_t)levels;
    ep.format = (uint8_t)format;
    jp2z_buffer_t enc = {0};
    jp2z_status_t rc = jp2z_encode(samples, need, &ep, &enc);
    free(data);
    if (rc != JP2Z_OK) {
        fprintf(stderr, "jp2z encode: failed (%d): %s\n", rc, jp2z_last_error_message());
        return rc == JP2Z_ERR_INVALID_ARGUMENT || rc == JP2Z_ERR_UNSUPPORTED_PRECISION ? EX_DATAERR : EX_SOFTWARE;
    }
    int w = write_out(out, NULL, 0, enc.data, enc.len);
    jp2z_buffer_free(&enc);
    return w;
}

int main(int argc, char *argv[]) {
    binary_stdio();
    if (argc < 2) { usage(stderr); return EX_USAGE; }
    if (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) { usage(stdout); return 0; }
    if (strcmp(argv[1], "--about") == 0) {
        /* One line: what it is, the version, and the platform it was built for. */
        printf("jp2z %s: pure-Zig JPEG 2000 Part 1 codec and validator (%s %s)\n",
               jp2z_version(), JP2Z_PLATFORM, JP2Z_ARCH);
        return 0;
    }
    if (strcmp(argv[1], "--version") == 0) {
        printf("jp2z %s\n", jp2z_version());
        return 0;
    }
    if (strcmp(argv[1], "validate") == 0 || strcmp(argv[1], "verify") == 0) return cmd_validate(argc - 2, argv + 2);
    if (strcmp(argv[1], "decode") == 0) return cmd_decode(argc - 2, argv + 2);
    if (strcmp(argv[1], "encode") == 0) return cmd_encode(argc - 2, argv + 2);
    if (argc != 2) { usage(stderr); return EX_USAGE; }
    return cmd_decode(1, argv + 1);
}
