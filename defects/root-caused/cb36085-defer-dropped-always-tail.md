---
title: defer is silently dropped in a function that ends with @call(.always_tail, ...)
priority: 1
area: compiler
targets: [all]
upstream: [codeberg#36085]
affects-line: yes
---

## Symptom

Pending `defer`s in scope at an `@call(.always_tail, ...)` are not executed
and no error is reported:

```zig
pub extern fn abc() void;
pub extern fn def() void;
pub export fn some_function() void {
    defer abc();
    @call(.always_tail, def, .{});
}
```

The generated function is `musttail call void @def(); ret void`. `abc` is
never called.

## Evidence

- Reported on 0.17.0-dev.1099 with `-fllvm -femit-llvm-ir`.
- Reproduced on 0.17.1: `zig build-lib repro.zig -fllvm
  -femit-llvm-ir=out.ll -fno-emit-bin`; the function body in `out.ll` has
  only the `musttail call` to `@def` and `ret void`. There is no call to `@abc`.

## Root cause

`src/Sema.zig:7104-7116` routes `.call_always_tail` to `handleTailCall`
(`src/Sema.zig:7426`), which emits an AIR `ret` directly (line 7442) and
returns `unreachable_value`. The defer bodies, which AstGen places on the
scope-exit path after the call, become dead code. Nothing checks for pending
defers.

## Fix sketch

Per the issue comments and github#694, this should be a compile error ("tail
call with pending defer"). Sema would need to know about active defers at the
call site (AstGen could record it, or reject the case itself when the
modifier is comptime-known `.always_tail`). Not investigated further.

## Verification

The repro gives a compile error. Also check `errdefer` and nested blocks.

## Notes

The self-hosted backends do not implement tail calls yet, so only LLVM
builds are affected today.
