---
title: acosh/acoshf return finite values for some x < 1 instead of NaN (std.math and bundled musl/wasi libc)
priority: 1
area: lib/std
targets: [all]
upstream: [codeberg#37577]
affects-line: yes
---

## Symptom

`std.math.acosh(@as(f64, -3282980.9188842773))` returns `7.143967918122541`
instead of NaN; the f32 version returns `-3.484465` for `-100.5`. Because
`lib/c/math.zig` exports `std.math.acosh` as `acoshf` for musl and wasi-libc,
C code built with `zig cc` for those targets gets the same wrong `acoshf`, and
the bundled musl `acosh.c` (f64) has the same flaw.

## Evidence

- codeberg#37577 (0.18.0-dev.935); comment identifies the masked sign bit and
  points to musl commit 3e80328d45b7 which fixed musl upstream.
- Reproduced on 0.17.1 (aarch64-macos): f64 input above gives
  7.143967918122541; f32 inputs stepped by 0.37 over [-4096, -2] gave 2939
  non-NaN results.

## Root cause

`lib/std/math/acosh.zig:26-60`: `acosh32` masks the sign (`u & 0x7FFFFFFF`) and
`acosh64` masks the exponent with `& 0x7FF`, so negative inputs take the
`|x| < 2` or `|x| < 2^12 / 2^26` branches and compute a finite value. musl's
fixed version keeps the sign bit so negative inputs fall through to an
`(x-x)/(x-x)` NaN branch. The bundled `lib/libc/musl/src/math/acosh.c:12` is
the pre-fix musl code with the same mask. `lib/c/math.zig:62,106-108` exports
the Zig version as `acoshf` for musl and wasi.

## Fix sketch

Port musl's fix: compare the unmasked bits so only `0 <= x < 2` and
`2 <= x < 2^26` take the fast branches, and return NaN when the sign bit is set
(f32 and f64). Update the bundled musl `acosh.c` to upstream. Add tests for
negative inputs. Small.

## Verification

`std.math.acosh` returns NaN for -1.5, -100.5, -3282980.9 in f32 and f64,
comptime and runtime; a C test calling `acosh`/`acoshf(-100.5)` built with
`zig cc -target x86_64-linux-musl` prints nan.

## Notes

No fix on `origin/master` (last change to `acosh.zig` predates 0.17).
