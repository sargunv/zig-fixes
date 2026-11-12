---
title: OpenHarmony programs that do not link libc fail with an undefined `__emutls_get_address`
priority: 1
area: target-defs
targets: [aarch64-linux-ohos, x86_64-linux-ohos, arm-linux-ohoseabi]
upstream: [codeberg#31427]
affects-line: yes
---

## Symptom

```
$ zig build-exe empty.zig -target aarch64-linux-ohos
error: ld.lld: undefined symbol: __emutls_get_address
    note: referenced by debug.zig:578 (lib/std/debug.zig:578)
    note:               .../empty_zcu.o:(debug.defaultPanic)
```

`empty.zig` is `pub fn main() void {}`. Every program fails this way, because
the default panic handler uses a threadlocal.

## Evidence

- Reproduced on 0.17.1 (macOS host) with the release binary.

## Root cause

- `src/target.zig:130` turns on emulated TLS for every OpenHarmony target,
  matching LLVM's default for OpenHarmony.
- `lib/compiler_rt/emutls.zig:20-22` exports `__emutls_get_address` only when
  linking libc, since it is built on `pthread_key_create`.
- `requiresLibC` (`lib/std/Target.zig:2304-2325`) forces libc for Android
  before API 29, the other emulated-TLS case, but not for OpenHarmony. So a
  build without libc emits emulated TLS accesses and nothing defines the
  helper.

## Fix sketch

Two candidates, a design choice:

- Make `requiresLibC` true for OpenHarmony, as for old Android (1 line). A
  build without a libc file then fails with "unable to provide libc" instead
  of a link error, and linking libc needs the SDK sysroot.
- Or use native TLS for OpenHarmony when libc is not linked. That needs
  `useEmulatedTls` to know whether libc is linked, and must not change the
  TLS model of code that is linked with OpenHarmony C code.

## Verification

`zig build-exe empty.zig -target aarch64-linux-ohos` either links or reports
that libc is required.

## Notes

- Split out of ohos-libc-support, which covers builds that link libc.
