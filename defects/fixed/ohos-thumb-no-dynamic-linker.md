---
title: thumb-linux-ohoseabi executables get no dynamic linker and crash at startup
priority: 2
area: target-defs
targets: [thumb-linux-ohoseabi, thumb-linux-androideabi, thumb-linux-gnueabi, thumb-linux-gnueabihf, thumbeb-linux-gnueabi, thumbeb-linux-gnueabihf]
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

The same happens for Thumb on Android and glibc, where the executable has
no interpreter but the `arm`/`armeb` equivalent gets one. The SDK Clang's
`clang --target=arm-linux-ohos -mthumb hello.c` gets
`interpreter /lib/ld-musl-arm.so.1` and runs, and dynamic
`thumb-linux-musleabi` executables from Zig run.

## Evidence

- Reproduced on this line (0.17.1 plus ohos-libc-support and
  ohos-arm-aeabi-builtins, with a compiler built from it) with SDK 7.0,
  running under qemu-arm 8.2.2 with upstream musl's soft-float ARM loader
  standing in for OpenHarmony's. Both `zig cc hello.c` and
  `zig build-exe hello.zig -lc` crash this way.
- `DynamicLinker.standard` compared with the `-dynamic-linker` that Clang
  (the SDK's Clang 15) passes, for `arm`, `thumb`, `armeb` and `thumbeb`
  with each EABI ABI:

  | Target | Zig before | Clang |
  |---|---|---|
  | `thumb-linux-gnueabi`, `thumbeb-linux-gnueabi` | none | `/lib/ld-linux.so.3` |
  | `thumb-linux-gnueabihf`, `thumbeb-linux-gnueabihf` | none | `/lib/ld-linux-armhf.so.3` |
  | `thumb-linux-androideabi` | none | `/system/bin/linker` |
  | `thumb-linux-ohoseabi` | none | `/lib/ld-musl-arm.so.1` |
  | `armeb`/`thumbeb-linux-androideabi` | none | `/system/bin/linker` |
  | `armeb`/`thumbeb-linux-ohoseabi` | none | `/lib/ld-musl-armeb.so.1` |

  All `musleabi`/`musleabihf` rows and the `arm`/`armeb` glibc, `arm`
  Android and `arm` OpenHarmony rows already agreed.

## Root cause

`lib/std/Target.zig:2607`, `2625` and `2738-2744`: in `DynamicLinker.standard`
the Android arm of the Linux switch gives `/system/bin/linker` to `.arm`
only, the OpenHarmony arm gives `/lib/ld-musl-arm.so.1` to `.arm` only, and
the glibc arm gives `/lib/ld-linux{,-armhf}.so.3` to `.arm` and `.armeb`
only. `.thumb` (and for glibc `.thumbeb`) fall to `else => none`. The
loader does not depend on the instruction set: the musl arm of the same
switch already lists `.arm, .armeb, .thumb, .thumbeb` together, and Clang
treats `thumb` like `arm` for all three. This file is compiled into the
compiler, so a fix needs a compiler build.

## Fix sketch

As done; see Fix.

## Verification

- `zig test lib/std/std.zig --test-filter "thumb uses the arm loader"`:
  checks that `arm` and `thumb` get the same loader for glibc (`gnueabihf`),
  Android and OpenHarmony. It fails without the fix.
- A `thumb-linux-ohoseabi` executable shows
  `interpreter /lib/ld-musl-arm.so.1` and runs.

## Fix

- `lib/std/Target.zig`: `.thumb` joins `.arm` in the Android and
  OpenHarmony arms, and `.thumb` and `.thumbeb` join `.arm` and `.armeb` in
  the glibc arm.
- `lib/std/Target.zig`: the test above.

Big-endian Android and OpenHarmony are left without a loader: neither has
a big-endian ARM libc, though Clang names one.

Verified on a macOS aarch64 host with a compiler built from this change
(`0.17.1+fixes.2eb1885eb` plus the change):

- `DynamicLinker.standard` now agrees with Clang on every row above except
  the four big-endian Android and OpenHarmony ones.
- **OpenHarmony Thumb, run:** the C and Zig hello worlds and the C and Zig
  helper programs from ohos-arm-aeabi-builtins (Zig in Debug and
  ReleaseSafe), built for `thumb-linux-ohoseabi -mcpu cortex_a7` against
  SDK 7.0, now have `interpreter /lib/ld-musl-arm.so.1`. Under qemu-arm
  with the same stand-in loader they exit 0 with output identical to the
  host's. Their code is Thumb (`main` at an odd address, 16-bit
  encodings). The same C hello world built before the fix still
  segfaults.
- **Android Thumb, linked:** `zig cc -target thumb-linux-androideabi.24`
  with an NDK r30 libc file gives `interpreter /system/bin/linker`; the
  0.17.1 release gives none. Not run: no Android device or emulator here.
- **glibc Thumb, linked:** Zig cannot provide glibc for Thumb, so a
  `-nostdlib` C executable linked against a shared library was used.
  `thumb-linux-gnueabihf` now gets `/lib/ld-linux-armhf.so.3` and
  `thumbeb-linux-gnueabi` `/lib/ld-linux.so.3`, as their `arm`/`armeb`
  twins do; the 0.17.1 release gives neither an interpreter. Not run: no
  ARM glibc loader here.
- The std tests filtered on `Target` pass.

## Notes

- Found while fixing ohos-arm-aeabi-builtins.
