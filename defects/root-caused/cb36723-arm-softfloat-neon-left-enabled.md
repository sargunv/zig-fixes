---
title: ARM soft-float ABIs drop vfp2 but leave neon marked enabled; arm_neon.h breaks
priority: 1
area: target-defs
targets: [arm-linux-androideabi, arm-linux-ohoseabi, arm-linux-musleabi, arm-linux-gnueabi]
upstream: [codeberg#36723]
affects-line: yes
---

## Symptom

For ARM targets whose ABI float mode is `.soft` (including `androideabi` and
`ohoseabi`), Zig removes `vfp2` but keeps the features that depend on it.
`builtin.cpu.has(.arm, .neon)` is true while LLVM has NEON disabled, so
NEON inline asm guarded by that check fails:
`error: <inline asm>:1:2: invalid instruction ... vadd.f32 d0, d1, d2`.

## Evidence

- codeberg#36723, reported on 0.17.0-dev.1936 with `arm-freestanding`.
- Reproduced on 0.17.1 (aarch64-macos host): the issue's `foo.zig` fails
  with the error above for `arm-freestanding`, `arm-linux-androideabi`,
  `arm-linux-musleabi` and `arm-linux-ohoseabi`. A `@compileLog` on
  `arm-linux-androideabi` shows `neon = true`, `vfp3 = true`, `vfp2 = false`.
- Related C impact, observed here: `zig cc -target arm-linux-androideabi`
  defines `__SOFTFP__` and no `__ARM_NEON`, and `#include <arm_neon.h>`
  fails with `arm_bf16.h:14:9: error: __bf16 is not supported on this target`.
  The same file compiles for `arm-linux-musleabihf`.

## Root cause

`lib/std/zig/system.zig:448-451`: the workaround for llvm-project#105978
calls `removeFeature(vfp2)` without removing its dependents (neon, vfp3,
and so on). A maintainer (alexrp) confirmed that only the ARM hack has this
problem and suggested adding `populateDependents`.

## Fix sketch

Add `Feature.Set.populateDependents`, build the set {vfp2} plus dependents,
and remove it from the CPU features. Small.

## Verification

`zig build-obj foo.zig -target arm-linux-androideabi` succeeds, and
`builtin.cpu.has(.arm, .neon)` is false for soft-float ABIs.

## Notes

`origin/master` fixes this in 6c92a9ea64 ("remove FPU features according to
float ABI in resolveTargetQuery()") on top of f913d0d289 (adds
`populateDependents`). It is part of a large CPU-feature rework (features are
renamed, e.g. `fpregs`), so a backport needs adapting.
Design gap beyond this issue: Android armeabi-v7a and OHOS arm32 use
*softfp* (soft calling convention, but VFP/NEON hardware), and NDK clang
defines `__ARM_NEON`. Zig treats these ABIs as full soft float, so C code
gets no FPU or NEON at all. Master keeps that behaviour and says softfp needs
more compiler work. This is worth a separate entry for NEON C code on 32-bit
Android.
