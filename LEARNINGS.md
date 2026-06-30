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

## Zig 0.16: non-test executables need their own `Io` context (2026-06-30)

Tests use `std.testing.io`, but that symbol is `@compileError` outside
`builtin.is_test`. A non-test exe doing file I/O must build its own context:

    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

Then file ops take that `io`: `std.Io.Dir.openFileAbsolute(io, path, .{})`,
`file.reader(io, &.{}).interface.allocRemaining(alloc, .limited(n))`. The gpa
passed to `.init` must be threadsafe but is only touched by `Io.async` (which
plain file reads never call) — `page_allocator` is fine.

Also removed in 0.16 (all bit `tools/sweep_one.zig` during the sweep-harness
port): `std.process.argsAlloc` (read args/env via `std.c.getenv` + `std.mem.span`
with link_libc, exactly like `tests/unit/decode.zig` reads OPENJPEG_DATA), and
`std.io.getStdOut` / `std.io.fixedBufferStream` (route simple output through
`std.debug.print`, which writes stderr — have the consumer grep for it).
