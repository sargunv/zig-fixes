---
title: std.c.pthread_cond_t has the wrong alignment on 32-bit glibc and 64-bit Android, and the wrong size on 32-bit Android
priority: 3
area: lib/std
targets: [arm-linux-gnueabihf, mips-linux-gnueabihf, riscv32-linux-gnu, sparc-linux-gnu, x86_64-linux-gnux32, mips64-linux-gnuabin32, arm-linux-androideabi, x86-linux-android, aarch64-linux-android, x86_64-linux-android]
upstream: []
affects-line: yes
---

## Symptom

`@alignOf(std.c.pthread_cond_t)` is 4 on 32-bit glibc targets other than
x86, where C's `_Alignof(pthread_cond_t)` is 8, and 8 on 64-bit Android,
where C's is 4. On 32-bit Android, C's `pthread_cond_t` is 4 bytes and
Zig's is 48. A Zig `extern struct` embedding one and shared with C is laid
out differently, and on 32-bit glibc a `pthread_cond_t` that Zig places at
a 4-byte boundary is less aligned than glibc's 64-bit fields in it expect.

Reproduce with `T` = `pthread_cond_t`:

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
- glibc mismatches: arm and armeb `gnueabi`/`gnueabihf`, mips and mipsel
  `gnueabi`/`gnueabihf`, `mips64(el)-linux-gnuabin32`, `riscv32-linux-gnu`,
  `sparc-linux-gnu` and `x86_64-linux-gnux32` (48/8 in C, 48/4 in Zig).
  `x86-linux-gnu`, where `long long` is 4-byte aligned, agrees. musl and
  OpenHarmony agree everywhere.
- Android: 4/4 in C and 48/4 in Zig on arm and x86; 48/4 in C and 48/8 in
  Zig on aarch64, x86_64 and riscv64.

## Root cause

`lib/std/c.zig:8241-8244` declared one Linux layout, `[48]u8
align(@alignOf(usize))`. glibc's `pthread_cond_t` union has a `long long
__align` member (`lib/libc/include/generic-glibc/bits/pthreadtypes.h:75-80`),
so it takes the alignment of `long long`. Bionic's is `int32_t
__private[12]` on 64-bit and `int32_t __private[1]` on 32-bit (NDK
`sysroot/usr/include/bits/pthread_types.h:58-64`), aligned to 4.

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

- `lib/std/c.zig`: the Linux `pthread_cond_t` is 4 bytes on 32-bit Android
  and 48 elsewhere, aligned to `c_longlong` on glibc (except m68k, see
  Notes), to 4 on Android, and to `usize` otherwise (musl, OpenHarmony).

Who sees a change: on the 32-bit glibc targets above the alignment grows
from 4 to 8, so a `pthread_cond_t` is no longer placed where glibc's
64-bit fields are misaligned, and structs that embed one may gain padding.
On 64-bit Android the alignment drops from 8 to 4. On 32-bit Android the
type shrinks from 48 to 4 bytes: passing it to C was safe before, and code
that stores one gets smaller.

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
- arc, csky, loongarch32 and m68k could not be compiled as C. Zig gives
  arc and csky `c_longlong`'s alignment, 4 (unchanged), and loongarch32 8
  (was 4), as glibc's generic header's `long long` member requires. m68k
  keeps 4: GCC's m68k ABI aligns `long long` to 2, and glibc raises the
  type to 4 with `__LOCK_ALIGNMENT` on `__g_size`
  (`lib/libc/include/generic-glibc/bits/thread-shared-types.h:98`,
  `lib/libc/include/m68k-linux-gnu/bits/pthreadtypes-arch.h:33`). Zig's own
  `c_longlong` is 8-aligned on m68k, so `@alignOf(c_longlong)` would be
  wrong there.
