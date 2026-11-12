---
title: std.c.sem_open is declared non-variadic, wrong ABI on Apple arm64
priority: 1
area: lib/std
targets: [aarch64-macos, aarch64-ios]
upstream: [codeberg#31625]
affects-line: yes
---

## Symptom

`std.c.sem_open` is declared as
`fn sem_open(name, flag: c_int, mode: mode_t, value: c_uint) *sem_t`, but the
C prototype is `sem_t *sem_open(const char *, int, ...)`. On Apple arm64,
variadic arguments are passed on the stack, so `mode` and `value` passed in
registers are not what libc reads when `O_CREAT` is set. The reporter had to
redeclare it. `sem_unlink` is also missing from `std.c`.

## Evidence

- codeberg#31625, reported on 0.16.0-dev.2682 (aarch64-macos), comparing
  against the SDK's `sys/semaphore.h`.
- Read at 0.17.1: `lib/std/c.zig:11315` still has the non-variadic
  declaration. Not reproduced at run time.

## Root cause

`lib/std/c.zig:11315`: fixed-arity extern for a variadic C function. On
targets where variadic and fixed arguments share registers (x86_64 SysV,
aarch64 Linux) it happens to work; on Darwin arm64 it does not.

## Fix sketch

Make it `pub extern "c" fn sem_open(name: [*:0]const u8, flag: c_int, ...) *sem_t;`
(one line) and add `sem_unlink`. Callers in std, if any, need `@as` casts for
the variadic arguments.

## Verification

On aarch64-macos, `sem_open("/zigtest", O_CREAT, 0o600, 3)` then
`sem_getvalue`/`sem_trywait` three times succeeding and the fourth failing
with EAGAIN.

## Notes

Fixed on `origin/master` by aa5a7dc93d ("std.c: fix sem_open() to be
variadic"), a one-line backport candidate. `sem_unlink` is still absent on
master.
