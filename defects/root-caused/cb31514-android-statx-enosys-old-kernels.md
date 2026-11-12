---
title: std.Io stat uses statx only, so it fails on Android devices with kernels before 4.11
priority: 1
area: lib/std
targets: [aarch64-linux-android, arm-linux-androideabi, x86_64-linux-android, x86-linux-android]
upstream: [codeberg#31514]
affects-line: yes
---

## Symptom

On a Fairphone 3 (Android 9 to 15, kernel 4.9), `zig init` fails with
`error: unable to make path 'src': Unexpected`; strace shows `statx`
returning ENOSYS. The same applies to any Zig program built for Android that
uses `std.Io` stat (`Dir.statFile`, `File.stat`, `makePath`, ...) on such a
device.

## Evidence

- codeberg#31514, reported on 0.16.0-dev.2821 (aarch64, Termux).
- Read at 0.17.1: the Linux stat paths call only `statx` with no `fstatat`
  fallback. Not reproduced (no Android device here).
- Zig's default minimum Android API level is 29 (Android 10)
  (`lib/std/Target.zig:507`). Android 10 to 12 devices may run 4.9 or 4.14
  kernels, and `statx` arrived in Linux 4.11, so Zig's default Android floor
  allows kernels this code cannot handle.

## Root cause

`lib/std/Io/Threaded.zig:3759` (`dirStatFileLinux`) and
`lib/std/Io/Threaded.zig:4054` (`fileStatLinux`) call `statx` directly, or
through bionic when API >= 30 (`statx_use_c`, line 2089; bionic's `statx` is a
plain syscall stub). ENOSYS falls to `posix.unexpectedErrno` and becomes
`error.Unexpected`. Other `statx` users: lines 3926, 3961, 8758.

## Fix sketch

On Linux, when the ABI is Android, map ENOSYS from `statx` to a fallback
using `fstatat`/`fstat` (an `fstatat_sym` already exists at line 2072 for
other POSIX). Cache the fallback in an atomic flag. Medium-small.

## Verification

Run a test that stats a file under an Android emulator image with a 4.9
kernel (e.g. Android 9 or 10 x86_64 system image), or use seccomp to make
`statx` return ENOSYS on Linux.

## Notes

Upstream's stance (andrewrk, alexrp): kernels below 5.10 are unsupported, so
upstream is unlikely to take a fix. 32-bit arm Android is where old kernels
are most common. Master still calls only `statx`.
