---
title: std.c.sem_t is 8-byte aligned on 64-bit musl and OpenHarmony, where C aligns it to 4, and has the wrong size on Android
priority: 2
area: lib/std
targets: [x86_64-linux-musl, aarch64-linux-musl, aarch64-linux-ohos, x86_64-linux-ohos, riscv64-linux-musl, loongarch64-linux-musl, arm-linux-androideabi, aarch64-linux-android, x86_64-linux-android]
upstream: []
affects-line: yes
---

## Symptom

On 64-bit musl and OpenHarmony, `@alignOf(std.c.sem_t)` is 8 but C's
`_Alignof(sem_t)` is 4; the sizes agree (32). On Android, C's `sem_t` is 4
bytes (32-bit) or 16 (64-bit), aligned to 4, while Zig's is 16 or 32,
aligned to `usize`. A Zig `extern struct` that embeds a `sem_t` and is
shared with C is laid out differently.

Reproduce with `T` = `sem_t`:

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
- Every 64-bit musl target, the 64-bit OpenHarmony targets and every
  Android target mismatched. glibc targets and 32-bit musl and OpenHarmony
  targets agree.

## Root cause

`lib/std/c.zig:8419-8422` gave Linux one layout, `[4 * @sizeOf(usize)]u8
align(@alignOf(usize))`. That matches glibc, whose `sem_t` is a union with
a `long` (`lib/libc/include/generic-glibc/bits/semaphore.h:35-39`). musl's
is `struct { volatile int __val[4*sizeof(long)/sizeof(int)]; }`
(`lib/libc/include/generic-musl/semaphore.h:16-18`), aligned to `int`.
Bionic's is `struct { unsigned int count; int __reserved[3]; }`, without
`__reserved` on 32-bit (NDK `sysroot/usr/include/semaphore.h:39-44`).

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

- `lib/std/c.zig`: the Linux `sem_t` is 4 bytes on 32-bit Android, 16 on
  64-bit Android, and `4 * @sizeOf(usize)` elsewhere, aligned to `usize` on
  glibc and to `c_int` otherwise. Emscripten keeps the old declaration.

Who sees a change: on 64-bit musl and OpenHarmony the alignment drops from
8 to 4 and the size stays 32. On Android the type shrinks (16 to 4 bytes
on 32-bit, 32 to 16 on 64-bit) and its alignment drops to 4 on 64-bit:
passing it to C was safe before, and code that stores one gets smaller.

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
- m68k musl could not be compiled as C. Its `sem_t` now takes `c_int`'s
  alignment there, 2, as musl's `int` array does.
