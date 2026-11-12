---
title: "@mod on floats returns the wrong value for negative divisors (LLVM backend and comptime)"
priority: 1
area: codegen
targets: [all]
upstream: [codeberg#36333, github#6714]
affects-line: yes
---

## Symptom

`@mod(10.0, -3.0)` on `f32`/`f64` gives `1` at runtime and at comptime. The
langref requires `@divFloor(a, b) * b + @mod(a, b) == a`, so the answer must
be `-2`; with the current result the identity gives `13`. Integer `@mod`
gives `-2` correctly.

## Evidence

- codeberg#36333, reported on 0.17.0-dev.1476 and 0.16.0. The reporter saw
  `-2` at runtime only with the self-hosted backend in Debug.
- Reproduced on 0.17.1 (aarch64-macos native, Debug, ReleaseSafe and
  ReleaseFast; x86_64-macos Debug under Rosetta): `comptime=1 runtime=1
  divFloor=-4 identity=13`. `@mod(@as(i32, 10), -3)` prints `-2`.
- The 0.17.1 langref (`doc/langref.html.in:5270-5280`) only requires
  `denominator != 0` and states the identity.

## Root cause

`src/codegen/llvm/FuncGen.zig:3710-3719` lowers float `@mod` as
`a = fmod(lhs, rhs); c = fmod(a + rhs, rhs); select(lhs < 0, c, a)`. This
only adjusts when the *numerator* is negative, which is correct only for a
positive divisor. Comptime evaluation in `src/Sema/arith.zig:2269`
(`floatMod`) shows the same result; not inspected in detail.

## Fix sketch

Adjust when `a != 0` and `sign(a) != sign(rhs)`: result `a + rhs`, else `a`.
Same change in Sema's `floatMod`. Small. Check vector and f16/f80/f128
(compiler-rt `fmod`) paths.

## Verification

Behavior test: `@mod(10.0, -3.0) == -2.0`, `@mod(-10.0, 3.0) == 2.0`,
`@mod(-10.0, -3.0) == -1.0`, at comptime and runtime for f16..f128 and
vectors, in Debug and ReleaseFast.

## Notes

`std.math.mod` rejects negative denominators, so std is unaffected. Not
fixed on origin/master.
