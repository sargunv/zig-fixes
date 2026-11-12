---
title: std.c.pthread_attr_t on Linux is larger than C's on every ABI
priority: 2
area: lib/std
targets: [x86_64-linux-gnu, x86_64-linux-musl, aarch64-linux-gnu, aarch64-linux-musl, aarch64-linux-ohos, arm-linux-musleabihf, arm-linux-ohoseabi, x86-linux-gnu]
upstream: []
affects-line: yes
---

## Symptom

`@sizeOf(std.c.pthread_attr_t)` is 64 on 64-bit Linux and 60 on 32-bit
Linux. C's `sizeof(pthread_attr_t)` is 56 on 64-bit, and 36 on 32-bit
(32 on `gnux32` and `riscv32-linux-gnu`). Alignment agrees. A Zig
`extern struct` that embeds one and is shared with C has the wrong
layout. Passing a pointer to `pthread_attr_init` is unaffected, because
the Zig object is larger than C's.

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

- Measured on this line (0.17.1 plus ohos-libc-support) with the release
  binary for every Linux glibc and musl target Zig has libc headers for and
  an LLVM backend, and with the OpenHarmony SDK 7.0 Clang for
  `arm-linux-ohos`, `aarch64-linux-ohos` and `x86_64-linux-ohos`. Every
  one mismatches.

## Root cause

`lib/std/c.zig:8351-8355` declares it for Linux, Emscripten and DragonFly
as `extern struct { __size: [56]u8, __align: c_long }`. C declares a
union of the two (glibc `union pthread_attr_t`,
`lib/libc/include/generic-glibc/bits/pthreadtypes.h:56-60`; musl a union
inside a struct, `lib/libc/include/generic-musl/bits/alltypes.h:371`), so
the `c_long` is laid out after the bytes instead of over them. The 56
bytes are also the 64-bit size; 32-bit C uses 36 (glibc
`__SIZEOF_PTHREAD_ATTR_T`, musl `__i[9]`), or 32 on glibc `gnux32`
and `riscv32`.

## Fix sketch

Make the Linux layout an `extern union` with `__size` sized by pointer
width and ABI, keeping both field names. Check Emscripten and DragonFly
separately before changing them. Small, but it changes the type from a
struct to a union, which a caller initializing it field by field would
notice.

## Verification

The comparison in Symptom agrees for every Linux libc target.

## Notes

- Found while fixing std-c-pthread-rwlock-32bit-size.
