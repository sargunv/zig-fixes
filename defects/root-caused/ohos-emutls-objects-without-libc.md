---
title: An OpenHarmony executable without libc cannot link objects that use emulated TLS
priority: 2
area: target-defs
targets: [aarch64-linux-ohos, x86_64-linux-ohos, arm-linux-ohoseabi]
upstream: []
affects-line: yes
---

## Symptom

A Zig static library built without libc for OpenHarmony, linked into an
executable without libc:

```
$ zig build-lib lib.zig -target aarch64-linux-ohos -OReleaseSafe
$ zig build-exe uses.zig liblib.a -target aarch64-linux-ohos -OReleaseSafe
error: ld.lld: undefined symbol: __emutls_get_address
    note: referenced by lib.zig:2
```

`lib.zig` exports a function that increments a `threadlocal`; `uses.zig`
calls it. C code with a `_Thread_local`, compiled for an OpenHarmony triple
and linked into such an executable, fails the same way.

## Evidence

- Reproduced on this line with a compiler built with the fix for
  ohos-emutls-without-libc. On 0.17.1 the executable fails earlier, on its
  own threadlocals.

## Root cause

`useEmulatedTls` (`src/target.zig:125-136`) keeps emulated TLS for
OpenHarmony objects and libraries, so that they match the SDK's C code,
which Clang compiles with emulated TLS by default. compiler_rt provides
`__emutls_get_address` only when linking libc
(`lib/compiler_rt/emutls.zig:20-22`), because it is built on pthread keys.
An executable without libc that pulls in such an object has nothing that
defines it.

## Fix sketch

Not decided. compiler_rt could provide an `__emutls_get_address` for builds
without libc, built on native TLS, since Zig's `_start` sets that up. That
is new runtime code rather than a small fix. The workaround is to build the
library for an executable without libc as part of that executable, or to
link libc.

## Verification

The commands in Symptom link, and the executable runs.

## Notes

- Follows from the fix for ohos-emutls-without-libc.
