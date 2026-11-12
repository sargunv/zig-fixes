---
title: Self-hosted ELF linker does not search the libc file's crt_dir for libc, libm, libdl
priority: 1
area: linker
targets: [x86_64-linux-android]
upstream: [codeberg#35239]
affects-line: likely
---

## Symptom

Building an Android library with a `--libc` installation file fails to find
`libc`, `libm` and `libdl` when Zig's own ELF linker is used; setting
`use_lld = true` makes it link.

## Evidence

- Reported on 0.16.0 while building a (private) Android app (codeberg#35239);
  no minimal reproduction.
- A commenter noted `crt_dir` is only used in `src/link/Lld.zig` and in
  `src/link/Elf.zig`'s argv dump.
- Not reproduced here (needs an NDK sysroot). In 0.17.1, Debug builds for
  x86_64 ELF targets, including x86_64-linux-android, default to the
  self-hosted backend and therefore the self-hosted linker
  (`src/target.zig:311-331`, `src/Compilation/Config.zig:404-407`).

## Root cause

Partly read: LLD gets `-L <crt_dir>` (`src/link/Lld.zig:1067`). In
`src/link/Elf.zig:1035-1039` the `-L crt_dir` appears only in the verbose
argv dump, not in input resolution. Where the self-hosted path resolves
`-lc`/`-lm`/`-ldl` was not located in a short look; not investigated further.

## Fix sketch

Not investigated. Likely: add `libc_installation.crt_dir` to the library search
directories used to resolve system libs when linking libc with the self-hosted
ELF linkers (old and Elf2).

## Verification

`zig build-lib -dynamic -target x86_64-linux-android --libc android.txt -lc
foo.zig` (Debug) links against the NDK sysroot's libc.so.

## Notes

Related known entry `android-libc-file-cc-dir` (libc file key requirements) is
a different defect.
