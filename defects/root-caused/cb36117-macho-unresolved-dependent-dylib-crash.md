---
title: Mach-O linker crashes when a framework's re-exported dependency cannot be resolved
priority: 1
area: linker
targets: [aarch64-macos, x86_64-macos]
upstream: [codeberg#36117]
affects-line: yes
---

## Symptom

Cross-compiling to macOS from Linux with an SDK and linking AppKit, Carbon,
CoreFoundation or QuartzCore crashes the compiler:
`panic: for loop over objects with non-equal lengths` at
`src/link/MachO.zig:1270 in parseDependentDylibs` (a segfault in release
builds of Zig). The reporter found `dylib.dependents` held
`/usr/lib/libobjc.A.dylib` while the resolved list was empty.

## Evidence

- Reported on 0.17.0-dev.1275 cross-compiling from x86_64-linux with a
  downloaded macOS SDK via `build.zig` `linkFramework` (codeberg#36117).
- Not reproduced: linking those frameworks natively on aarch64-macos with the
  Xcode SDK on 0.17.1 succeeds, because there `libobjc` resolves. The crash
  needs a dependent dylib that fails to resolve. Faulty code read at 0.17.1.

## Root cause

`src/link/MachO.zig:1108-1116`: when a dependent install name cannot be
resolved, the loop reports `unable to resolve dependency`, sets
`has_errors = true` and `continue`s without appending to `dependents`. The
loop at `src/link/MachO.zig:1140-1141` then zips `dylib.dependents.items` with
the shorter `dependents.items`, which panics (safety) or reads past the end
(release). So a missing dependency becomes a crash instead of the error message.

## Fix sketch

Return or skip the zip loop when `has_errors` is set after the resolution loop,
or append a null file index for unresolved entries and skip them. A few lines.
Separately, the underlying miss (`/usr/lib/libobjc.A.dylib` under `--sysroot`)
may deserve a look once the error is visible.

## Verification

Link `-framework AppKit` against a sysroot with `usr/lib/libobjc.A.tbd` removed:
expect a clean "unable to resolve dependency" error, no panic.

## Notes

Same code on origin/master.
