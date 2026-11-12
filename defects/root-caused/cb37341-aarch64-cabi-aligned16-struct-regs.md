---
title: LLVM backend passes 16-byte-aligned structs (e.g. extern struct { i128 }) in the wrong register pair on AAPCS64
priority: 1
area: codegen
targets: [aarch64-linux-gnu, aarch64-linux-musl, aarch64-linux-android, aarch64-linux-ohos, aarch64-freebsd, aarch64-windows]
upstream: [codeberg#37341]
affects-line: yes
---

## Symptom

A C-ABI function whose parameter is a 16-byte struct with 16-byte alignment
gets that parameter from the wrong registers when the next general register
number is odd. AAPCS64 rule C.10 rounds NGRN up to even for alignment-16
arguments; Zig does it for a bare `i128` but not for `extern struct { x: i128 }`.

```zig
const S = extern struct { x: i128 };
export fn f(_: i64, _: i64, _: i64, _: i64, _: i64, s: S) i64 {
    return @truncate(s.x);
}
```

Zig reads `s` from x5/x6; clang, gcc and rustc pass it in x6/x7. Calls between
Zig and C in either direction exchange garbage.

## Evidence

- codeberg#37341, reported on 0.17.0 and 0.18.0-dev.349.
- Reproduced on 0.17.1 (`zig build-obj -O ReleaseSmall -fomit-frame-pointer`,
  then `objdump -d`): Zig emits `mov x0, x5` for `aarch64-linux-gnu` and
  `aarch64-windows-gnu`; `zig cc -O2` on the equivalent C emits `mov x0, x6`
  for both. On `aarch64-macos` both emit `x5` (Apple's ABI drops the rounding),
  so Darwin is not affected.

## Root cause

`src/codegen/aarch64/abi.zig:24-27` (and `:33-36` for unions) classifies every
struct of 65..128 bits as `.double_integer` regardless of alignment.
`src/codegen/llvm/FuncGen.zig:7150` lowers `.double_integer` parameters as
`[2 x i64]`, which LLVM never rounds to an even register. Clang coerces
16-byte-aligned aggregates to `i128` instead, which carries the rounding.

## Fix sketch

In the aarch64 param lowering, when the type's ABI alignment is 16, lower it
as a single `i128` instead of `i64_array = 2`. Small change, maybe a new class
in `aarch64/abi.zig`. Darwin keeps working because LLVM applies the Apple
rules to `i128` itself. Check the return path (`FuncGen.zig:7602`) for the
same.

## Verification

Add a case to `test/c_abi` with five `i64` arguments followed by a struct
wrapping `__int128`, both directions, and run it on aarch64-linux and
aarch64-windows.

## Notes

Not fixed on origin/master as of this sweep.
