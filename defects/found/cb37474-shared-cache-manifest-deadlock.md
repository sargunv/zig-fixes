---
title: Concurrent compilations sharing a cache directory deadlock on manifest locks
priority: 1
area: build-system
targets: [all]
upstream: [codeberg#37474]
affects-line: yes
---

## Symptom

Two `zig build-lib` processes that share `--cache-dir` can hang forever. One
compiles C sources `a.c, b.c` and the other `b.c, a.c` (different contents,
same paths relative to their build roots). Each holds a shared lock on its
first object's manifest while waiting for an exclusive lock on the manifest
the other one holds. Separate cache directories avoid the hang. Concurrent
`zig build` / `zig cc` runs from several worktrees or CI jobs that share a
cache can hit this.

## Evidence

- codeberg#37474 (0.18.0-dev.738), found through the Acton build system. A
  comment gives a Python repro (`repro.py`): two roots, 15000-function
  `a.c`/`b.c` each, `build-lib -j1 -OReleaseFast --build-root <root>` with a
  shared `--cache-dir`, run concurrently with a 20 s timeout.
- Reproduced on 0.17.1, aarch64-macos: `ZIG=<0.17.1 zig> python3 repro.py`
  printed `timed out: [None, None]` in 3 of 3 runs. The same build alone
  finishes in 4.8 s.

## Root cause

Not investigated beyond the reporter's diagnosis. The manifest lock states
live in `lib/std/Build/Cache.zig` (`want_shared_lock`, line 281;
`upgradeToExclusiveLock`, line 2049). Compiled C objects keep a held lock
(`man.toOwnedLock()` in `src/Compilation.zig`, about lines 5909, 6051, 6171)
while later objects are checked, so the locks are taken in an order that
depends on the input order.

## Fix sketch

Not investigated. Options: release or downgrade object manifest locks before
taking the next manifest's exclusive lock; use non-blocking lock attempts with
a back-off-and-retry; or take locks in a canonical order.

## Verification

The `repro.py` from the issue comment, run against the fixed compiler, should
print `finished: [0, 0]`.

## Notes

The manifest doc comment (`Cache.zig:278`) promises that several processes can
use one cache directory at the same time.
