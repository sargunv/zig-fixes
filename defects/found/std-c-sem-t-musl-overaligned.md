---
title: std.c.sem_t is 8-byte aligned on 64-bit musl and OpenHarmony, where C aligns it to 4
priority: 2
area: lib/std
targets: [x86_64-linux-musl, aarch64-linux-musl, aarch64-linux-ohos, x86_64-linux-ohos, riscv64-linux-musl, loongarch64-linux-musl]
upstream: []
affects-line: yes
---

## Symptom

On 64-bit musl and OpenHarmony, `@alignOf(std.c.sem_t)` is 8 but C's
`_Alignof(sem_t)` is 4. The sizes agree (32). A Zig `extern struct` that
embeds a `sem_t` and is shared with C can have different padding.

Reproduce with `T` = `sem_t`, using the reproduction in
std-c-pthread-attr-t-layout.

## Evidence

- Measured on this line with the release binary for every 64-bit musl
  target, and with the OpenHarmony SDK 7.0 Clang for `aarch64-linux-ohos`
  and `x86_64-linux-ohos`. glibc targets and 32-bit musl targets agree.

## Root cause

`lib/std/c.zig:8413-8416` gives Linux one layout, `[4 * @sizeOf(usize)]u8
align(@alignOf(usize))`. That matches glibc, whose `sem_t` is a union with
a `long` (`lib/libc/include/generic-glibc/bits/semaphore.h:35-39`). musl's
is `struct { volatile int __val[4*sizeof(long)/sizeof(int)]; }`
(`lib/libc/include/generic-musl/semaphore.h:16-18`), aligned to `int`.

## Fix sketch

Use `align(@alignOf(c_int))` when the ABI is musl (which includes
OpenHarmony). A few lines.

## Verification

The comparison agrees on all Linux libc targets.

## Notes

- Found while fixing std-c-pthread-rwlock-32bit-size.
