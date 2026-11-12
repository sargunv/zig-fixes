---
title: zig cc -flto for MinGW fails with undefined libzigc and libm symbols
priority: 1
area: bundled-libc
targets: [x86_64-windows-gnu, aarch64-windows-gnu]
upstream: [codeberg#31958]
affects-line: yes
---

## Symptom

```sh
echo 'int main(void){}' | zig cc -target x86_64-windows-gnu -flto -x c -
```

fails at link: `lld-link: error: <root>: undefined symbol: frexpf`, `frexpl`,
`modfl`, `atanl`, `copysignl`, and `undefined symbol: wmemchr ... referenced by
zigc.lib(zigc_zcu.obj)` for `wmemcpy`, `mempcpy`, `strtok_r`, `isnan`, etc.
Any LTO build for MinGW is broken.

## Evidence

- Reported on 0.16.0 (codeberg#31958). Commenter: does not occur if zigc
  symbols are not weak (link to PR #31177 discussion).
- Reproduced on 0.17.1 from aarch64-macos: `zig cc -target x86_64-windows-gnu
  -flto m.c -o m.exe` fails with the same `<root>` undefined symbols
  (`frexpf`, `frexpl`, `lrintl`, `lroundl`, `modfl`, `rintl`, `atanl`, ...).

## Root cause

`lib/c.zig:31-42`: every libzigc function is exported with
`.linkage = .weak`. In COFF, weak definitions become weak externals; under LTO,
lld-link does not resolve libcalls and archive members against them, so
symbols that libzigc provides end up undefined. (Diagnosis from the issue
comment; mechanism in lld-link not verified.)

## Fix sketch

Use strong linkage for libzigc exports on COFF targets (they live in a static
archive, so they are already overridable), or at least when LTO is enabled.
Small; check that the in-ZCU libc use case that motivated weak still works.

## Verification

The one-line reproduction links; run a MinGW LTO build of a program calling
`frexpl` and `wmemcpy` under Wine.

## Notes

May interact with `cb36412-mingw-lto-catch-all-missed.md`.
