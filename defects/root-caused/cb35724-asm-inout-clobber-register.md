---
title: Inline asm naming a register as input, output and clobber drops the input copy; std.Io fiber contextSwitch does this
priority: 1
area: codegen
targets: [all]
upstream: [codeberg#35724]
affects-line: yes
---

## Symptom

```zig
noinline fn passThrough(p: *const u64) *const u64 {
    return asm volatile (""
        : [out] "={x1}" (-> *const u64),
        : [in] "{x1}" (p),
        : .{ .x0 = true, .x1 = true, .x2 = true, .memory = true });
}
```

In release builds the argument is never moved into `x1`; the asm sees the
caller's stale `x1`. GCC and Clang reject an in/out register that is also a
clobber; Zig silently miscompiles.

`lib/std/Io/fiber.zig` `contextSwitch` uses exactly this shape on aarch64
(`fiber.zig:42-46`, `x1`), riscv64 (`:139-150`, `a1`/`x11`) and x86_64
(`:255-262`, `rsi`). Every `std.Io.Evented` backend (Uring, Kqueue, Dispatch)
switches fibers through it.

## Evidence

- codeberg#35724, reported on 0.17.0-dev.813; the reporter says removing the
  register from each clobber list in `fiber.zig` fixes their runs.
- Reproduced on 0.17.1 (aarch64-macos native): the snippet's `main` exits 0
  in Debug and 1 (`error.InputCopyDropped`) in ReleaseSafe and ReleaseFast.
- `fiber.zig` at 0.17.1 still lists the message register as input, output and
  clobber on all three arches (read at the cited lines; unchanged on
  origin/master).

## Root cause

`src/codegen/llvm/FuncGen.zig` `airAssembly` passes clobbers straight
through (`FuncGen.zig:2786-2796`, `appendConstraints` at `:8076`) without
checking them against the output and input register constraints, so LLVM is
given an ill-formed constraint string. The std code then relies on it.

## Fix sketch

1. `lib/std/Io/fiber.zig`: drop `x1` / `x11` / `rsi` from the clobber lists
   (three one-line deletions).
2. In Sema or `airAssembly`, reject (compile error) a clobber that names a
   register also used as an explicit input or output constraint.

## Verification

The snippet returns `&value` in ReleaseFast. Run the `std.Io` Evented tests
in ReleaseFast on aarch64-macos (Dispatch/Kqueue) and x86_64-linux (Uring).

## Notes

The issue also points out aarch64/riscv64 `contextSwitch` does not clobber
condition flags (`nzcv`), unlike x86_64. Related: cb37533 (zmm clobbers in
the same function).
