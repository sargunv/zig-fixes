---
title: EnumSet/EnumMap/EnumArray of a large sparse enum fails to compile with a branch-quota error the caller cannot raise
priority: 1
area: lib/std
targets: [all]
upstream: [codeberg#31316]
affects-line: yes
---

## Symptom

Instantiating `std.EnumSet(E)` (and anything else built on
`std.enums.EnumIndexer`) for an enum with about 140 or more fields whose
values are sparse fails with
`lib/std/sort/pdq.zig:22:30: error: evaluation exceeded 3013 backwards branches`.
C-derived enums in bindings typically look like this, for example Wayland's
`wl_shm_format` FourCC codes. Calling `@setEvalBranchQuota` in the caller does
not help, because `EnumIndexer` sets its own quota inside its comptime
scope.

## Evidence

- codeberg#31316, 0.16.0-dev.2637, with the 150-value `wl_shm_format` enum.
- Reproduced on 0.17.1 (aarch64-macos): the issue's enum plus
  `var s: std.EnumSet(ShmFormat) = .initEmpty(); s.insert(.c8);` gives
  `error: evaluation exceeded 3013 backwards branches` in `pdq.zig`, called
  from the `sortUnstable` in `EnumIndexer`.

## Root cause

`lib/std/enums.zig:1277-1280` sets
`@setEvalBranchQuota(3 * n * log2(n) + 10)` before the comptime
`std.mem.sortUnstable` of the field values at `lib/std/enums.zig:1332`. The
3·n·log2(n) budget is too small for pdqsort's comptime branch count:
insertion-sort inner loops, `lessThan` calls and swaps each count. The type
function is evaluated with its own quota, so the caller's quota does not
carry over. Also checked on 0.17.1: `@setEvalBranchQuota(10_000_000)` in
`main` before `std.EnumSet(E)`, where `E` is a 150-field enum with
pseudo-random values, still fails with "exceeded 3160 backwards branches".

## Fix sketch

Raise the budget generously, for example `n * n + 1000` or a large constant
floor. Or avoid the sort: the indexer only needs min/max and a dense check,
which a linear pass can compute, and the sorted order only for the sparse
case. One-line to small change.

## Verification

Compile the reproducer from codeberg#31316 (an `EnumSet` of the 150-field
`wl_shm_format` enum). Add a std test with a ~200-field enum with
pseudo-random sparse values and instantiate `EnumSet`, `EnumMap` and
`EnumArray` on it.

## Notes

`lib/std/enums.zig` is unchanged between 0.17.1 and origin/master. Similar
comptime-quota failures exist in `std.zon.parse` (codeberg#35310,
codeberg#31638); they were listed, not filed.
