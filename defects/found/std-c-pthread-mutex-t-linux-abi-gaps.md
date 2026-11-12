---
title: std.c.pthread_mutex_t has the wrong size on some glibc targets and does not compile on several musl and loongarch ABIs
priority: 3
area: lib/std
targets: [riscv32-linux-gnu, mips64-linux-gnuabin32, aarch64_be-linux-gnu, x86_64-linux-muslx32, mips64-linux-muslabi64, mips64-linux-muslabin32, loongarch64-linux-muslsf, loongarch64-linux-gnusf]
upstream: []
affects-line: yes
---

## Symptom

`@sizeOf(std.c.pthread_mutex_t)` disagrees with C's `sizeof`:

| Target | C | Zig |
|---|---|---|
| `riscv32-linux-gnu` | 32 | 24 |
| `mips64(el)-linux-gnuabin32` | 24 | 40 |
| `aarch64_be-linux-gnu` | 48 | 40 |

On `x86_64-linux-muslx32`, `mips64(el)-linux-muslabi64`,
`mips64(el)-linux-muslabin32`, `loongarch64-linux-muslsf`,
`loongarch64-linux-muslf32` and `loongarch64-linux-gnusf` it does not
compile, so neither does anything that references it (`std.Thread` with
libc, compiler_rt's emutls):

```
lib/std/c.zig:8185:21: error: unsupported ABI
```

Reproduce with `T` = `pthread_mutex_t`, using the reproduction in
std-c-pthread-attr-t-layout.

## Evidence

- Measured on this line with the release binary for every Linux glibc and
  musl target Zig has libc headers for and an LLVM backend. All other
  targets agree.

## Root cause

`lib/std/c.zig:8172-8187` sizes the Linux mutex by ABI and then by
architecture. The musl arm lists only `.musl`, `.musleabi`,
`.musleabihf` and OpenHarmony; the gnu arm lacks `.gnusf` and `.gnuf32`;
and the gnu sizes are missing `.aarch64_be` (which has
`.aarch64`'s 48), the RISC-V glibc 32-bit size (32,
`lib/libc/include/riscv-linux-gnu/bits/pthreadtypes-arch.h:37`), and give
`mips64` 40 regardless of n32, whose pointers are 4 bytes.

## Fix sketch

Use `native_abi.isMusl()` and `isGnu()` for the ABI arms, and correct
the per-architecture glibc sizes. About ten lines.

## Verification

The comparison agrees on all Linux libc targets; `std.Thread` with libc
compiles for the musl ABIs above.

## Notes

- Found while fixing std-c-pthread-rwlock-32bit-size.
