---
title: std.c.pthread_mutex_t has the wrong size on some glibc targets, the wrong alignment on 64-bit Android, and does not compile on several musl and loongarch ABIs
priority: 3
area: lib/std
targets: [riscv32-linux-gnu, mips64-linux-gnuabin32, aarch64_be-linux-gnu, aarch64-linux-android, x86_64-linux-android, x86_64-linux-muslx32, mips64-linux-muslabi64, mips64-linux-muslabin32, loongarch64-linux-muslsf, loongarch64-linux-gnusf]
upstream: []
affects-line: yes
---

## Symptom

`std.c.pthread_mutex_t` disagrees with C:

| Target | C | Zig |
|---|---|---|
| `riscv32-linux-gnu` | 32/4 | 24/4 |
| `mips64-linux-gnuabin32` | 24/4 | 40/4 |
| `aarch64_be-linux-gnu` | 48/8 | 40/8 |
| `aarch64`, `x86_64`, `riscv64` Android | 40/4 | 40/8 |

On `x86_64-linux-muslx32`, `mips64(el)-linux-muslabi64`,
`mips64(el)-linux-muslabin32`, `loongarch64-linux-muslsf`,
`loongarch64-linux-muslf32`, `loongarch64-linux-gnusf` and
`loongarch32-linux-gnusf` it does not compile, so neither does anything
that references it (`std.Thread` with libc, compiler_rt's emutls):

```
lib/std/c.zig:8185:21: error: unsupported ABI
```

Reproduce with `T` = `pthread_mutex_t`:

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
- All other targets agree.
- On 64-bit Android the same alignment mismatch (8 in Zig, 4 in C) exists
  in `pthread_rwlock_t`, whose bionic definition has the same shape.

## Root cause

`lib/std/c.zig:8172-8187` sized the Linux mutex by ABI and then by
architecture. The musl arm listed only `.musl`, `.musleabi`,
`.musleabihf` and OpenHarmony; the gnu arm lacked `.gnusf` and `.gnuf32`;
and the gnu sizes missed `.aarch64_be` (which has `.aarch64`'s 48), the
RISC-V glibc 32-bit size (32,
`lib/libc/include/riscv-linux-gnu/bits/pthreadtypes-arch.h:37`), and gave
`.mips64` 40 regardless of n32, whose pointers are 4 bytes. Every arm
aligned the bytes to `usize`, but bionic's 64-bit `pthread_mutex_t` and
`pthread_rwlock_t` are `int32_t` arrays (NDK
`sysroot/usr/include/bits/pthread_types.h:70-75` and `83-88`), aligned to
4.

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

- `lib/std/c.zig`, `pthread_mutex_t`: the ABI arms use `isMusl()` and
  `isGnu()`, so every musl and glibc ABI is covered; glibc `aarch64_be`
  gets 48, glibc `riscv32` 32, and `mips64` n32 falls to the 4-byte-pointer
  size, 24. Android aligns it to 4.
- `lib/std/c.zig`, `pthread_rwlock_t`: Android aligns it to 4.

Who sees a change: the mutex grows on `riscv32-linux-gnu` (24 to 32) and
`aarch64_be-linux-gnu` (40 to 48). Those were the dangerous mismatches:
glibc wrote past the end of a Zig-allocated mutex. It shrinks on
`mips64-linux-gnuabin32` (40 to 24): passing it to C was safe, and code
that stores one gets smaller. On 64-bit Android the mutex and rwlock keep
their sizes and drop from 8- to 4-byte alignment. The ABIs that did not
compile now do.

Source compatibility: the declarations keep their shape (`data` byte arrays
with zero defaults), so `.{}`, `.{ .data = @splat(0) }`,
`std.mem.zeroes(...)` and `undefined` compile as they did with 0.17.1.
Checked on `x86_64-linux-gnu`, `aarch64-linux-musl`,
`arm-linux-musleabihf`, `riscv32-linux-gnu`, `aarch64-linux-android` and
`arm-linux-androideabi`. One form cannot be kept: a `data` value of the old
length no longer fits where the mutex's size changed (`riscv32-linux-gnu`,
`aarch64_be-linux-gnu`, `mips64-linux-gnuabin32`), because the array's
length is the size being fixed. The `pthread_rwlock_t` change is alignment
only.

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
- arc, csky, m68k and loongarch32 could not be compiled as C. Their bundled
  headers give 24, and Zig gives 24 on all four (on `loongarch32-linux-gnusf`
  it did not compile before).
