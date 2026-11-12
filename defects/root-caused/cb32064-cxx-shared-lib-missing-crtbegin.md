---
title: zig c++ shared libraries for Linux link without crtbeginS.o/crtendS.o and crash on dlclose
priority: 1
area: zig-cc
targets: [x86_64-linux-gnu, aarch64-linux-gnu, x86_64-linux-musl, aarch64-linux-musl]
upstream: [codeberg#32064, codeberg#30936]
affects-line: yes
---

## Symptom

C++ shared objects built with `zig c++ -shared` (bundled glibc or musl) get no
`crtbeginS.o`/`crtendS.o`, so nothing calls `__cxa_finalize(__dso_handle)` when
the library is unloaded. Static destructors registered with `__cxa_atexit`
then run after `dlclose` against unmapped code: the php-imagick extension
segfaults at exit.

## Evidence

- Reported on 0.16.0-dev by static-php-cli (codeberg#32064), who work around it
  by compiling LLVM's `crtbegin.c`/`crtend.c` per target and linking them in.
- Maintainer: native-only fix is insufficient; cross builds to be tackled
  with codeberg#30936 for 0.18.0.
- Checked on 0.17.1: `zig c++ -shared -fPIC -target x86_64-linux-gnu foo.cpp -v`
  shows an `ld.lld` line with no crtbegin/crtend objects.

## Root cause

`lib/std/zig/LibCInstallation.zig:765-797` asks for `crtbeginS.o`/`crtendS.o`
on Linux, but with bundled libc `getCrtPathsInner` looks them up in
`comp.crt_files` (`src/Compilation.zig:7676-7684`) and `crtFilePath`
(`src/Compilation.zig:7236-7238`) silently returns null because
`src/libs/glibc.zig` and `src/libs/musl.zig` never build them. The BSD libs do
build crtbegin (`src/libs/freebsd.zig:135`).

## Fix sketch

Build compiler-rt's `crtbegin.c`/`crtend.c` (or a Zig equivalent providing
`__do_global_dtors_aux` calling `__cxa_finalize(&__dso_handle)` plus
`.init_array`/`.fini_array` hooks) for Linux targets and link them for shared
libraries and PIE executables. Moderate.

## Verification

Build a `.so` with a static C++ object with a destructor, `dlopen`/`dlclose`
it, then exit: no crash, destructor runs at `dlclose`.

## Notes

Track upstream codeberg#30936.
