---
title: std.c.pthread_rwlock_t is 56 bytes on 32-bit Linux, where musl, OpenHarmony and glibc use 32
priority: 2
area: lib/std
targets: [arm-linux-musleabihf, arm-linux-ohoseabi, x86-linux-musl, arm-linux-gnueabihf]
upstream: [codeberg#31427]
affects-line: yes
---

## Symptom

On 32-bit Linux targets other than Android, `@sizeOf(std.c.pthread_rwlock_t)`
is 56, but C's `sizeof(pthread_rwlock_t)` is 32. A Zig `extern struct` that
embeds one, and is shared with C code, has the wrong layout.

## Evidence

- Read at 0.17.1. The OpenHarmony SDK's Clang
  (`clang --target=arm-linux-ohos --sysroot=<sdk>/native/sysroot`) gives
  `sizeof(pthread_rwlock_t) == 32`, align 4.
- Zig's bundled musl headers define it as
  `union { int __i[sizeof(long)==8?14:8]; ... }`
  (`lib/libc/include/arm-linux-musl/bits/alltypes.h:396`), which is 32 bytes
  on 32-bit targets.

## Root cause

`lib/std/c.zig:8288-8302` gives Android its own sizes and every other Linux
ABI a fixed 56-byte layout, which is the 64-bit size.

## Fix sketch

Size the non-Android arm by pointer width: `if (@sizeOf(usize) == 8) 56 else
32`. Check glibc's 32-bit size (`__SIZEOF_PTHREAD_RWLOCK_T` is 32 on 32-bit
glibc targets) and `gnux32`/`muslx32` before folding them in.

## Verification

Compare `@sizeOf(std.c.pthread_rwlock_t)` against C's `sizeof` for
`arm-linux-musleabihf`, `arm-linux-ohoseabi` and `x86-linux-gnu`.

## Notes

- Split out of ohos-libc-support.
