---
title: DriverKit builds cannot link libc, even against the DriverKit SDK
priority: 2
area: compiler
targets: [aarch64-driverkit, x86_64-driverkit]
upstream: []
affects-line: yes
---

## Symptom

Every DriverKit build that links libc fails, with or without the SDK:

```
$ zig build-exe hello.zig -target aarch64-driverkit
error: undefined symbol: _writev
error: undefined symbol: _wait4
... (101 errors in total)
```

`--sysroot $(xcrun --sdk driverkit --show-sdk-path)` gives the same 101
errors. A C file that includes `<stdlib.h>` fails earlier, with
`'stdlib.h' file not found`. Only a program that uses no libc symbol or
header links, and then against the bundled macOS stub.

## Evidence

Reproduced with the 0.17.1 release on macOS (Apple silicon), Xcode 26.4.1,
DriverKit25.4.sdk.

- With no flags, or with `--sysroot`: 101 undefined symbols for hello world.
  The compiler loads the bundled `lib/libc/darwin/libSystem.tbd`, which lists
  no DriverKit target (see `apple-device-sdk-libsystem` for the same fallback
  on device targets). `--sysroot` only adds `-syslibroot`.
- `zig libc -target aarch64-driverkit` writes `crt_dir=<sdk>/usr/lib` and
  `include_dir=<sdk>/usr/include`, but the DriverKit SDK has no `usr/`. Its
  libraries and headers are in `<sdk>/System/DriverKit/usr/lib` and
  `<sdk>/System/DriverKit/usr/include`. Its `libSystem.tbd` there lists
  `[ x86_64-driverkit, arm64e-driverkit ]`.
- With a hand-written `--libc` file that points at
  `System/DriverKit/usr/{include,lib}`, a C program that calls `malloc`
  links. Zig hello world still fails, on 6 symbols that DriverKit's
  libSystem does not export: `__availability_version_check`,
  `__tlv_bootstrap`, `_fcopyfile`, `_freeaddrinfo`, `_getaddrinfo`,
  `_if_nametoindex`.

## Root cause

Two separate causes, not fully investigated:

1. `LibCInstallation.findNative` (`lib/std/zig/LibCInstallation.zig:195-198`)
   assumes every Apple SDK keeps libc under `usr/include` and `usr/lib`.
   DriverKit's SDK keeps it under `System/DriverKit/usr/`.
2. The standard library (and maybe compiler_rt) references functions and
   thread-local storage that DriverKit's libSystem does not provide. Which
   code references each of the 6 symbols has not been traced.

## Fix sketch

Not investigated. Cause 1 is a path choice in `findNative` for
`.driverkit`, and in whatever builds a libc installation from `--sysroot`.
Cause 2 needs the std and compiler_rt references found, and either guarded
for DriverKit or accepted as unsupported.

## Verification

`zig build-exe hello.zig -target aarch64-driverkit` on a Mac with Xcode links,
and so does a C file that calls `malloc`.

## Notes

- `apple-device-sdk-libsystem` deliberately leaves DriverKit alone: routing it
  to the SDK would fail on cause 1 even for programs that link today.
