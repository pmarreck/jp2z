const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    // External library paths (openjpeg: build-time oracle only).
    const openjpeg_include = b.option(
        []const u8,
        "openjpeg-include",
        "Path to openjpeg headers (default: /usr/include/openjpeg-2.5)",
    ) orelse "/usr/include/openjpeg-2.5";
    const openjpeg_lib = b.option(
        []const u8,
        "openjpeg-lib",
        "Path to openjpeg libs (default: /usr/lib)",
    ) orelse "/usr/lib";

    // ── PUBLIC Zig module — what `@import("jp2z")` gets ────────────
    // Carries ZERO C attachments: validate AND decode are pure Zig since
    // Phase 3 (decode/image.zig routes the cleanroom reconstruction), so a
    // consumer links no openjpeg. Zig's lazy analysis keeps the oracle
    // (openjpeg_wrapper's @cImport behind internal.openjpegDecode) out of
    // such builds; the import-probe gate below keeps it that way.
    const jp2z_pub = b.addModule("jp2z", .{
        .root_source_file = b.path("src/jp2z.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // ── Internal oracle flavor: same root + openjpeg for the oracle ──
    // The unit tests and the sweep / tile-hist tools diff the cleanroom
    // decode against internal.openjpegDecode, so they use this instance.
    // The CLI and the archive no longer need it.
    const jp2z_mod = b.createModule(.{
        .root_source_file = b.path("src/jp2z.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    jp2z_mod.addIncludePath(.{ .cwd_relative = openjpeg_include });
    jp2z_mod.addLibraryPath(.{ .cwd_relative = openjpeg_lib });
    jp2z_mod.linkSystemLibrary("openjp2", .{});

    // ── Static library with C ABI ──────────────────────────────────
    // Rooted at lib_root.zig (public API + the C-ABI force-link) so the
    // export fns land in the archive without contaminating the module
    // root. Include path only — deliberately NO linkSystemLibrary: the
    // archive must not embed a libopenjp2.so member (the "neither ET_REL
    // nor LLVM bitcode" LLD wart); executables linking libjp2z.a resolve
    // -lopenjp2 themselves, exactly as the in-repo consumers already do.
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const lib = b.addLibrary(.{
        .name = "jp2z",
        .linkage = .static,
        .root_module = lib_mod,
    });
    lib.installHeadersDirectory(b.path("include"), "", .{
        .include_extensions = &.{".h"},
    });
    b.installArtifact(lib);

    // ── C CLI (dogfoods the FFI) ───────────────────────────────────
    const cli_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_mod.addCSourceFile(.{
        .file = b.path("cli/main.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra" },
    });
    cli_mod.addIncludePath(b.path("include"));
    cli_mod.linkLibrary(lib);
    // Phase 3: decode is the pure-Zig cleanroom route, so the CLI links no
    // openjpeg. If anything in the archive reached the wrapper again, this
    // link would fail — that is the retirement gate.
    const cli = b.addExecutable(.{
        .name = "jp2z",
        .root_module = cli_mod,
    });
    b.installArtifact(cli);

    const run_cmd = b.addRunArtifact(cli);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the jp2z CLI").dependOn(&run_cmd.step);

    // ── Conformance sweep worker (zig build sweep-one) ──────────────
    // One fixture per process so a panic on an unsupported profile is
    // isolated; the ./sweep driver builds this then runs the installed
    // zig-out/bin/jp2z-sweep-one per file with SWEEP_FIXTURE set.
    const sweep_mod = b.createModule(.{
        .root_source_file = b.path("tools/sweep_one.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sweep_mod.addImport("jp2z", jp2z_mod);
    sweep_mod.addIncludePath(.{ .cwd_relative = openjpeg_include });
    sweep_mod.addLibraryPath(.{ .cwd_relative = openjpeg_lib });
    sweep_mod.linkSystemLibrary("openjp2", .{});
    const sweep_one = b.addExecutable(.{
        .name = "jp2z-sweep-one",
        .root_module = sweep_mod,
    });
    // Dev/conformance tool — NOT in the default (shipped) install, so
    // `nix build`/Garnix stay lean. Input arrives via the SWEEP_FIXTURE env
    // var (0.16 dropped std.process.argsAlloc); the step only builds+installs.
    const sweep_install = b.addInstallArtifact(sweep_one, .{});
    b.step("sweep-one", "Build the conformance-sweep worker (input: SWEEP_FIXTURE=<abs-path>)").dependOn(&sweep_install.step);

    // ── Per-tile diff histogram (zig build tile-hist) ──────────────
    // Same shape as sweep-one; prints per-tile max_abs vs the openjpeg
    // oracle for one fixture. Decode-divergence diagnostic, dev-only.
    const hist_mod = b.createModule(.{
        .root_source_file = b.path("tools/tile_hist.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    hist_mod.addImport("jp2z", jp2z_mod);
    hist_mod.addIncludePath(.{ .cwd_relative = openjpeg_include });
    hist_mod.addLibraryPath(.{ .cwd_relative = openjpeg_lib });
    hist_mod.linkSystemLibrary("openjp2", .{});
    const tile_hist = b.addExecutable(.{ .name = "jp2z-tile-hist", .root_module = hist_mod });
    const hist_install = b.addInstallArtifact(tile_hist, .{});
    b.step("tile-hist", "Build the per-tile diff histogram tool (input: SWEEP_FIXTURE=<abs-path>)").dependOn(&hist_install.step);

    // ── Tests ──────────────────────────────────────────────────────
    const test_step = b.step("test", "Run unit + CLI tests");

    // (1) Inline tests inside jp2z.zig and the modules it imports.
    const inline_mod = b.createModule(.{
        .root_source_file = b.path("src/jp2z.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    inline_mod.addIncludePath(.{ .cwd_relative = openjpeg_include });
    inline_mod.addLibraryPath(.{ .cwd_relative = openjpeg_lib });
    inline_mod.linkSystemLibrary("openjp2", .{});
    const inline_tests = b.addTest(.{
        .name = "jp2z_inline",
        .root_module = inline_mod,
    });
    test_step.dependOn(&b.addRunArtifact(inline_tests).step);

    // (2) Smoke test (public-API wiring).
    const smoke_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit/smoke.zig"),
        .target = target,
        .optimize = optimize,
    });
    smoke_mod.addImport("jp2z", jp2z_mod);
    const smoke_tests = b.addTest(.{
        .name = "smoke",
        .root_module = smoke_mod,
    });
    test_step.dependOn(&b.addRunArtifact(smoke_tests).step);

    // (3) Decode test suite.
    const decode_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit/decode.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // for std.c.getenv in the corpus test
    });
    decode_mod.addImport("jp2z", jp2z_mod);
    const decode_tests = b.addTest(.{
        .name = "decode",
        .root_module = decode_mod,
    });
    test_step.dependOn(&b.addRunArtifact(decode_tests).step);

    // (4) Validate test suite.
    const validate_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit/validate.zig"),
        .target = target,
        .optimize = optimize,
    });
    validate_mod.addImport("jp2z", jp2z_mod);
    const validate_tests = b.addTest(.{
        .name = "validate",
        .root_module = validate_mod,
    });
    test_step.dependOn(&b.addRunArtifact(validate_tests).step);

    // (4b) Module-import gate (MFIC; jpegz U1 contract): a validate-only
    //      consumer of the PUBLIC module must build+link with zero C deps
    //      (no openjpeg include/lib anywhere on its graph). See
    //      tests/import_probe.zig for what a RED here means.
    const probe_mod = b.createModule(.{
        .root_source_file = b.path("tests/import_probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    probe_mod.addImport("jp2z", jp2z_pub);
    const probe_exe = b.addExecutable(.{
        .name = "import_probe",
        .root_module = probe_mod,
    });
    const run_probe = b.addRunArtifact(probe_exe);
    test_step.dependOn(&run_probe.step);
    b.step("import-probe", "Gate: validate-only consumer of the public jp2z module builds with zero C deps").dependOn(&run_probe.step);

    // (4c) Mutation classifier: valid controls plus deterministic sniper,
    //      bolter, and shotgun mutations through the public pure-Zig strict
    //      API. This module deliberately imports jp2z_pub, not jp2z_mod.
    const mutation_mod = b.createModule(.{
        .root_source_file = b.path("tests/mutation_matrix.zig"),
        .target = target,
        .optimize = optimize,
        // libc only for std.c.getenv (the MUTATION_MATRIX_DUMP scorecard dump);
        // the validator under test stays the pure-Zig public module.
        .link_libc = true,
    });
    mutation_mod.addImport("jp2z", jp2z_pub);
    const mutation_tests = b.addTest(.{
        .name = "mutation_matrix",
        .root_module = mutation_mod,
    });
    const run_mutation_tests = b.addRunArtifact(mutation_tests);
    test_step.dependOn(&run_mutation_tests.step);
    b.step("mutation-matrix", "Classify strict-validation controls and deterministic mutation scales").dependOn(&run_mutation_tests.step);

    // (5) C FFI smoke test — links the static lib and runs the CLI
    //     test program (exercises every C ABI entry point).
    const cli_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_test_mod.addCSourceFile(.{
        .file = b.path("tests/cli/smoke.c"),
        .flags = &.{ "-std=c23", "-Wall", "-Wextra" },
    });
    cli_test_mod.addIncludePath(b.path("include"));
    cli_test_mod.linkLibrary(lib); // no openjpeg: the archive must stand alone
    const cli_test = b.addExecutable(.{
        .name = "ffi_smoke",
        .root_module = cli_test_mod,
    });
    const run_cli_test = b.addRunArtifact(cli_test);
    test_step.dependOn(&run_cli_test.step);

    // (6) End-to-end CLI test — spawns the actual `jp2z` binary
    //     against vendored conformance fixtures, validates the
    //     PPM/PGM stdout, and byte-compares the pixel body against
    //     opj_decompress (when present on $PATH; gracefully skipped
    //     otherwise so the test still runs in minimal environments).
    const e2e_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    e2e_mod.addCSourceFile(.{
        .file = b.path("tests/cli/e2e.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra" },
    });
    const e2e_exe = b.addExecutable(.{
        .name = "cli_e2e",
        .root_module = e2e_mod,
    });

    // Grayscale fixture: c1_mono.j2c → P5/PGM 303x179.
    const run_e2e_mono = b.addRunArtifact(e2e_exe);
    run_e2e_mono.addArtifactArg(cli); // resolves to zig-out/bin/jp2z
    run_e2e_mono.addFileArg(b.path("tests/unit/fixtures/conformance/c1_mono.j2c"));
    run_e2e_mono.addArgs(&.{ "pgm", "303", "179" });
    test_step.dependOn(&run_e2e_mono.step);

    // RGB fixture: d1_colr.j2c → P6/PPM 256x149.
    const run_e2e_rgb = b.addRunArtifact(e2e_exe);
    run_e2e_rgb.addArtifactArg(cli);
    run_e2e_rgb.addFileArg(b.path("tests/unit/fixtures/conformance/d1_colr.j2c"));
    run_e2e_rgb.addArgs(&.{ "ppm", "256", "149" });
    test_step.dependOn(&run_e2e_rgb.step);
}
