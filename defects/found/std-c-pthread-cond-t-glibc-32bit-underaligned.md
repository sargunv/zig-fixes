---
title: std.c.pthread_cond_t is 4-byte aligned on 32-bit glibc, where C aligns it to 8
priority: 3
area: lib/std
targets: [arm-linux-gnueabihf, mips-linux-gnueabihf, riscv32-linux-gnu, sparc-linux-gnu, x86_64-linux-gnux32, mips64-linux-gnuabin32]
upstream: []
affects-line: yes
---

## Symptom

On 32-bit glibc targets other than x86, `@alignOf(std.c.pthread_cond_t)`
is 4 but C's `_Alignof(pthread_cond_t)` is 8. Sizes agree (48). A Zig
`extern struct` embedding one and shared with C can be laid out
differently, and a `pthread_cond_t` that Zig places at a 4-byte boundary
is less aligned than glibc's 64-bit fields in it expect.

Reproduce with `T` = `pthread_cond_t`, using the reproduction in
std-c-pthread-attr-t-layout.

## Evidence

- Measured on this line with the release binary: arm and armeb
  `gnueabi`/`gnueabihf`, mips and mipsel `gnueabi`/`gnueabihf`,
  `mips64(el)-linux-gnuabin32`, `riscv32-linux-gnu`, `sparc-linux-gnu` and
  `x86_64-linux-gnux32` mismatch. `x86-linux-gnu` (where `long long` is
  4-byte aligned), musl and OpenHarmony agree.

## Root cause

`lib/std/c.zig:8241-8244` uses `align(@alignOf(usize))` for Linux. glibc's
`pthread_cond_t` union has a `long long __align` member
(`lib/libc/include/generic-glibc/bits/pthreadtypes.h:75-80`), so it takes
the alignment of `long long`.

## Fix sketch

Align to `c_longlong` on glibc ABIs. One or two lines.

## Verification

The comparison agrees on all Linux libc targets.

## Notes

- Found while fixing std-c-pthread-rwlock-32bit-size.
