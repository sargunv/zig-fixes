---
title: -femit-asm silently produces nothing for C sources in exe/lib and fails quietly for build-obj
priority: 1
area: compiler
targets: [all]
upstream: [codeberg#31415]
affects-line: yes
---

## Symptom

`-femit-asm` (and `Compile.getEmittedAsm()` in `build.zig`) does not produce
an assembly file but exits successfully:

```sh
zig build-exe main.c -lc -femit-asm=main.s   # exit 0, no main.s
```

The build system then fails later with `unable to update file ... main.s:
FileNotFound` when installing the emitted asm. A commenter saw the same
thing for Zig code on the self-hosted backend.

## Evidence

- Reported on 0.15.2; milestone Urgent.
- Reproduced on 0.17.1 (aarch64-macos host):
  - `zig build-exe main.c -lc -femit-asm=main.s`: exit 0, no file.
  - `zig build-lib main.c -femit-asm=lib.s`: exit 0, no file.
  - `zig build-obj main.c -femit-asm=obj.s`: prints `error(compilation):
    unable to copy '.../main.s' to 'obj.s': FileNotFound`, but still exits 0.
  - `zig build-exe minimal.zig -femit-asm=zig.s -target x86_64-linux`
    (self-hosted): exit 0, no file.

## Root cause

`src/Compilation.zig:3029-3035` emits asm/LLVM IR/bitcode for C only when
there is no ZCU, the output mode is `Obj`, and there is exactly one C
object. Every other combination ignores `emit_asm` without an error. For
`build-obj`, `emitFromCObject` (`src/Compilation.zig:3506`) expects a `.s`
next to the cached object that was apparently not produced. That part was not
investigated.

## Fix sketch

At minimum, give an error when an emit option cannot be honoured. A real fix
would pass `-S` output requests through to each clang invocation (or run a
separate pass per C object). Medium.

## Verification

Each command above either writes the file or exits non-zero with a clear
message. Add a standalone build test that installs `getEmittedAsm()` of a
C-only library.

## Notes

Workaround: `zig cc -S`.
