---
title: Array <-> vector @bitCast with differing element types is scalarized in the LLVM backend, making std.hash.XxHash3 ~30x slower than 0.16.0
priority: 1
area: codegen
targets: [all]
upstream: [codeberg#36256]
affects-line: yes
---

## Symptom

Release builds that `@bitCast` between arrays and vectors get lane-by-lane
extract/insert code instead of a plain load or bitcast. `std.hash.XxHash3`
hashing a 16 KiB buffer in ReleaseFast:

| Zig | aarch64-macos | x86_64-macos (v3, Rosetta) |
|---|---|---|
| 0.16.0 | 387 ns | 2132 ns |
| 0.17.1 | 12125 ns | 28235 ns |

## Evidence

- codeberg#36256, a 0.17-dev regression, milestone Urgent. The original
  vector-to-vector case was fixed by codeberg PR #36512 (0.17.1 already sets
  `scalarize_bit_cast_vector_non_elementwise = endian != .little`). Comments
  report array-to-vector casts still regress, with the XxHash3 benchmark
  (reporter: 411 ns on 0.16.0 vs 31283 ns on 0.17.0), and squeek502 confirms
  those comment reproductions still reproduce.
- Reproduced on 0.17.1 with the commenter's XxHash3 benchmark
  (`zig build-exe -O ReleaseFast`, 20000 iterations over 16 KiB); numbers in
  the table, same digest in all builds.
- Isolated on 0.17.1 (`-target aarch64-linux -O ReleaseFast`):
  `const v: @Vector(8, u64) = @bitCast(p.*)` with `p: *const [64]u8` is 323
  instructions vs 12 on 0.16.0; the reverse direction (vector to `[64]u8`)
  is 47 vs 12. `[8]u64` to `@Vector(8, u64)` (same element type) is
  unaffected.

## Root cause

`src/codegen/llvm.zig:39` enables the `.scalarize_bit_cast_array`
legalization unconditionally, so every array <-> vector `@bitCast` is split
per element before reaching LLVM. XxHash3 does this on its hot path
(`lib/std/hash/xxhash.zig:546`, `:575`: `@bitCast(self.secret[...].*)` to
`@Vector(8, u64)`, a `[64]u8` source). Attributing the extra code to this
flag is a guess from the issue comments and the isolated case above; not
confirmed with a patched build.

## Fix sketch

Lower array <-> vector bitcasts in `airBitCast`
(`src/codegen/llvm/FuncGen.zig`, around `:4698`) by storing to memory and
loading as the other type (what clang does for same-size reinterprets), and
drop `.scalarize_bit_cast_array` on little-endian targets the way the vector
case was handled. Medium change; needs care with padded element types and
big-endian.

## Verification

Re-run the XxHash3 benchmark from the issue in ReleaseFast; expect 0.16.0
numbers. Inspect `-femit-asm` for `const v: @Vector(16, u8) = @bitCast(arr)`
to see a single vector load.

## Notes

origin/master still has `.scalarize_bit_cast_array = true`
(`src/codegen/llvm.zig:35`, `:46`). Related: codeberg#36375 (general
ReleaseFast vector performance regression since 0.15.2).
