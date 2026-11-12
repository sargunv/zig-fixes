---
title: Clang crashes on vld1q_*_x4 NEON intrinsics with the softfp float ABI (Android arm)
priority: 1
area: upstream-llvm
targets: [arm-linux-androideabi, arm-linux-gnueabi]
upstream: [codeberg#36584, github#25843]
affects-line: yes
---

## Symptom

```c
#include <arm_neon.h>
int32x4x4_t f(int var[16]) { return vld1q_s32_x4(var); }
```

`zig cc -target arm-linux-gnueabi -mfloat-abi=softfp test.c` fails with
`fatal error: error in backend: Do not know how to split the result of this
operator!` (clang exit 70). Android 32-bit ARM always uses softfp, so NEON code
using these intrinsics cannot be built for `arm-linux-androideabi`.

## Evidence

- Reported on 0.17.0-dev.1818 (clang 22.1.8), labelled upstream (codeberg#36584).
- Reproduced on 0.17.1: same error for `-target arm-linux-gnueabi
  -mfloat-abi=softfp` and `-target arm-linux-androideabi -mfloat-abi=softfp`
  (`-c` only). `arm-linux-gnueabihf` compiles fine.
- Side observation: `-target arm-linux-androideabi` without flags rejects
  `arm_neon.h` (`__bf16 is not supported on this target`) because the default
  CPU lacks NEON, and `-target arm-linux-android` passes `-mfloat-abi=hard`,
  which clang rejects for Android.

## Root cause

LLVM ARM SelectionDAG legalization bug when returning a 4-vector aggregate
under softfp. Not investigated further.

## Fix sketch

Not investigated. Find or file the LLVM issue and carry a patch in the fork's
LLVM if needed; otherwise document a workaround (avoid `_x4` loads on softfp).

## Verification

The two-line reproduction compiles for `arm-linux-androideabi -mfloat-abi=softfp`.

## Notes

The `arm-linux-android` / default-CPU observations above may deserve their own
entry; they were not in this slice.
