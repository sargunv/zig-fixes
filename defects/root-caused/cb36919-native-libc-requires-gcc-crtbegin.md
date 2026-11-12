---
title: Native Linux libc detection requires GCC's crtbeginS.o, so zig cc and -lc fail on clang-only hosts
priority: 1
area: zig-cc
targets: [native-linux]
upstream: [codeberg#36919]
affects-line: yes
---

## Symptom

On a Linux host whose only C compiler is Clang with compiler-rt (Chimera Linux,
Gentoo musl/llvm, custom musl systems), anything that needs the native libc
fails with:

    error: failed to find libc installation: LibCRuntimeNotFound

This includes `zig cc --version`, `zig libc`, `zig build-exe -lc hello.zig`,
and bootstrapping Zig itself. Installing GCC makes it work. Regression: 0.16.0
works on the same hosts.

## Evidence

- codeberg#36919, reported on 0.17.0-dev.2265 and confirmed by several users
  on 0.17.0 and 0.18.0-dev.753; `zig cc --version` works on 0.16.0 and fails on
  0.17.0 on the same Chimera host.
- Not reproduced here (needs a GCC-less Linux host); the faulty code was read
  at 0.17.1.

## Root cause

`lib/std/zig/LibCInstallation.zig:229-232`: on Linux, `findNative` now calls
`findNativeGccDirPosix` unconditionally. That function
(`lib/std/zig/LibCInstallation.zig:471-477`) runs
`cc -print-file-name=crtbeginS.o`; Clang with compiler-rt has no file of that
name (it ships `clang_rt.crtbegin.o` or `clang_rt.crtbegin-<arch>.o` under
`cc -print-runtime-dir`), so it echoes the bare name and `ccPrintFileName`
returns `error.LibCRuntimeNotFound` (`lib/std/zig/LibCInstallation.zig:632`).
The GCC basenames are also hard-coded in `CrtBasenames.get`
(`lib/std/zig/LibCInstallation.zig:724`, Linux cases around lines 762-835). Introduced by commit c269a604b6
("fix: crtbegin/crtend not being linked on linux (#32064)"), first in 0.17.0.

## Fix sketch

When `crtbeginS.o` is not found, fall back to compiler-rt names
(`clang_rt.crtbegin.o`, then `clang_rt.crtbegin-<arch>.o` in the runtime dir),
record the actual crtbegin/crtend basenames in the installation (a patch in the
issue adds `crtbegin_obj`/`crtend_obj` fields), or make `cc_dir` optional for
native detection. Small to moderate.

## Verification

On a Linux container with only clang + compiler-rt + musl (e.g. Chimera or
Alpine with `clang compiler-rt` and no gcc): `zig cc --version` and
`zig build-exe -lc hello.zig` succeed.

## Notes

Workaround: symlink `crtbegin.o`, `crtbeginS.o`, `crtend.o`, `crtendS.o` to
the `clang_rt.*` objects in the runtime dir, or provide a `--libc` file.
Cross-compiling with bundled libcs is unaffected. No fix on `origin/master`.
