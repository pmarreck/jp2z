/* jp2z — end-to-end CLI integration test.
 *
 * Spawns the built `jp2z` CLI binary against a vendored conformance
 * fixture, captures its PPM/PGM stdout, then spawns `opj_decompress`
 * against the same fixture and compares the two outputs byte-for-byte
 * (modulo the optional PPM/PGM "# comment" header line that openjpeg
 * inserts but we don't).
 *
 * Invoked from build.zig as the (6) E2E CLI test. Args:
 *   argv[1]  path to jp2z CLI executable (resolved by Zig's build system)
 *   argv[2]  path to fixture file (.j2c / .j2k / .jp2)
 *   argv[3]  expected output kind: "pgm" or "ppm"
 *   argv[4]  expected width
 *   argv[5]  expected height
 *
 * `opj_decompress` is located on $PATH (provided by the Nix devShell
 * and by the openjpeg buildInput in checks.test). When it isn't
 * available we skip the oracle comparison and just validate that the
 * CLI's PPM/PGM is well-formed and matches the expected dimensions —
 * so `zig build test` still works in minimal environments.
 *
 * Exit codes follow the same convention as the FFI smoke test:
 *   0 success, 1 assertion failure, 2 setup/IO failure.
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define FAIL(...) do { \
    fprintf(stderr, "FAIL (%s:%d): ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); \
    fputc('\n', stderr); \
    return 1; \
} while (0)

#define SETUP_FAIL(...) do { \
    fprintf(stderr, "SETUP (%s:%d): ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); \
    fputc('\n', stderr); \
    return 2; \
} while (0)

/* Read entire file into a malloc'd buffer. Caller free()s. */
static int slurp(const char *path, unsigned char **out_buf, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return -1; }
    long n = ftell(f);
    if (n < 0) { fclose(f); return -1; }
    if (fseek(f, 0, SEEK_SET) != 0) { fclose(f); return -1; }
    unsigned char *buf = (unsigned char *)malloc((size_t)n);
    if (!buf) { fclose(f); return -1; }
    size_t got = fread(buf, 1, (size_t)n, f);
    fclose(f);
    if (got != (size_t)n) { free(buf); return -1; }
    *out_buf = buf;
    *out_len = (size_t)n;
    return 0;
}

/* Spawn argv[0]…argv[N] with stdout redirected to `stdout_path`.
 * stderr is left alone so failures surface in the build log.
 * Returns the child's exit status (0 = success), or -1 on spawn error. */
static int spawn_capture(char *const argv[], const char *stdout_path) {
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        int fd = open(stdout_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) { perror("open stdout"); _exit(127); }
        if (dup2(fd, STDOUT_FILENO) < 0) { perror("dup2"); _exit(127); }
        close(fd);
        execvp(argv[0], argv);
        perror("execvp");
        _exit(127);
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) return -1;
    if (!WIFEXITED(status)) return -1;
    return WEXITSTATUS(status);
}

/* Parse a PPM/PGM header. On success returns the offset of the first
 * pixel byte; fills width/height/maxval/expected_magic. Comment lines
 * starting with '#' are skipped per the netpbm spec.
 *
 * `expected_magic` is "P5" (PGM) or "P6" (PPM). */
static int parse_pnm_header(const unsigned char *buf, size_t len,
                            const char *expected_magic,
                            long *out_width, long *out_height,
                            long *out_maxval, size_t *out_body_off) {
    if (len < 2 || buf[0] != expected_magic[0] || buf[1] != expected_magic[1]) return -1;
    size_t i = 2;
    if (i >= len || (buf[i] != '\n' && buf[i] != ' ' && buf[i] != '\t')) return -1;

    long values[3] = {0, 0, 0};
    int got = 0;

    while (i < len && got < 3) {
        /* skip whitespace */
        while (i < len && (buf[i] == ' ' || buf[i] == '\t' ||
                           buf[i] == '\n' || buf[i] == '\r')) {
            i++;
        }
        /* skip comments */
        if (i < len && buf[i] == '#') {
            while (i < len && buf[i] != '\n') i++;
            continue;
        }
        if (i >= len) break;
        /* parse a non-negative integer */
        long v = 0;
        int any = 0;
        while (i < len && buf[i] >= '0' && buf[i] <= '9') {
            v = v * 10 + (buf[i] - '0');
            i++;
            any = 1;
        }
        if (!any) return -1;
        values[got++] = v;
    }
    if (got != 3) return -1;
    /* exactly one whitespace byte separates maxval from the pixel data */
    if (i >= len) return -1;
    if (buf[i] != '\n' && buf[i] != ' ' && buf[i] != '\t' && buf[i] != '\r') return -1;
    i++;

    *out_width = values[0];
    *out_height = values[1];
    *out_maxval = values[2];
    *out_body_off = i;
    return 0;
}

/* True if opj_decompress is invocable on PATH. */
static int oracle_available(void) {
    /* Cheap probe: `opj_decompress -h` exits 1 but doesn't fail to
     * spawn. We just check that execvp doesn't ENOENT. */
    pid_t pid = fork();
    if (pid < 0) return 0;
    if (pid == 0) {
        /* silence the child */
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) {
            dup2(devnull, STDOUT_FILENO);
            dup2(devnull, STDERR_FILENO);
            close(devnull);
        }
        char *argv[] = { (char *)"opj_decompress", (char *)"-h", NULL };
        execvp(argv[0], argv);
        _exit(127);
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) return 0;
    if (!WIFEXITED(status)) return 0;
    return WEXITSTATUS(status) != 127;
}

int main(int argc, char *argv[]) {
    if (argc != 6) {
        SETUP_FAIL("usage: %s <jp2z-cli> <fixture> <pgm|ppm> <width> <height>",
                   argv[0] ? argv[0] : "e2e");
    }
    const char *cli_path = argv[1];
    const char *fixture = argv[2];
    const char *kind = argv[3];
    long want_w = strtol(argv[4], NULL, 10);
    long want_h = strtol(argv[5], NULL, 10);

    const char *expected_magic;
    int channels;
    if (strcmp(kind, "pgm") == 0) { expected_magic = "P5"; channels = 1; }
    else if (strcmp(kind, "ppm") == 0) { expected_magic = "P6"; channels = 3; }
    else SETUP_FAIL("unknown kind '%s' (expected pgm|ppm)", kind);

    /* Per-PID tmp paths so parallel test runs don't clobber. */
    char our_out[256], oracle_out[256];
    snprintf(our_out, sizeof our_out, "/tmp/jp2z_e2e_ours_%ld.pnm", (long)getpid());
    snprintf(oracle_out, sizeof oracle_out, "/tmp/jp2z_e2e_oracle_%ld.pnm", (long)getpid());

    /* (1) Run our CLI, capture stdout to a file. */
    {
        char *argv_cli[] = { (char *)cli_path, (char *)fixture, NULL };
        int rc = spawn_capture(argv_cli, our_out);
        if (rc != 0) {
            unlink(our_out);
            FAIL("jp2z CLI exited with %d (fixture=%s)", rc, fixture);
        }
    }

    unsigned char *ours = NULL;
    size_t ours_len = 0;
    if (slurp(our_out, &ours, &ours_len) != 0) {
        unlink(our_out);
        SETUP_FAIL("slurp(%s) failed: %s", our_out, strerror(errno));
    }
    unlink(our_out);

    /* (2) Validate our CLI's PPM/PGM is well-formed. */
    long w, h, maxval;
    size_t body_off;
    if (parse_pnm_header(ours, ours_len, expected_magic, &w, &h, &maxval, &body_off) != 0) {
        free(ours);
        FAIL("jp2z output is not a valid %s (first 16 bytes: %.16s)", expected_magic, ours);
    }
    if (w != want_w || h != want_h) {
        free(ours);
        FAIL("jp2z output dims %ldx%ld, expected %ldx%ld", w, h, want_w, want_h);
    }
    if (maxval != 255) {
        free(ours);
        FAIL("jp2z maxval %ld, expected 255", maxval);
    }
    size_t expected_body = (size_t)w * (size_t)h * (size_t)channels;
    if (ours_len - body_off != expected_body) {
        free(ours);
        FAIL("jp2z body len %zu, expected %zu", ours_len - body_off, expected_body);
    }

    /* (3) Oracle comparison: opj_decompress against the same fixture.
     *     Skipped (with a clear log line) if opj_decompress isn't on PATH. */
    if (!oracle_available()) {
        free(ours);
        fprintf(stderr, "NOTE: opj_decompress not on PATH; skipped oracle compare.\n");
        printf("PASS: jp2z CLI e2e (header+body length, no oracle) — %s %ldx%ld\n", kind, w, h);
        return 0;
    }

    {
        char *argv_oracle[] = {
            (char *)"opj_decompress",
            (char *)"-i", (char *)fixture,
            (char *)"-o", (char *)oracle_out,
            NULL,
        };
        /* opj_decompress writes its own file; spawn_capture's stdout
         * redirect is harmless (suppresses its chatter). */
        int rc = spawn_capture(argv_oracle, "/dev/null");
        if (rc != 0) {
            free(ours);
            unlink(oracle_out);
            FAIL("opj_decompress exited with %d (fixture=%s)", rc, fixture);
        }
    }

    unsigned char *oracle = NULL;
    size_t oracle_len = 0;
    if (slurp(oracle_out, &oracle, &oracle_len) != 0) {
        free(ours);
        unlink(oracle_out);
        SETUP_FAIL("slurp(%s) failed: %s", oracle_out, strerror(errno));
    }
    unlink(oracle_out);

    /* (4) Parse oracle header (it has a "# OpenJPEG-…" comment line). */
    long ow, oh, omaxval;
    size_t obody_off;
    if (parse_pnm_header(oracle, oracle_len, expected_magic, &ow, &oh, &omaxval, &obody_off) != 0) {
        free(ours);
        free(oracle);
        FAIL("oracle output is not a valid %s", expected_magic);
    }
    if (ow != w || oh != h || omaxval != maxval) {
        free(ours);
        free(oracle);
        FAIL("header mismatch ours=%ldx%ld@%ld oracle=%ldx%ld@%ld",
             w, h, maxval, ow, oh, omaxval);
    }
    size_t oracle_body_len = oracle_len - obody_off;
    if (oracle_body_len != expected_body) {
        free(ours);
        free(oracle);
        FAIL("oracle body len %zu, expected %zu", oracle_body_len, expected_body);
    }

    /* (5) Byte-perfect pixel-body compare. */
    if (memcmp(ours + body_off, oracle + obody_off, expected_body) != 0) {
        /* find first mismatch for a useful diagnostic */
        size_t first = 0;
        const unsigned char *a = ours + body_off;
        const unsigned char *b = oracle + obody_off;
        while (first < expected_body && a[first] == b[first]) first++;
        free(ours);
        free(oracle);
        FAIL("pixel mismatch at byte %zu: ours=0x%02x oracle=0x%02x",
             first, a[first], b[first]);
    }

    free(ours);
    free(oracle);
    printf("PASS: jp2z CLI e2e — %s %ldx%ld, %zu pixel bytes match opj_decompress\n",
           kind, w, h, expected_body);
    return 0;
}
