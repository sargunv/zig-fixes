---
title: arm-linux-ohoseabi programs that link libc fail with undefined `__aeabi_*` helpers
priority: 1
area: lib/std
targets: [arm-linux-ohoseabi]
upstream: [codeberg#31427]
affects-line: yes
---

## Symptom

With a libc file pointing at the OpenHarmony SDK's `arm-linux-ohos` sysroot,
and with ohos-libc-support fixed:

```
$ zig build-exe hello.zig -target arm-linux-ohoseabi -lc --libc libc-arm.txt
error: ld.lld: undefined symbol: __aeabi_uidiv
    note: referenced by malloc_common.c
    note:               malloc_common.o:(calloc) in archive .../sysroot/usr/lib/arm-linux-ohos/libc.a
    note: referenced by int.zig:259 (compiler_rt/int.zig:259)
    ...
```

`zig cc -target arm-linux-ohoseabi hello.c` fails the same way, and also
lacks `__aeabi_dadd` and others.

## Evidence

- Reproduced on this line (0.17.1 plus the ohos-libc-support fix, macOS
  host) against OpenHarmony SDK 7.0. The libc file sets `sys_include_dir` and
  `crt_dir` to the `arm-linux-ohos` directories and `cc_dir` to
  `native/llvm/lib/clang/15.0.4/lib/arm-linux-ohos`.

## Root cause

`want_aeabi` (`lib/compiler_rt.zig:216-227`) lists the ARM EABI ABIs for
which compiler_rt exports the `__aeabi_*` run-time helpers. It has
`.androideabi` and the musl and gnu EABI ABIs but not `.ohoseabi`, so
compiler_rt exports only the generic names (`__udivsi3`, `__adddf3`, ...).
OpenHarmony's libc and code compiled for it call the `__aeabi_*` names.

## Fix sketch

Add `.ohoseabi` to `want_aeabi` (1 line). Done in a scratch copy: both the
Zig and the C hello world then link.

## Verification

The commands in Symptom link, and the binaries run on 32-bit ARM
OpenHarmony (or, statically linked, on any armv7 Linux). Not run yet: no
32-bit ARM emulator was available.

## Notes

- Split out of ohos-libc-support, which covers aarch64 and x86_64.
- Other 32-bit ARM OpenHarmony gaps: std-c-pthread-rwlock-32bit-size, and
  cb36723-arm-softfloat-neon-left-enabled.
