---
title: zig build --system panics when a needed lazy dependency is only in the global cache tarballs
priority: 1
area: build-system
targets: [all]
upstream: [codeberg#37537]
affects-line: yes
---

## Symptom

`zig build --system <dir>` aborts with `thread N panic: reached unreachable
code` (exit 134) when the build needs a lazy dependency that is missing from
`<dir>` but whose `p/<hash>.tar.gz` exists in the global cache. Expected: the
usual `error: lazy dependency package not found: <dir>/<hash>` with the note
that remote fetching is disabled in `--system` mode. Distro packagers testing a
dependency list offline hit this (libghostty packaging).

## Evidence

- codeberg#37537 (0.18.0-dev.855, macOS); a commenter's trace on Windows ends
  in `Fetch.zig:718 assert(!job_queue.read_only)` called from `run` at the
  global-cache branch.
- Reproduced on 0.17.1, aarch64-macos, with the issue's shell script (a
  `file://` tarball fetched into a private global cache, `lazyDependency("dep")`
  in `build.zig`, `zig build --system <empty dir>`): `panic: reached
  unreachable code`, exit 134.

## Root cause

`lib/compiler/Maker/Fetch.zig:656-659`: after the package is not found in local
storage (the `--system` directory), `run` checks the global cache and calls
`runResource` on the cached tarball without checking `job_queue.read_only`.
`runResource` starts with `assert(!job_queue.read_only)` (line 713). Eager
dependencies fail earlier with "package not found" (line 633), so only lazy
ones that the build actually requests reach the assert.

## Fix sketch

In `--system` mode, skip the global cache branch (fall through to the existing
read-only "not found" handling), or explicitly allow unpacking the cached
tarball into the system directory if that is intended. A few lines.

## Verification

The issue's script exits 1 with the "lazy dependency package not found"
message instead of panicking.

## Notes

Not fixed on origin/master. Related ordering problem in the same function:
cb35652 (lazy dependencies extracted from the global cache before laziness is
checked). Older report with a different stack, possibly related:
codeberg#30191.
