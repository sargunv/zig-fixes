---
title: std.mem.swap takes noalias pointers but std.sort swaps an element with itself, so release builds sort wrongly
priority: 1
area: lib/std
targets: [all]
upstream: [codeberg#37590]
affects-line: yes
---

## Symptom

`std.mem.swap(T, noalias a, noalias b)` is called with `a == b` by
`std.sort.heap`/`heapContext` (last pop), `pdq` (several sites), `block`,
`std.Random.shuffle`, and `MultiArrayList.sortUnstable`. Under LLVM the
noalias violation lets the optimizer produce wrong results. The issue's
`lensHeap` program sorts `{5, 4}` into `{5, 5}` at ReleaseSafe.

## Evidence

- codeberg#37590 (0.17.0 and 0.18.0-dev.935). The reporter's table lists every
  self-swap site at a7808addac.
- Reproduced on 0.17.1, aarch64-macos, with the issue's `r.zig`:
  `-O Debug` prints `heap: 504`; `-O ReleaseSafe` and `-O ReleaseFast` both
  print `heap: 505` (wrong). The reporter saw only ReleaseSafe wrong on
  x86_64, so which modes fail depends on the target.

## Root cause

`lib/std/mem.zig:3930` declares `swap` with `noalias` parameters. Its callers
pass the same pointer twice: `lib/std/sort.zig:94` (`context.swap(a, i)` with
`i == a` on the final iteration), plus the pdq, block and shuffle sites the
issue lists.

## Fix sketch

Per the reporter (who says a PR is coming): drop `noalias` from
`std.mem.swap`. For small `T`, load both values before storing either; for
large `T`, return early when `a == b`. Also make `heapContext` and
`pdqContext` stop calling `swap(i, i)`, since user contexts may forward to
`mem.swap` or use an XOR swap. Small change.

## Verification

Run the issue's `r.zig` in all four optimize modes; each should print
`heap: 504`. Add a std test that sorts with a context whose `swap` asserts
`a != b`.

## Notes

As of this sweep, origin/master still has `noalias` on `std.mem.swap`. The
reporter notes that upstream PR #36743 rewrites `swap` but keeps `noalias`.
