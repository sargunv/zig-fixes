---
title: thumb-linux-ohoseabi executables get no dynamic linker and crash at startup
priority: 2
area: target-defs
targets: [thumb-linux-ohoseabi]
upstream: []
affects-line: yes
---

## Symptom

With the OpenHarmony SDK's `arm-linux-ohos` libc file (see
ohos-arm-aeabi-builtins), `thumb-linux-ohoseabi` executables that link libc
link as dynamic executables but have no `PT_INTERP`, so the kernel starts
them at `_start` with no loader and they crash:

```
$ ZIG_LIBC=libc-arm.txt zig cc -target thumb-linux-ohoseabi -mcpu=cortex_a7 hello.c -o hello
$ file hello
hello: ELF 32-bit LSB executable, ARM, EABI5 version 1 (SYSV), dynamically linked, with debug_info, not stripped
$ qemu-arm -L <dir with lib/ld-musl-arm.so.1> ./hello
Segmentation fault
```

The SDK Clang's `clang --target=arm-linux-ohos -mthumb hello.c` gets
`interpreter /lib/ld-musl-arm.so.1` and runs. `arm-linux-ohoseabi` from
Zig does too, and so do dynamic `thumb-linux-musleabi` executables.

## Evidence

- Reproduced on this line (0.17.1 plus ohos-libc-support and
  ohos-arm-aeabi-builtins, compiler built from it) with SDK 7.0, running
  under qemu-arm 8.2.2 with upstream musl's soft-float ARM loader standing
  in for OpenHarmony's. Both `zig cc hello.c` and
  `zig build-exe hello.zig -lc` crash this way.

## Root cause

`lib/std/Target.zig:2619-2627`: the OpenHarmony arm of
`DynamicLinker.standard` gives `/lib/ld-musl-arm.so.1` to `.arm` only.
`.thumb` falls to `else => none`. The musl arm of the same switch lists
`.arm, .armeb, .thumb, .thumbeb` together. This file is compiled into the
compiler, so a fix needs a compiler build.

## Fix sketch

List `.thumb` beside `.arm` in the OpenHarmony arm (1 line). The Android
arm above it has the same shape for `thumb-linux-androideabi`; check it
separately.

## Verification

`file` shows `interpreter /lib/ld-musl-arm.so.1` for a
`thumb-linux-ohoseabi` executable, and it runs.

## Notes

- Found while fixing ohos-arm-aeabi-builtins.
