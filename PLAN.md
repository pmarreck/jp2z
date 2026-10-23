# PLAN

What is left to do, in priority order. Completed items are retired to docs/PLAN_LOG.md; background for an open item lives in docs/plan_context/ and is linked from the item. Purpose and scope: INTENT.md.

## Open work

- [ ] Entropy-tail discriminator: compare the unread bytes with the coder's own FLUSH output before calling a tail of 3 surplus, so a conforming tail and a flipped-byte tail can be told apart (context: docs/plan_context/entropy_tail_discriminator.md)
- [ ] Mutation vocabulary part (c): rerun corruption-probe with the v2 operators when a bounded same-profile campaign is authorized, recording version and parameters and counting crashes separately from rejections (context: docs/plan_context/mutation_vocabulary.md)

## Build architecture conformance (cross-platform-project-build-arch skill, 2026-10-23)

- [x] Namespace the Zig install prefix as zig-out/<PF>/[musl|gnu]/<profile>/ with explicit PF-to-triple translation in build.zig and ./build; park the Nix output link under .nix-out/<PF>/<profile> and stop copying result/bin into zig-out (done 2026-10-23 18:37 EDT) (context: docs/plan_context/cross_platform_build_arch.md)
- [x] Publish bin/<PF>/jp2z as a relative link to the selected product (Windows .exe form without symlink privileges), only after a verified build, preserving the previous entrypoint on failure and serializing competing publications; ignore bin/<PF>/, .nix-out/, .build-work/ and dist/ (done 2026-10-23 18:37 EDT) (context: docs/plan_context/cross_platform_build_arch.md)
- [x] ./build: keep Nix as the default backend, add --backend=direct with the documented zig build equivalent, --debug and --test profiles, and --all-plats/--all-platforms/--all over the declared five-target matrix that reports a missing builder as a failure; the legacy build_all (BDFN's former build-all) retires into ./build --all, single implementation so no canonize; update README and callers; add ./run (done 2026-10-23 18:37 EDT) (context: docs/plan_context/cross_platform_build_arch.md)
- [x] Full five-target matrix built, not only declared (BDFN 2026-10-23: wanted regardless of single implementation): build.zig and per-target flake packages for linux-amd64 and linux-arm64 (musl), macos-arm64, mswin-amd64 and mswin-arm64 (gnu), build metadata (triple, profile, libc) beside each product, header and loader inspection of every product, and .mechatron-prime/targets extended with the cross packages the x86_64-linux worker can build; macOS and Windows runtime tests stay labelled pending (done 2026-10-23 18:37 EDT) (context: docs/plan_context/cross_platform_build_arch.md)
- [x] Point sweep, probe-label, corruption-coverage and the C end-to-end test at exact namespaced products so ./test and the campaigns never resolve a PATH or flat zig-out/bin binary (done 2026-10-23 18:37 EDT) (context: docs/plan_context/cross_platform_build_arch.md)
- [ ] Run the skill's acceptance scenarios (coexisting host, foreign and profile builds; header and loader inspection of published products; failure keeps the previous entrypoint; no store-link write-through; case-insensitive name coexistence) and record commands, platforms exercised and gaps in the context file before claiming conformance (context: docs/plan_context/cross_platform_build_arch.md)
- [ ] `jp2z --about` reports the build target as `PF=<OS>-<ARCH>` plus `VARIANT=musl|gnu` where it applies (today it prints `(linux x86_64)`), red-first in the CLI test, from compile-time target macros rather than the build host (context: docs/plan_context/cross_platform_build_arch.md)

## Encoder and the decode/encode/verify CLI (BDFN, 2026-10-23)

- [x] Interface coordinator sign-off for the additive encode surface in the frozen v1 contract (jp2z_encode, jp2z_buffer_free, params/buffer/format types, statuses -10/-11, jp2z.encode); request sent 2026-10-23 15:30 EDT; approved 16:11 EDT as additive contract v1.1, non-overlap clause added to the header, docs/INTERFACE_CONTRACT.md updated; normal test and build gates still apply (done 2026-10-23 16:20 EDT) (context: docs/plan_context/encoder_and_cli.md)
- [x] Move the spec-written MQ encoder into the library and add the forward 5/3 wavelet and RCT, each red-first with exact inverse round trips against the existing decoder halves (done 2026-10-23 18:37 EDT) (context: docs/plan_context/encoder_and_cli.md)
- [x] Tier-1 EBCOT encoding (significance, refinement, cleanup passes with the 19 contexts) and tier-2 packet formation (tag trees, inclusion, zero bit-planes, pass counts, lengths) for one tile, one layer, LRCP, so decode(encode(x)) == x exactly (done 2026-10-23 18:37 EDT) (context: docs/plan_context/encoder_and_cli.md)
- [x] Codestream and JP2 writer (SIZ, COD, QCD, SOT/SOD, EOC; JP2 with ihdr and colr) behind jp2z_encode in the C ABI with explicit buffer ownership; every encoded test image decodes exactly in jp2z and OpenJPEG and passes strict validation with nothing above INFO (done 2026-10-23 18:37 EDT) (context: docs/plan_context/encoder_and_cli.md)
- [x] C CLI: `jp2z encode [--jp2|--j2k] <pgm|ppm|-> [-o out|-]` through the C ABI only, `verify` as an alias of validate, help and --about updated, Bash CLI tests for all three verbs including stdin, stdout and a path with spaces (done 2026-10-23 18:37 EDT) (context: docs/plan_context/encoder_and_cli.md)
- [ ] Encoded outputs join the mutation-matrix controls and ./corruption-coverage as known-good inputs (context: docs/plan_context/encoder_and_cli.md)
- [ ] Follow-on: irreversible 9/7 with quantization and rate control, multiple layers, tiling and the other progression orders (context: docs/plan_context/encoder_and_cli.md)

## Recently completed
