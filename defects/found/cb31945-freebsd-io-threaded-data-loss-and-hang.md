---
title: std.Io.Threaded on FreeBSD intermittently loses read/write data and hangs in join
priority: 1
area: lib/std
targets: [x86_64-freebsd, aarch64-freebsd]
upstream: [codeberg#31945, codeberg#36458]
affects-line: likely
---

## Symptom

On FreeBSD, rarely and intermittently:

- Output is truncated or replaced at the start (the cmakedefine standalone
  test got `s TEXT` with a NUL instead of `// becomes TEXT`), and the compiler
  appears to read incomplete source files (`root source file struct 'enums'
  has no member named 'directEnumArrayLen'`) (codeberg#31945).
- `std.Io.Threaded.deinit()` hangs in `join()`: the main thread waits in
  `WaitGroup.wait` while a worker sleeps in `condWait`, both in `_umtx_op`
  (codeberg#36458).

## Evidence

- Both reported by alexrp from upstream FreeBSD CI (April and August 2026,
  0.17.0-dev). He says the data loss is specific to FreeBSD and has not been
  seen on NetBSD or OpenBSD.
- Not reproduced (no FreeBSD host). No fix found in `git log origin/master`
  (master only has unrelated FreeBSD `std.c` signature fixes).

## Root cause

Not investigated. alexrp is unsure whether the hang is a race in the join
logic or a bug in the FreeBSD futex implementation
(`lib/std/Io/Threaded.zig:1035`, `_umtx_op` with `WAIT_UINT_PRIVATE`). Whether
the two symptoms share a cause is unknown.

## Fix sketch

Not investigated.

## Verification

Stress loop on FreeBSD: run the `cmakedefine` standalone test and a
`Threaded.init`/`Group.async`/`deinit` loop thousands of times with no
truncation and no hang.

## Notes

Affects the Zig compiler when hosted on FreeBSD and any Zig program built
for FreeBSD that uses `std.Io.Threaded`. Both issues are on upstream's
"Urgent" milestone.
