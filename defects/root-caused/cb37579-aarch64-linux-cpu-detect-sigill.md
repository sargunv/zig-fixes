---
title: Native CPU detection on aarch64 Linux reads ID registers without checking HWCAP_CPUID, causing SIGILL
priority: 1
area: lib/std
targets: [aarch64-linux-gnu, aarch64-linux-musl, aarch64-linux-android]
upstream: [codeberg#37579]
affects-line: yes
---

## Symptom

On aarch64 Linux kernels that do not expose CPU ID registers to EL0 (no
`HWCAP_CPUID`, for example older Android phones under Termux), every `zig`
subcommand that resolves the native target dies with `Illegal instruction`.
`zig version` and `zig zen` still work. gdb shows the faulting instruction is
`mrs x9, midr_el1`.

## Evidence

- codeberg#37579 (0.18.0-dev.935, aarch64 Linux). A second commenter hit the
  same on an old Android phone and worked around it by checking `HWCAP_CPUID`
  and falling back to `/proc/cpuinfo`.
- Not reproduced (needs such a device). Faulty code read at 0.17.1.

## Root cause

`lib/std/zig/system/linux.zig:51` `aarch64.detectNativeCpuAndFeatures`
unconditionally executes `mrs` on `MIDR_EL1` and eleven `ID_AA64*_EL1`
registers. `linux.zig:927` calls it for every aarch64 host. The kernel
emulates these reads only when it advertises `HWCAP_CPUID`
(`std.os.linux.HWCAP.CPUID`, `lib/std/os/linux.zig:634`).

## Fix sketch

Check `std.os.linux.getauxval(AT.HWCAP) & HWCAP.CPUID` before the `mrs`
reads. Without it, fall back to parsing `/proc/cpuinfo` (the 32-bit `arm`
path already has a cpuinfo parser) or return null so the baseline CPU is used.
About 10–30 lines. `lib/std/zig/system/freebsd.zig:26` has the same unguarded
pattern and is worth checking.

## Verification

On a kernel without `HWCAP_CPUID` (or with the check forced off), `zig env`
and `zig build-exe` should run, with a baseline or cpuinfo-derived CPU.

## Notes

This affects Zig programs that do native target detection, not just the
compiler.
