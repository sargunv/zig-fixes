---
title: zmm clobbers are silently dropped by LLVM on x86_64 CPUs without AVX-512, leaving xmm/ymm unclobbered
priority: 1
area: codegen
targets: [x86_64-linux-gnu, x86_64-linux-musl, x86_64-windows, x86_64-macos, x86_64-freebsd, x86_64-linux-android]
upstream: [codeberg#37533]
affects-line: yes
---

## Symptom

An `asm` clobber list naming `.zmm0 = true, ...` (expecting that to cover the
aliased `xmm`/`ymm` registers) protects nothing when the target CPU lacks
AVX-512: LLVM discards the unknown-for-this-CPU clobbers and keeps live values
in `xmm` registers across the asm. The reporter hit this in a context-switch
routine in ReleaseFast for x86_64 baseline, where auto-vectorized code lost
its vector registers.

`lib/std/Io/fiber.zig:244-318` (`contextSwitch`, x86_64) clobbers only
`zmm0..zmm31` and no `xmm`/`ymm`, so std's own fiber switch is exposed to this
on non-AVX-512 CPUs.

## Evidence

- codeberg#37533 (0.18.0-dev.852), milestone Urgent. alexrp suggests the
  compiler weaken `zmm` -> `ymm` -> `xmm` by CPU features.
- Reproduced on 0.17.1: `zig build-obj -target x86_64-linux -mcpu=x86_64
  -O ReleaseFast` of a function that keeps `x` and `x*3` live across
  `asm volatile ("xorps %%xmm0,%%xmm0\n xorps %%xmm1,%%xmm1" ::: .{ .zmm0 =
  true, ... .zmm15 = true })`. With zmm clobbers the values stay in
  xmm0/xmm1 across the asm (`mulsd xmm1,xmm0; xorps...; addsd xmm0,xmm1`);
  with the same list spelled `xmm0..xmm15` they are spilled to the stack.

## Root cause

`src/codegen/llvm/FuncGen.zig:8076` (`appendConstraints`) emits `~{zmmN}`
verbatim for every clobber, with no mapping to the widest vector register the
target CPU actually has.

## Fix sketch

In `appendConstraints` for x86/x86_64: map `zmmN` to `ymmN` without
`avx512f`, and to `xmmN` without `avx`; drop `zmm16..31` (or map to nothing)
when AVX-512 is absent. Likewise `ymmN` -> `xmmN` without AVX. Alternatively
emit a compile error, as the issue first asked. Small change.

## Verification

Rebuild the snippet above for `-mcpu=x86_64`; the live values must be spilled
around the asm. Run the `std.Io` Evented (Uring) tests in ReleaseFast on an
x86_64 baseline target.

## Notes

Not fixed on origin/master; `fiber.zig` there still clobbers only zmm.
Related: cb35724 (same `contextSwitch`, register in/out/clobber overlap).
