---
title: Weak exports lose their weak (or even external) binding on Mach-O with the LLVM backend, including all of compiler-rt
priority: 1
area: codegen
targets: [aarch64-macos, x86_64-macos, aarch64-ios, aarch64-tvos, aarch64-visionos, aarch64-maccatalyst]
upstream: [codeberg#31844]
affects-line: yes
---

## Symptom

On Darwin targets, symbols exported with `.linkage = .weak` come out wrong:

- compiler-rt bundled into a static library: `___ctzdi2` etc. are
  `private external` instead of `weak private external`, so users cannot
  override them and several Zig static libraries can collide.
- A user's own weak export in an object file is emitted as a *local*
  symbol, so C code cannot link against it:

```zig
fn foo() callconv(.c) u32 { return 1; }
comptime { @export(&foo, .{ .name = "foo", .linkage = .weak }); }
```

`zig build-obj` gives `non-external _foo`; `zig cc main.c w.o` fails with
`undefined symbol: _foo`. With `.strong` it is `external _foo`.

## Evidence

- codeberg#31844: regression first seen in 0.16.0-dev.3061 (dev.3041 emitted
  `weak private external`). mlugg confirmed it still fails with LLVM 22 and
  filed llvm/llvm-project#196047.
- Reproduced on 0.17.1 (aarch64-macos): compiler-rt symbols in
  `zig build-lib -fcompiler-rt -fllvm` are `private external`; for
  `aarch64-linux-gnu` they are `W`. The user weak export above is
  `non-external _foo` on macOS and `W foo` on aarch64-linux, and linking it
  from C on macOS fails as shown.

## Root cause

`src/codegen/llvm.zig:1223` onwards (`addGlobalExport`): every export is an
LLVM alias to a private global, with `weak_odr` set on the alias
(`llvm.zig:1286`). LLVM's Mach-O output loses the weak/external binding of
such aliases (maintainer diagnosis; upstream bug above).

## Fix sketch

Extend the existing `workaround_alias_bugs` path (`llvm.zig:1219`, `:1241`)
to Mach-O: when a global has one export, rename the global to the export name
and set linkage and visibility on it directly instead of aliasing. Multiple
exports of one global still need aliases. Small to medium change.

## Verification

On aarch64-macos: `nm -m` shows `weak external _foo` for the snippet and
`weak private external ___ctzdi2` for a `-fcompiler-rt` static library; a C
program links against the weak export.

## Notes

Not fixed on origin/master.
