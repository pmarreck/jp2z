/* jp2z — minimal C CLI. Decodes a JP2 or J2K file and writes a
 * PPM (RGB) or PGM (grayscale) to stdout. Dogfoods the C FFI; the
 * Zig core is reached only through the public ABI.
 *
 * Usage:
 *   jp2z <input.jp2 | input.j2k > output.ppm
 *   jp2z --version
 *   jp2z -h | --help
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "jp2z_core.h"

static void usage(FILE *out) {
    fputs(
        "jp2z — cleanroom JPEG 2000 decoder\n"
        "\n"
        "Usage:\n"
        "  jp2z <input.jp2|input.j2k> > output.{ppm,pgm}\n"
        "  jp2z --version\n"
        "  jp2z -h | --help\n",
        out);
}

static int read_all(const char *path, uint8_t **out_buf, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "jp2z: open %s: failed\n", path); return 1; }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n < 0) { fclose(f); return 1; }
    uint8_t *buf = (uint8_t *)malloc((size_t)n);
    if (!buf) { fclose(f); return 1; }
    size_t got = fread(buf, 1, (size_t)n, f);
    fclose(f);
    if (got != (size_t)n) { free(buf); return 1; }
    *out_buf = buf;
    *out_len = (size_t)n;
    return 0;
}

int main(int argc, char *argv[]) {
    if (argc != 2) { usage(stderr); return 2; }
    if (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) { usage(stdout); return 0; }
    if (strcmp(argv[1], "--version") == 0) {
        printf("jp2z %s\n", jp2z_version());
        return 0;
    }

    uint8_t *data = NULL;
    size_t len = 0;
    if (read_all(argv[1], &data, &len) != 0) return 1;

    jp2z_image_t img = {0};
    jp2z_status_t rc = jp2z_decode(data, len, &img);
    free(data);
    if (rc != JP2Z_OK) {
        fprintf(stderr, "jp2z: decode failed (%d): %s\n", rc, jp2z_last_error_message());
        return 1;
    }

    /* Only emit 8-bit PPM/PGM for now (Phase 1 minimum). */
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
