---
purpose: Environment/tooling learnings discovered while working on jp2z
audience: agent
maintained_by: agent
---

# Learnings

## nix flake `./test` only sees git-tracked files (2026-06-21)

`./test` runs `nix build .#checks.<system>.test`, whose source is the
flake source (`src = ./.`). nix flakes resolve that from the **git**
working tree and **exclude untracked files**. So a newly created
fixture referenced via `@embedFile` (e.g. a new
`tests/unit/fixtures/oracles/*.t1.bin`) fails to compile in the
sandbox with `error: unable to open '<path>': FileNotFound`, even
though `nix develop -c zig build test` (which reads the real working
dir) builds fine.

Fix: make the file visible to git before `./test`. Under the **jj-only**
policy you cannot `git add` (the file is staged only by jj's snapshot,
and raw `git` is hook-blocked) — the reliable way is to **commit it**
(`jj describe` / advance `yolo`), which writes it into a git tree the
flake reads. A pure-git workflow could `git add` it without committing;
jj has no separate staging step, so just commit.

Symptom to recognize: `zig build test` (devshell) passes but `./test`
(nix) fails with `FileNotFound` on a path that exists on disk → the
path is untracked.
