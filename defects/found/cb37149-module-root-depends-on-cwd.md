---
title: Root module path depends on cwd, so `zig build` from a subdirectory fails with "import of file outside module path"
priority: 1
area: compiler
targets: [all]
upstream: [codeberg#37149]
affects-line: yes
---

## Symptom

A project whose `main.zig` does `@import("foo/foo.zig")` builds from the
project root. From inside `foo/`, both `zig build` and `zig build-exe
../main.zig` fail with:
`main.zig:2:17: error: import of file outside module path`. `--build-root`
does not help.

## Evidence

- codeberg#37149 (0.18.0-dev.120). A commenter bisected it to versions that
  have `--build-root` (0.17.0-dev.1902 onward); 0.16.0 and
  0.17.0-dev.1267 work.
- Reproduced on 0.17.1, aarch64-macos: with `p/main.zig`, `p/foo/foo.zig` and
  a minimal `build.zig`/`build.zig.zon`, `zig build` in `p/` exits 0, and
  `zig build` in `p/foo/` fails with the error above. `zig build-exe
  ../main.zig` from `p/foo/` fails the same way.

## Root cause

Not investigated in depth. Guess: `Compilation.Path.fromUnresolved`
(`src/Compilation.zig:499`) resolves the root source directory relative to
`dirs.cwd`. When the build root is the cwd (`path == null`) and the module
directory is `..`, it keeps `..` as the sub-path. As a result,
`foo/foo.zig` resolves outside the module root.

## Fix sketch

Not investigated.

## Verification

From a subdirectory of a project, `zig build` should behave as it does from
the project root. Add a standalone test that runs `zig build` with the cwd set
to a subdirectory.

## Notes

The `zig build` runner passes the absolute root source path, yet the
compilation still fails, so the bug is in how the compiler derives the module
root, not in the build runner.
