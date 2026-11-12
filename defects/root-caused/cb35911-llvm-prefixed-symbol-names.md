---
title: A source file or module named llvm makes LLVM abort, because its symbols get the reserved "llvm." prefix
priority: 1
area: codegen
targets: [all]
upstream: [codeberg#35911, github#2291]
affects-line: yes
---

## Symptom

```
$ echo 'test {}' > llvm.zig; zig test -fllvm llvm.zig
llvm intrinsics cannot be defined!
ptr @llvm.test_0
LLVM ERROR: Broken module found, compilation aborted!
```

It is not limited to the root file: `main.zig` doing
`@import("llvm.zig")` and calling a function from it aborts the same way
(`ptr @llvm.bar`). Any project with `src/llvm.zig`, or a module named `llvm`
(for example LLVM bindings), cannot build with the LLVM backend.

## Evidence

- codeberg#35911, reported on 0.17.0-dev.955. rpkak cites the LLVM LangRef:
  the `llvm.` prefix is reserved for intrinsics.
- Reproduced on 0.17.1 (aarch64-macos): the `zig test` one-liner above, a
  `zig build-exe` of a root `llvm.zig`, and a `main.zig` importing a
  non-root `llvm.zig` all abort with "llvm intrinsics cannot be defined!".

## Root cause

The LLVM backend names private globals after the declaration's fully
qualified name, which starts with the file/module namespace:
`src/codegen/llvm.zig:740`, `:1033` and `:3914`
(`o.builder.strtabString(nav.fqn.toSlice(ip))`). Nothing escapes a leading
`llvm.`.

## Fix sketch

Add one helper used at those three sites (and anywhere else an fqn becomes an
LLVM symbol name) that rewrites a leading `llvm.` to something else, e.g.
`llvm_.` or `.llvm.`. Exported names are user-chosen and can stay as is (or
get a compile error). Small change.

## Verification

`zig test -fllvm llvm.zig` with `test {}` passes; a two-file program
importing `llvm.zig` builds. Add a standalone test.

## Notes

Not fixed on origin/master.
