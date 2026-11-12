---
title: "Not root-caused: sscanf crashes in a MinGW DLL built with -D_GNU_SOURCE when the DLL also has a Zig root module"
priority: 1
area: bundled-libc
targets: [x86_64-windows-gnu]
upstream: [codeberg#32116]
affects-line: likely
---

## Symptom

A C++ file compiled into a Windows DLL with `-D_GNU_SOURCE` calls `sscanf`,
and the call crashes at run time. It works when the DLL has no
`root_source_file`, or when `_GNU_SOURCE` is removed. Reported trigger:
`b.addLibrary(.{ .linkage = .dynamic })` with `.root_source_file =
"expo.zig"`, `link_libc`, `link_libcpp`, a `parse.cpp` that does
`sscanf("RefScale=13.0", "RefScale=%f", &f)`, and
`addCMacro("_GNU_SOURCE", "")`; an exe that links the DLL and calls `parse()`
crashes. Found through raylib, which defines `_GNU_SOURCE`.

## Evidence

- codeberg#32116 (0.16.0, x86_64-windows-gnu). No comments; also filed as
  raysan5/raylib#5818.
- Checked on 0.17.1 from aarch64-macos: with `-D_GNU_SOURCE`,
  `zig c++ -target x86_64-windows-gnu -c parse.cpp` references
  `__mingw_sscanf`; without it, `sscanf`. Both DLL variants (with and without
  a Zig root module) link. Running them needs Windows, so the crash was not
  reproduced.

## Root cause

Not investigated. Known part: the bundled MinGW headers turn on
`__USE_MINGW_ANSI_STDIO` under `_GNU_SOURCE`, so `sscanf` becomes
`__mingw_sscanf` from Zig's mingw-w64 build. Why adding a Zig root module
changes the outcome is unknown. A guess: the Zig module brings in a different
definition of a symbol that `__mingw_sscanf` depends on, through compiler_rt
or Zig's libc.

## Fix sketch

Not investigated.

## Verification

Build the issue's three-file project for x86_64-windows-gnu and run `main.exe`
on Windows (or under Wine). It should exit cleanly. Compare which object
supplies `__mingw_sscanf` and its callees in the two DLLs, using the linker
map or PDB.

## Notes

Workaround: do not define `_GNU_SOURCE` for Windows targets.
