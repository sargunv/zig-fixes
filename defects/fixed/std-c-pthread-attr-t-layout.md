---
title: std.c.pthread_attr_t on Linux is larger than C's on every ABI
priority: 2
area: lib/std
targets: [x86_64-linux-gnu, x86_64-linux-musl, aarch64-linux-musl, aarch64-linux-ohos, aarch64-linux-android, arm-linux-musleabihf, arm-linux-ohoseabi, arm-linux-androideabi, x86-linux-gnu]
upstream: []
affects-line: yes
---

## Symptom

`@sizeOf(std.c.pthread_attr_t)` is 64 on 64-bit Linux and 60 on 32-bit
Linux. C's `sizeof(pthread_attr_t)` is 56 on 64-bit (64 on aarch64
glibc), and 36 on 32-bit (32 on `gnux32` and `riscv32-linux-gnu`, 24 on
32-bit Android). Alignment agrees. A Zig `extern struct` that embeds one
and is shared with C has the wrong layout. Passing a pointer to
`pthread_attr_init` was unaffected, because the Zig object was the larger.

Reproduce with `T` = `pthread_attr_t`:

```c
// layout.c
#include <pthread.h>
#include <semaphore.h>
int size = sizeof(T), align = _Alignof(T);
```

```zig
// layout.zig
comptime {
    @compileLog(@sizeOf(@import("std").c.T), @alignOf(@import("std").c.T));
}
```

```
zig cc -target <t> -S -o - layout.c   # read the .long values of size and align
zig build-obj -target <t> -fno-emit-bin layout.zig
```

## Evidence

- Measured on this line (0.17.1 plus ohos-libc-support and
  std-c-pthread-rwlock-32bit-size) with the release binary for the 57 Linux
  glibc and musl targets that Zig has libc headers for and that have an LLVM
  backend, with the OpenHarmony SDK 7.0 Clang for `arm-linux-ohos`,
  `aarch64-linux-ohos` and `x86_64-linux-ohos`, and with the Android NDK r30
  Clang (API 24, 35 for riscv64) for arm, aarch64, x86, x86_64 and riscv64.
- Every target mismatched except `aarch64-linux-gnu` and
  `aarch64_be-linux-gnu`, whose glibc size is 64.

## Root cause

`lib/std/c.zig:8357-8361` declared it for Linux, Emscripten and DragonFly
as `extern struct { __size: [56]u8, __align: c_long }`. C declares a union
of the two (glibc `union pthread_attr_t`,
`lib/libc/include/generic-glibc/bits/pthreadtypes.h:56-60`; musl a union
inside a struct, `lib/libc/include/generic-musl/bits/alltypes.h:371`) whose
size is the byte array's, so Zig's struct was larger by the trailing
`c_long`. The 56 bytes are also the 64-bit size. 32-bit C uses 36 (glibc
`__SIZEOF_PTHREAD_ATTR_T`, musl `__i[9]`), 32 on glibc `gnux32` and
`riscv32`, and glibc on aarch64 uses 64. Android's bionic is a struct of
named fields (`flags`, `stack_base`, ...), 24 bytes on 32-bit and 56 on
64-bit (NDK `sysroot/usr/include/bits/pthread_types.h:36-46`).

## Fix sketch

As done; see Fix.

## Verification

- `test/standalone/pthread_type_layouts`: translates `<pthread.h>` and
  `<semaphore.h>` for 17 glibc and musl targets and fails to compile if
  `std.c.pthread_mutex_t`, `pthread_cond_t`, `pthread_rwlock_t`,
  `pthread_attr_t` or `sem_t` differs from C in size or alignment. Run it
  from that directory with `zig build test`, or as part of
  `mise run zig-build -- test-standalone`. Android and OpenHarmony cannot
  be in it: Zig ships no headers for them.
- The comparison in Symptom, for every target in Evidence.

## Fix

- `lib/std/c.zig`: on Linux, `pthread_attr_t` keeps its shape, an
  `extern struct` of `__size` followed by `__align: c_long`, with `__size`
  shortened so that the whole struct has C's size: Android 24/56; glibc
  aarch64 64; glibc `riscv32` and `gnux32` 32; otherwise 56 with 8-byte
  pointers and 36 with 4-byte ones. `__size` is that size less
  `@sizeOf(c_long)`, and the `c_long` gives the struct C's alignment.
  Emscripten and DragonFly keep the old declaration; they were not
  compared.

The struct keeps its shape rather than becoming a union like glibc's,
because the defect is its size and alignment, and the fields are opaque
through the pthread API, which only takes a pointer. In C, `__align`
overlaps `__size` at offset 0; here it sits at the end. No caller can
observe that through the API. Upstream's `master` (at `c9ec343709`) still
has the 0.17.1 declaration, so there was no upstream shape to follow.

Who sees a change: every Linux target except glibc aarch64 and
aarch64_be. The type shrinks on all of them: 64 to 56 on 64-bit, 60 to
36 (32 on `gnux32` and `riscv32-linux-gnu`, 24 on 32-bit Android).
Shrinking to C's size is safe for code that only passes a pointer to C,
and code that stores one gets smaller. An `extern struct` embedding one
now has C's layout, so fields after it move.

Source compatibility: `var a: std.c.pthread_attr_t = undefined;`,
`std.mem.zeroes(std.c.pthread_attr_t)` and initializers naming both fields
(`.{ .__size = undefined, .__align = 0 }`, `.{ .__size = @splat(0),
.__align = 0 }`) compile as they did with 0.17.1. Checked on
`x86_64-linux-gnu`, `aarch64-linux-musl`, `arm-linux-musleabihf`,
`riscv32-linux-gnu`, `aarch64-linux-android` and `arm-linux-androideabi`.
One form cannot be kept: a `__size` value of the old length, such as a
`[56]u8`, no longer fits on the targets whose size changed, because the
array's length is what this fixes.

Fixed together with std-c-pthread-attr-t-layout,
std-c-pthread-cond-t-glibc-32bit-underaligned, std-c-sem-t-musl-overaligned
and std-c-pthread-mutex-t-linux-abi-gaps, which share the comparison and
the test.

- The comparison now agrees for all five types (these four and
  `pthread_rwlock_t`) on all 65 measured targets: 325 of 325 rows, where
  114 disagreed or did not compile before. The other pthread types did not
  change on any target.
- arc, csky, m68k and loongarch32 have no C backend here; see Notes.
- `test/standalone/pthread_type_layouts` passes; against the previous
  `lib/` it fails on 16 of its 17 targets (all but `aarch64-linux-gnu`,
  whose layouts were already right).

## Notes

- Found while fixing std-c-pthread-rwlock-32bit-size.
- arc, csky, loongarch32 and m68k could not be compiled as C. Their
  bundled headers give 36, and the new declaration gives 36 on all four.
