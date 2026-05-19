# jp2z — Next Session Handoff

Created: 2026-05-18, by the same Claude session that brought jpegz
to "cleanroom-only at runtime" (commits up through `0b01ec9`).

## Status at handoff

**Scaffolded but not yet built.** All files are written; no `nix
build` / `nix flake check` has run yet against this tree. The
project layout mirrors jpegz exactly:

```
jp2z/
├── README.md, PROJECT_OVERVIEW.md, PLAN.md, CODE_MINIMAP.md, this file
├── flake.nix, build.zig, build.zig.zon
├── build, test, build_all (scripts)
├── src/
│   ├── jp2z.zig            (public API hub)
│   ├── core/{errors,types,last_error}.zig
│   ├── decode/findings.zig
│   └── ffi/{openjpeg_wrapper,c_api}.zig
├── include/jp2z_core.h
├── cli/main.c
└── tests/{unit,cli,fixtures}/
```

## Pick this up in 4 steps

### Step 1 — confirm the build green

```bash
cd ~/Documents-CloudManaged/jp2z
./test
```

Expected outcome: `nix flake check` builds the static lib + C CLI,
runs the smoke tests, returns 0. If it doesn't, the most likely
culprits are:

- **openjpeg include/lib paths in `flake.nix`** — pinned to
  `openjpeg-2.5`. If nixpkgs has bumped to 2.6+ the include subdir
  changed (look for `openjpeg-2.6`). Fix: parameterize in
  `flake.nix:25-26` or update the constant.

- **`build.zig.zon` fingerprint** — set to `0x0` placeholder. First
  `zig build` will reject this with an error showing the correct
  value. Drop that value into `build.zig.zon:11`.

- **Linker can't find `libopenjp2`** — the build.zig uses
  `linkSystemLibrary("openjp2", .{})`; on macOS via nix this should
  resolve via the path passed to `-Dopenjpeg-lib=`. If it doesn't,
  check `flake.nix:34` is passing the path through.

### Step 2 — git init + first commit

The user typically uses `setup_zig_repo` (a shell function) for
new Zig projects — it sets up `jj`/`git` init, symlinks
`AGENTS.md`/`CLAUDE.md` from a template, adds the `jj` cheatsheet
and Zig API-change reference. **Ask the user to run that first**
(or do it yourself if their shell exports the function).

After setup_zig_repo, run:

```bash
git add -A
git status   # confirm nothing surprising
git commit -m "Scaffold jp2z: openjpeg wrapper backend + C ABI mirror of jpegz_jp2_*"
```

Then create the GitHub repo:

```bash
gh repo create pmarreck/jp2z --public --source=. --push
```

Garnix is org-wide installed — CI fires automatically.

### Step 3 — add a JP2/J2K fixture

`tests/unit/fixtures/` is empty. `tests/unit/decode.zig` is a
SkipZigTest stub waiting on real fixtures. Mirror jpegz's
`scratch/gen_*_fixtures.{c,sh}` pattern:

Easiest path — use openjpeg's CLI inside the devShell:

```bash
nix develop -c bash -c '
  # 4x4 RGB ppm — simple gradient
  printf "P6\n4 4\n255\n" > /tmp/4x4.ppm
  for y in 0 1 2 3; do for x in 0 1 2 3; do
    printf "$(printf \\\\%03o ${x}0)$(printf \\\\%03o ${y}0)$(printf \\\\%03o $((x+y)))" \
      >> /tmp/4x4.ppm
  done; done

  opj_compress -i /tmp/4x4.ppm -o tests/unit/fixtures/4x4_rgb.j2k
  opj_compress -i /tmp/4x4.ppm -o tests/unit/fixtures/4x4_rgb.jp2
'
```

(openjpeg-tools provides `opj_compress`; verify it's in the
devShell via `nix develop -c which opj_compress`. If not, add
`pkgs.openjpeg.bin` to `flake.nix:devShells.packages`.)

Then write the first real decode test (replace the SkipZigTest in
`tests/unit/decode.zig`):

```zig
const fixture_4x4_rgb_jp2 = @embedFile("fixtures/4x4_rgb.jp2");

test "decode 4x4 RGB JP2 via openjpeg wrapper" {
    const allocator = std.testing.allocator;
    var img = try jp2z.decode(allocator, fixture_4x4_rgb_jp2);
    defer img.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), img.width);
    try std.testing.expectEqual(@as(u32, 4), img.height);
    try std.testing.expectEqual(@as(u8, 3), img.channels);
    try std.testing.expectEqual(jp2z.PixelLayout.rgb, img.layout);
}
```

This proves the openjpeg wrapper round-trips a real file. `./test`
should go from "stub passing" to "real decode passing."

### Step 4 — start Phase 2 cleanroom (your call when)

Once the wrapper-backed v1 is green and a couple more fixtures
exist (gray + RGB + 16-bit, plus a known-bad codestream for the
M1 walker), open `PLAN.md` and pick the next milestone. The
recommended order is the order PLAN.md lists:

**M1 — codestream walker + minimal headers.** Parse SOC / SIZ /
COD / QCD / SOD / EOC markers. No entropy decode yet. Validates
that the file structure is sound; surfaces structural findings
via `FindingsSink`. Mirrors `jpegz/src/core/validator.zig`'s
shape but for T.800 markers instead of T.81.

Each subsequent milestone (M2 tier-2, M3 EBCOT, M4 wavelet 5/3,
M5 wavelet 9/7, M6 MCT) adds a new decode/<topic>.zig module and
shrinks the wrapper's runtime role. At M6 the dispatcher in
`src/jp2z.zig:decodeWithOptions` switches from "delegate to
wrapper" to "try cleanroom paths first, wrapper only if
NotImplemented", then eventually "cleanroom-only at runtime"
once parity is established (mirroring exactly what jpegz did
between commits `b6bc669` and `0b01ec9`).

## Integration with jpegz (later)

At jp2z M6 (cleanroom complete), do the jpegz side of the
integration:

```zig
// jpegz/src/jpegz.zig — replace the openjpeg-wrapper body of
// the jpeg2000 namespace with a re-export:
pub const jpeg2000 = struct {
    const jp2z = @import("jp2z");
    pub const decode = jp2z.decode;
    pub const decodeWithOptions = jp2z.decodeWithOptions;
    pub const validate = jp2z.validate;
};
```

Then:
- Add jp2z as a Zig dependency in `jpegz/build.zig.zon`
- Delete `jpegz/src/ffi/openjpeg_wrapper.zig`
- Remove openjpeg from `jpegz/flake.nix` (jpegz becomes truly
  cleanroom-only at runtime, no asterisks)

## Design decisions already baked in

- **C ABI naming**: `jp2z_*` symbols (e.g., `jp2z_decode`,
  `jp2z_findings_sink_create`). Mirrors jpegz's `jpegz_jp2_*`
  shape so the integration shim is either pure-Zig (above) or
  C-level aliasing if needed.

- **Vocabulary parity with jpegz**: `Severity`, `FindingCode`,
  `Image`, `PixelLayout`, `DecodeError` are structurally identical.
  No translation layer needed at the boundary.

- **lenient + FindingsSink on the public API from day 1**: even
  though the Phase 1 wrapper ignores them, the surface is stable
  so Phase 2 cleanroom can wire them without ABI churn.

- **Integer/fixed-point only in production code paths**: same
  project-wide rule jpegz observes. Wavelet implementations
  (M4/M5) use fixed-point, no `f32`/`f64`.

- **JP2 Part 1 only**: Part 2 (JPX) extensions are out of scope —
  murkier IP, less universal need. Documented in
  `PROJECT_OVERVIEW.md`.

## Things explicitly left for you (the next LLM) to decide

- **JP2 fixture corpus shape**: pick the 3-5 baseline fixtures
  worth committing. My recommendation: 4×4 gray, 4×4 RGB,
  16×16 RGB (5/3 lossless), 16×16 RGB (9/7 lossy), 8×8 gray
  16-bit. Plus 1-2 known-bad codestreams for M1 walker testing.

- **CI scope**: should `./build_all` cross-compile for all 5
  platforms like jpegz does? openjpeg cross-build is non-trivial;
  Phase 2 retires the dep anyway. Honest answer: leave
  cross-compile off until M6, then it becomes trivial.

- **Inbox handling**: jpegz has an `inbox/` for inter-LLM
  messaging. jp2z will likely receive messages from jpegz once
  the M6 integration begins. The `.gitignore` already excludes
  `inbox/` per convention.

## Reference

- jpegz's relevant commits to study before starting cleanroom:
  - `3e4056b` — FindingsSink infrastructure (start)
  - `90f90fa` — Lenient mode baseline cleanroom
  - `f1488df` — Public Zig + C ABI parity for lenient + sink
  - `24b34fe` — Validator migrated to cleanroom
  - `0b01ec9` — Dispatcher fallbacks stripped (cleanroom-only)
- T.800 spec (ITU-T Rec. T.800 / ISO 15444-1) — free PDF from
  the ITU; Annex C (tier-1 EBCOT) and Annex F (wavelet) are the
  load-bearing chapters
- charls equivalent reference for jp2z is openjpeg itself —
  use `nix develop -c bash -c 'echo $CHARLS_SRC'`-style
  technique to read `pkgs.openjpeg.src` if you need to compare
  against the reference implementation

Good luck. The architecture is well-grooved from jpegz's arc;
this is mostly methodical port work plus genuine new algorithm
in the wavelet/EBCOT modules.
