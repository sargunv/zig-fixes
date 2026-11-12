---
title: Zig's builtin headers precede user -isystem paths, breaking C++ with SDK libc++ (Emscripten)
priority: 1
area: zig-cc
targets: [wasm32-emscripten]
upstream: [codeberg#30090, github#20090]
affects-line: yes
---

## Symptom

Building C++ for `wasm32-emscripten` from `build.zig` with the Emscripten SDK's
libc/libc++ headers added via `addSystemIncludePath` fails:
`<cstddef> tried including <stddef.h> but didn't find libc++'s <stddef.h>
header ... The header search paths should contain the C++ Standard Library
headers before any C Standard Library`. Repro project:
codeberg.org/barath/zig-emscripten-includes.

## Evidence

- Reported on 0.16.0-dev.1522 (codeberg#30090).
- Maintainer (castholm): not Emscripten-specific; any external libc++ headers
  must come before the compiler's intrinsic headers in `zig/lib/include`.
  Workaround: use `addIncludePath` (`-I`) for the libc++ paths, ordered first.
- Not run here (needs emsdk); ordering read at 0.17.1.

## Root cause

`src/Compilation.zig:6477-6480` (in `addCCArgs`) appends
`-isystem <zig_lib>/include` (clang builtin headers) unconditionally, before
any user `-isystem` paths that come from module include options, so a
user-supplied libc++ `include/c++/v1` is searched after the builtin
`stddef.h`. Zig's own libc++ is fine because it is added above it
(lines 6462-6474).

## Fix sketch

Add the builtin header dir after user system include paths (as clang's driver
does with `-resource-dir` / `-internal-isystem`), or provide a "bring your own
libc++ headers" option analogous to `--libc`. Needs care not to break libc
headers' expectations. Moderate.

## Verification

The repro project builds with `addSystemIncludePath` pointing at
`emsdk/.../sysroot/include/c++/v1` and `.../sysroot/include`.

## Notes

Related known entry `emscripten-threads` (different problem).
