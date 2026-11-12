---
title: Aro (translate-c) predefines no LoongArch macros and no Android API-level macros, so libc headers fail or misdetect the target
priority: 1
area: translate-c
targets: [loongarch64-linux-gnu, loongarch64-linux-musl, loongarch32-linux-gnu, aarch64-linux-android, x86_64-linux-android, arm-linux-androideabi, x86-linux-android]
upstream: []
affects-line: yes
---

## Symptom

Translating C headers for LoongArch with Zig's C translator (Aro) fails as soon
as glibc's headers are included:

```
$ zig translate-c -target loongarch64-linux-gnu -lc s.h      # s.h: #include <stdio.h>
.../lib/libc/include/loongarch-linux-gnu/bits/wordsize.h:22:3: error: unsupported ABI

$ zig translate-c -target loongarch64-linux-gnu t.h          # t.h: #ifndef __loongarch__ / #error ...
t.h:2:2: error: no __loongarch__
t.h:5:2: error: no __loongarch_grlen
```

On Android, the API-level macros that clang defines are missing, so NDK
headers misdetect the API level:

```
$ zig translate-c -target aarch64-linux-android.29 a.h       # a.h: #ifndef __ANDROID_MIN_SDK_VERSION__ / #error
a.h:2:2: error: no min sdk
```

The same happens through the `translate_c` package (`std.Build` translate-c
step).

## Evidence

- Reproduced on Zig 0.17.1 with its bundled `zig translate-c`.
- The `translate_c` package checked is
  `git+https://codeberg.org/ziglang/translate-c?ref=zig-0.17.x#cfac21f3199b2b02ce3fd7db652aa456421fe4ab`,
  whose fetched Aro is package
  `aro-0.0.0-JSD1QvCRNwC2O1Jkop9TO6sXb1U1vhrH8FnYK1VdEMKn`.
- NDK 30 headers break on the missing `__ANDROID_MIN_SDK_VERSION__` and
  `__ANDROID_API__`.
- Aro already parses the Android API level from the target triple
  (`lib/compiler/aro/aro/Target.zig:1729`, verified) but never emits it.
- Hexagon, m68k, CSKY, Xtensa, and VE also have no predefined-macro arm.
- clang's reference set, from `zig cc -target loongarch64-linux-gnu -dM -E -x c /dev/null`:
  - `__loongarch__`, `__loongarch64`
  - `__loongarch_grlen 64`, `__loongarch_frlen 64`
  - `__loongarch_lp64`, `__loongarch_hard_float`, `__loongarch_double_float`
  - `__loongarch_arch "la64v1.0"`, `__loongarch_tune`
  - `__loongarch_sx`, `__loongarch_simd_width 128`

## Root cause

Verified by reading code.

- Zig's vendored Aro (`lib/compiler/aro/aro/Compilation.zig`) and the fetched
  Aro package (`src/aro/Compilation.zig`) have the same gaps at the same line
  numbers:
  - The architecture switch, from "architecture macros" at line 543 to about
    line 1263, has arms for x86, sparc, arm, aarch64, msp430, arc, wasm,
    s390x, riscv and others, then `else => {}`. There is no LoongArch arm.
  - For Android it emits only `__ANDROID__` (`Compilation.zig:539-541`), not
    `__ANDROID_MIN_SDK_VERSION__` or `__ANDROID_API__`. The Driver parses the
    level (`Driver.zig:1047`), and `Target.zig:1729` stores it.
- RISC-V is present but partial (`Compilation.zig:1239-1262`). It emits
  `__riscv`, `__riscv_xlen`, the f/d/q flags, `__riscv_flen`, and the float
  ABI, but lacks `__riscv_mul`, `__riscv_atomic`, `__riscv_compressed`,
  `__riscv_cmodel_*` and the rest of clang's roughly 27 macros.
- **Why LoongArch became a hard error in 0.17.0:** 23aa045ef4 ("libc: update
  glibc headers to 2.44") added a Zig patch to
  `lib/libc/include/loongarch-linux-gnu/bits/wordsize.h:18-23`:
  `#if __loongarch_grlen == (__SIZEOF_POINTER__ * 8) ... #else #error unsupported ABI`.
  Before that, the header hard-coded 64. Clang defines `__loongarch_grlen`, so
  only Aro breaks.
- Other bundled headers also test LoongArch macros: `gnu/stubs.h`,
  `bits/setjmp.h`, `bits/link.h`, `fpu_control.h`, `sys/asm.h`, and musl's
  `bits/fenv.h` read `__loongarch_soft_float`, `__loongarch_double_float`,
  and `__loongarch_frlen`.

Upstream: not fixed (verified). arocc master on both
codeberg.org/ziglang/arocc and github.com/Vexu/arocc (`src/aro/Compilation.zig`,
3010 lines each) contains no `loongarch` and no `ANDROID_MIN`, and neither
does Zig `origin/master`'s `lib/compiler/aro`. translate-c#43 is an unrelated
LoongArch `va_list` issue, fixed separately.

## Fix sketch

- Add a `.loongarch32, .loongarch64` arm modeled on the RISC-V one, about
  20–30 lines:
  - `__loongarch__`, `__loongarch32` or `__loongarch64`
  - `__loongarch_grlen` = pointer width
  - `__loongarch_frlen` and one of `__loongarch_soft_float`,
    `__loongarch_single_float`, or `__loongarch_double_float`, plus
    `__loongarch_hard_float`, derived from `target.abi.float()` / CPU features
  - `__loongarch_lp64` (or `ilp32`)
  - optionally `__loongarch_arch`, `__loongarch_sx`, `__loongarch_asx`
- In the Android branch, emit
  `#define __ANDROID_MIN_SDK_VERSION__ <api>` and
  `#define __ANDROID_API__ __ANDROID_MIN_SDK_VERSION__`, as clang does. About
  2 lines.
- Optionally fill the Hexagon, m68k, CSKY, Xtensa, and VE arms and the
  missing RISC-V macros, using clang's `getTargetDefines` for each as the
  reference.
- The change belongs in arocc. translate-c and Zig's vendored
  `lib/compiler/aro` then pick it up. A fork must patch both, or bump the
  translate_c pin.

## Verification

- `zig translate-c -target loongarch64-linux-gnu -lc s.h` succeeds for
  `#include <stdio.h>`.
- `zig translate-c -target loongarch64-linux-gnusf -lc` on a header using
  `jmp_buf` yields the soft-float layout.
- Compare `-dM`-style output from Aro with clang's
  `zig cc -target <t> -dM -E -x c /dev/null` for LoongArch and Android.
  Aro's test suite has predefined-macro tests to extend.
- `zig translate-c -target aarch64-linux-android.29` sees
  `__ANDROID_MIN_SDK_VERSION__ == 29`.

## Notes

- **Workaround today:** on the translate-c step, define
  `__loongarch_grlen=64` for 64-bit LoongArch targets, and define
  `__ANDROID_MIN_SDK_VERSION__` (and `__ANDROID_API__`) to the target's
  Android API level.
- **Caveat on the current workaround (verified from the headers above):**
  defining only `__loongarch_grlen` gives correct hard-float (lp64d) layouts,
  but would silently pick the hard-float `jmp_buf` and similar for soft-float
  LoongArch targets.
