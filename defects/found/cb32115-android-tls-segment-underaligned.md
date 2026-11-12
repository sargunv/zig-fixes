---
title: TLS segment underaligned for Android arm/arm64; bionic refuses to load the executable
priority: 1
area: linker
targets: [aarch64-linux-android, arm-linux-androideabi]
upstream: [codeberg#32115]
affects-line: likely
---

## Symptom

Bionic's loader requires the PT_TLS alignment to be at least 64 on arm64 and 32
on arm. Zig output often has 8, so running fails:
`error: "./test1-arm64": executable's TLS segment is underaligned: alignment is
8 (skew 0), needs to be at least 64 for ARM64 Bionic`.
An empty `pub fn main() void {}` triggers it; adding
`threadlocal var x: u8 align(64)` works around it.

## Evidence

- Reported on 0.17.0-dev.93, built on-device with
  `zig build-exe -target aarch64-linux-android test1.zig /system/lib64/libc.so`
  (codeberg#32115). Bionic check: `bionic/libc/bionic/bionic_elf_tls.cpp`.
- Not reproduced here (needs an Android device or emulator).

## Root cause

Not investigated. Guess: NDK clang avoids this because the NDK's crtbegin
objects carry an over-aligned TLS section, and Zig links no such object, so
PT_TLS gets only the program's own alignment.

## Fix sketch

When targeting Android arm/arm64, force PT_TLS alignment to 64/32: e.g. emit a
zero-size over-aligned `.tdata`/`.tbss` contribution from compiler-rt or the
start code, or have the linkers raise the TLS segment alignment. Small to
moderate.

## Verification

`readelf -l` on an Android build of an empty main shows TLS `Align 0x40`
(arm64) / `0x20` (arm); binary runs on device.

## Notes

Applies to shared libraries too, since bionic checks every loaded module.
