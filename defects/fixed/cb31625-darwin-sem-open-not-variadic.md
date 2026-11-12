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
registers are not what libc reads when `O_CREAT` is set: it reads whatever is
on the stack instead. Depending on that garbage, `sem_open` fails with
`EINVAL`, or succeeds with the wrong initial value or mode.

## Evidence

- codeberg#31625, reported on 0.16.0-dev.2682 (aarch64-macos), comparing
  against the SDK's `sys/semaphore.h`.
- Reproduced at 0.17.1 on aarch64-macos: the program under Verification,
  run with `zig run repro.zig -lc --zig-lib-dir lib`, printed
  `sem_open failed: errno 22` (`EINVAL`).

## Root cause

`lib/std/c.zig:11315`: fixed-arity extern for a variadic C function. On
targets where variadic and fixed arguments share registers (x86_64 SysV,
aarch64 Linux) it happens to work; on Darwin arm64 it does not.

## Fix sketch

Make it `pub extern "c" fn sem_open(name: [*:0]const u8, flag: c_int, ...) *sem_t;`
(one line). There are no callers in this checkout. Callers outside need `@as`
casts for the variadic arguments, as C variadic calls require.

## Verification

On aarch64-macos, `sem_open("/zigtest", O_CREAT, 0o600, 3)` then
`sem_getvalue`/`sem_trywait` three times succeeding and the fourth failing
with EAGAIN.

## Fix

Cherry-picked upstream's aa5a7dc93d ("std.c: fix sem_open() to be
variadic") from `master`, which changes the declaration at
`lib/std/c.zig:11315` to `sem_open(name, flag: c_int, ...)`. It applied
cleanly and needs nothing else from `master`.

Added the test `sem_open passes mode and value as variadic arguments` at the
end of `lib/std/c.zig`, run on Darwin: it creates a semaphore with value 3 and
expects three `sem_trywait` successes, then `EAGAIN`. It fails without the
fix (the first `sem_trywait` returns -1) and passes with it.

Verified on aarch64-macos with the release 0.17.1 binary and this checkout's
`lib/`:

- The Verification program printed `sem_trywait succeeded 3 times, then
  errno 35` (`EAGAIN`), where it failed with `EINVAL` before.
- `zig test lib/std/std.zig --zig-lib-dir lib -lc --test-filter sem_open`
  passed.

## Notes

`std.c` has no `sem_unlink`, on this line or on `master`. Adding it would be
an API addition, outside this fork's scope; the test declares it locally.
