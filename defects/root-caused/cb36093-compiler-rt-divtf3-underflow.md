---
title: compiler-rt __divtf3 returns a wrong nonzero result on deep f128 underflow
priority: 1
area: bundled-libc
targets: [all]
upstream: [codeberg#36093]
affects-line: yes
---

## Symptom

f128 division whose result underflows far below the smallest subnormal
returns garbage instead of signed zero. With `--debug-rt` it traps:
`integerOutOfBounds` at `compiler_rt/divtf3.zig:230`
(`@as(u7, @intCast(1 - writtenExponent))`). This hits Zig `f128` everywhere
and C `long double` on targets where it is binary128 (aarch64-linux,
riscv64-linux, loongarch64-linux) built with `zig cc`.

## Evidence

- Reported on 0.17.0-dev.1286 with `zig test repro.zig --debug-rt`
  (`floatMin(f128) / floatMax(f128)`), also seen in behavior tests
  (codeberg#36093).
- Reproduced a wrong result on 0.17.1 (aarch64-macos, normal rt):
  `floatMin(f128) / 0x1p200` (true value 2^-16582, below 2^-16494) prints
  `q=7.11953033571e-4954 bits=0x10000000000` in Debug and ReleaseFast;
  expected `0`.

## Root cause

`lib/compiler_rt/divtf3.zig:233-238`: `shiftAmount` is computed as
`@as(u7, @intCast(1 - writtenExponent))` *before* the
`if (shiftAmount > significandBits) return signed zero` check. For
`1 - writtenExponent >= 128` the cast is illegal; without safety it truncates
(200 becomes 72), passes the check, and produces a bogus subnormal.

## Fix sketch

Compare `1 - writtenExponent` against `significandBits` as a wide signed integer
first and return signed zero, then cast. Check the sibling division routines
(`divdf3`, `divsf3`, `divxf3`) for the same pattern. A few lines.

## Verification

`zig test repro.zig --debug-rt` from the issue passes; add a compiler-rt test
for `floatMin(f128) / 0x1p200 == 0`.

## Notes

The block was added by 07b08b9638 (#30198, in 0.17.1). origin/master still
has the same line.
