# Conformance to the cross-platform project build architecture

Gap analysis written 2026-10-23 against the shared
`cross-platform-project-build-arch` skill (fleet naming contract of the same
date). This records what jp2z does today, what the convention requires, and
the acceptance scenarios the migration must pass. It is a plan, not a claim
of conformance; the skill's verification reference says that matching its
wording or creating correctly named directories proves nothing.

## Vocabulary

PF is `<OS>-<ARCH>` with OS in {linux, macos, mswin} and ARCH in {amd64,
arm64}; VARIANT is `gnu` or `musl` only where it applies. The supported
matrix is macos-arm64, linux-amd64, linux-arm64, mswin-amd64, mswin-arm64.
Compiler triples keep their own spelling and are translated explicitly at
the tool boundary: linux-amd64 is `x86_64-linux-musl`, linux-arm64 is
`aarch64-linux-musl`, macos-arm64 is `aarch64-macos`, mswin-amd64 is
`x86_64-windows-gnu`, mswin-arm64 is `aarch64-windows-gnu`; the Nix system
name for the worker stays `x86_64-linux`.

## Today

- `build.zig` installs everything (the CLI, the static archive and header,
  the four dev tools) into Zig's default flat prefix `zig-out/bin`,
  `zig-out/lib`, `zig-out/include`, with no PF, variant or profile in the path.
- `./build` runs `nix build` for `packages.default`, leaves the `result`
  link at the project root, then copies `result/bin/jp2z` into
  `zig-out/bin/`. That mixes the Nix product into the direct-build prefix, so
  the two destinations can overwrite each other.
- `build_all` is an underscore-named stub whose body is a TODO from the
  openjpeg era; the runtime package has had no openjpeg since 2026-09-06, so
  the reason it was deferred is gone. No `./run` or `./build-and-run`.
- No `bin/<PF>/` entrypoint exists; nothing in this project is meant to be
  on PATH yet, and `zig-out/bin` must never be admitted to PATH discovery.
- The flake exposes one package (`default`, host only) and two checks; the
  Mechatron Prime target manifest lists those checks for x86_64-linux. No
  per-target packages, so no cross-compiled products exist to publish.
- The dev scripts `sweep`, `probe-label` and `corruption-coverage` resolve
  tools at `zig-out/bin/<name>`; the Zig test graph uses run artifacts, which
  is already the exact-product resolution the skill requires. Whether the
  C end-to-end test receives the CLI as a build-graph artifact or by path is
  to be verified during the migration.
- Profiles: ReleaseFast by default, ReleaseSafe in the test check; no
  build metadata (triple, profile, libc) is recorded beside the products.
- `.gitignore` covers `zig-out/`, `result`, `result-*`; it has no rules yet
  for `bin/<PF>/`, `.nix-out/`, `.build-work/` or `dist/`.
- One implementation (Zig core behind a C ABI, a C CLI dogfooding it), so
  the canonical-implementation machinery (`CANONICAL_IMPL`, `./build
  canonize`, `--all-impls`) does not apply; the skill says single-
  implementation projects need no artificial selection. Revisit only if a
  standalone C implementation is added.

## Target state

```text
bin/linux-amd64/jp2z -> ../../zig-out/linux-amd64/musl/ReleaseFast/bin/jp2z
zig-out/<PF>/[<VARIANT>/]<profile>/{bin,lib,include}/
.nix-out/<PF>/<profile> -> /nix/store/...-jp2z
.build-work/<PF>/<profile>/        (intermediates, if any; caches stay in .zig-cache)
dist/<version>/<PF>/               (release archives, never on PATH)
```

`./build` stays Nix by default with an explicit `--backend=direct` path and
documented equivalent `zig build` command; `--debug` and `--test` select
profiles; `--all-plats` / `--all-platforms` builds the declared matrix and
reports a missing builder as a failure, never as an excluded target. `./run`
builds the host product if stale and launches that exact CLI. `build_all` is
retired in favor of `./build --all-platforms`, with README and any callers
updated in the same change. Only the host PF's directory and generic `bin/`
are PATH candidates; PATH discovery itself belongs to the dotfiles owner and
is coordinated, not done here.

## Acceptance scenarios to pass (from the skill's verification reference)

1. Build the host CLI, then a foreign target, then another profile: outputs
   coexist and the host entrypoint is unchanged.
2. Inspect the published product's ELF, Mach-O or PE header and loader/libc
   requirements; the manifest copied from the build command is not the oracle.
3. Force a build failure: the previous entrypoint still works; two competing
   publications do not corrupt each other (no sleeps in the test).
4. Native and Nix destinations cannot overwrite one another or write through
   a store link; generated outputs and links are ignored by Git without hiding
   tracked scripts.
5. `./test` resolves exact products; a stale `jp2z` on PATH cannot make it
   green.
6. Windows products run without Unix symlink privileges (`.exe` entrypoint
   form); a Linux cross-compile is compile evidence only, and macOS/Windows
   runtime tests are labelled pending until run natively.
7. `build` and any intermediate directory coexist on a case-insensitive
   filesystem; no case-only name distinctions.
