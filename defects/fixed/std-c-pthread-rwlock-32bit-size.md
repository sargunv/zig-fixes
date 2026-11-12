---
title: std.c.pthread_rwlock_t is 56 bytes on 32-bit Linux, where musl, OpenHarmony and glibc use 32, 44 or 48
priority: 2
area: lib/std
targets: [arm-linux-musleabihf, arm-linux-ohoseabi, x86-linux-musl, arm-linux-gnueabihf, x86-linux-gnu, riscv32-linux-gnu, x86_64-linux-gnux32]
upstream: [codeberg#31427]
affects-line: yes
---

## Symptom

On 32-bit Linux targets other than Android, `@sizeOf(std.c.pthread_rwlock_t)`
is 56, but C's `sizeof(pthread_rwlock_t)` is 32 (44 on
`x86_64-linux-gnux32`, 48 on `riscv32-linux-gnu`). Alignment agrees. A Zig
`extern struct` that embeds one, and is shared with C code, has the wrong
layout.

```c
// layout.c
#include <pthread.h>
int size = sizeof(pthread_rwlock_t), align = _Alignof(pthread_rwlock_t);
```

```zig
// layout.zig
comptime {
    @compileLog(@sizeOf(@import("std").c.pthread_rwlock_t), @alignOf(@import("std").c.pthread_rwlock_t));
}
```

```
$ zig cc -target arm-linux-musleabihf -S -o - layout.c | grep -A1 '^size:'
size:
	.long	32
$ zig build-obj -target arm-linux-musleabihf -fno-emit-bin layout.zig
@as(comptime_int, 56), @as(comptime_int, 4)
```

## Evidence

- Measured on this line (0.17.1 plus ohos-libc-support) with the release
  binary, for every Linux target Zig has libc headers for and an LLVM
  backend, and with the OpenHarmony SDK 7.0 Clang
  (`clang --target=arm-linux-ohos --sysroot=<sdk>/native/sysroot`) for
  `arm-linux-ohos`, which gives 32, align 4.
- Every 32-bit musl and glibc target mismatched: arm, armeb, thumb,
  thumbeb, x86, mips, mipsel, powerpc, riscv32, hexagon, sparc,
  `mips64(el)-linux-gnuabin32`, `x86_64-linux-gnux32`, and
  `arm-linux-ohoseabi`. Every 64-bit target agreed (56, align 8).
- C has no backend here for arc, csky, m68k and loongarch32. Their bundled
  headers give 32: glibc's generic `__SIZEOF_PTHREAD_RWLOCK_T`
  (`lib/libc/include/generic-glibc/bits/pthreadtypes-arch.h:33`, used by
  arc, csky and loongarch32), m68k's own
  (`lib/libc/include/m68k-linux-gnu/bits/pthreadtypes-arch.h:28`), and
  musl's `int __i[sizeof(long)==8?14:8]`
  (`lib/libc/include/m68k-linux-musl/bits/alltypes.h:412`).

## Root cause

`lib/std/c.zig:8289-8303` gives Android its own sizes and every other Linux
ABI a fixed 56-byte layout, which is the 64-bit size. The 32-bit sizes are
32 in musl and in most of glibc, 44 in glibc for x86_64 x32
(`lib/libc/include/x86-linux-gnu/bits/pthreadtypes-arch.h:32`), and 48 in
glibc for 32-bit RISC-V
(`lib/libc/include/riscv-linux-gnu/bits/pthreadtypes-arch.h:38`).

## Fix sketch

As done; see Fix.

## Verification

- `test/standalone/pthread_type_layouts`: for a set of 32-bit and 64-bit
  glibc and musl targets, translates `<pthread.h>` and fails to compile if
  `std.c.pthread_rwlock_t` differs from C's in size or alignment. Run it
  from that directory with `zig build test`, or as part of
  `mise run zig-build -- test-standalone`.
- The `layout.c`/`layout.zig` comparison in Symptom, for all Linux libc
  targets and for the OpenHarmony SDK's `arm-linux-ohos`.

## Fix

- `lib/std/c.zig`: the non-Android Linux `pthread_rwlock_t` is 56 bytes
  with 8-byte pointers, as before. With 4-byte pointers it is 48 on
  `riscv32` glibc, 44 on `gnux32`, and 32 otherwise.
- `test/standalone/pthread_type_layouts` (first added as
  `pthread_rwlock_t_size`, before it covered the other pthread types): the
  test above, over `aarch64`, `x86_64` (gnu, musl, gnux32), `arm`
  (gnueabihf, musleabihf), `x86`, `riscv32` (gnu, musl) and
  `mips64el-linux-gnuabin32`. It fails on the 8 32-bit targets without the
  fix ("std.c.pthread_rwlock_t has size 56 align 4, but C has size 32
  align 4", 44 for gnux32, 48 for riscv32 glibc) and passes with it.

Verified on a macOS aarch64 host with the 0.17.1 release binary and this
checkout's `lib/`:

- The comparison in Symptom now agrees for `pthread_rwlock_t` on 49 of the
  57 Linux glibc and musl targets that have an LLVM backend, and for the
  OpenHarmony SDK's `arm-linux-ohos`, `aarch64-linux-ohos` and
  `x86_64-linux-ohos`. The 64-bit sizes did not change.
- The other eight (`x86_64-linux-muslx32`, the `mips64(el)` musl
  ABIs, and the loongarch64 `muslsf`, `muslf32` and `gnusf` ABIs) fail to
  compile `std.c.pthread_mutex_t` (std-c-pthread-mutex-t-linux-abi-gaps),
  so `pthread_rwlock_t` was checked alone there: 32 for muslx32 and
  muslabin32, 56 for the 64-bit ones, as in C. arc, csky, m68k and
  loongarch32 now give 32, as their headers do.
- The other pthread types' sizes and alignments are unchanged on every
  target.

## Notes

- Split out of ohos-libc-support.
- Android was not part of the comparison above. A later comparison with
  the Android NDK found the 64-bit Android `pthread_rwlock_t` aligned to 8,
  where bionic's `int32_t` array is aligned to 4. That was fixed with
  std-c-pthread-mutex-t-linux-abi-gaps, which has the same cause.
- The same comparison found mismatches in sibling types with other causes:
  std-c-pthread-attr-t-layout, std-c-pthread-cond-t-glibc-32bit-underaligned,
  std-c-sem-t-musl-overaligned and std-c-pthread-mutex-t-linux-abi-gaps.
