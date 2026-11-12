---
title: Subtracting two *anyopaque pointers crashes the compiler instead of erroring
priority: 1
area: compiler
targets: [all]
upstream: [codeberg#37548]
affects-line: yes
---

## Symptom

Pointer subtraction on pointers to an opaque type crashes Sema (SIGTRAP /
segfault, no diagnostic) instead of giving a compile error:

```zig
pub fn main() void {
    _ = @as(*anyopaque, @ptrFromInt(1)) - @as(*anyopaque, @ptrFromInt(1));
}
```

## Evidence

- Reported on 0.18.0-dev.860; alexrp's debug trace: `reached unreachable code`
  in `Type.abiSize` called from `Sema.analyzeArithmetic`.
- Reproduced on 0.17.1 (aarch64-macos host): `zig build-exe repro.zig
  -fno-emit-bin` exits with status 133 and prints nothing.

## Root cause

`src/Sema.zig:15108-15109` resolves layout and calls
`lhs_elem_ty.abiSize(zcu)` for pointer subtraction without first rejecting
opaque element types; `src/Type.zig:1254` has `.anyopaque => unreachable` in
`abiSize`. The existing zero-size check at `src/Sema.zig:15110` comes too late.

## Fix sketch

Before `ensureLayoutResolved`/`abiSize`, fail with a compile error when the
element type is `.@"opaque"` (e.g. "pointer subtraction requires element type
with known size"). A few lines plus a compile-error test case.

## Verification

The repro above must produce a compile error, not a crash. Add a
`test/cases/compile_errors` case for `*anyopaque - *anyopaque` and for a
user-declared `opaque {}`.

## Notes

Related: codeberg#35880 (indexing `*[1]anyopaque` also reaches
`abiSize` on an opaque type via `Value.ptrElem`). No fix on `origin/master`
as of this sweep.
