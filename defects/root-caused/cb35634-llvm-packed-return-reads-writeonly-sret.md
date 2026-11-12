---
title: Returning a packed struct in an error union reads uninitialized, writeonly sret memory
priority: 1
area: codegen
targets: [all]
upstream: [codeberg#35634]
affects-line: yes
---

## Symptom

Miscompilation under ReleaseSafe with the LLVM backend: the callee builds a
packed struct in the sret result pointer using a load/mask/store of bytes
it never initialised, so the returned padding bits come from garbage. Because
the pointer is also marked `writeonly`, the load is undefined behaviour in LLVM.

```zig
pub const PackedString = packed struct(u58) { index: u32 = 0, len: u26 = 0 };
noinline fn makePackedString(idx: u32, len: u26) !PackedString {
    return .{ .index = idx, .len = len };
}
test {
    @import("std").mem.doNotOptimizeAway(makePackedString(0, 0) catch unreachable);
}
```

## Evidence

- Reported on 0.16.0 and 0.17.0-dev.224; milestone Urgent.
- Reproduced on 0.17.1: `zig test repro.zig -OReleaseSafe
  -femit-llvm-ir=out.ll -fno-emit-bin` gives `define internal fastcc void
  @repro.makePackedString(ptr dead_on_unwind noalias nonnull writeonly align 8
  ... initializes((8, 10)) %0)` whose body does `load i64, ptr %0`, `and`,
  `store i64` on bytes 0-7.

## Root cause

`src/codegen/llvm.zig:2432` (`addSRetFnAttributes`) marks the sret pointer
`writeonly`, but the body reads it. The read most likely comes from per-field
bit-pointer stores into the packed-struct result location, each lowered as
read-modify-write (a guess; not traced).

## Fix sketch

Not investigated. Options: build the packed value in a register and store it
whole, or stop marking sret `writeonly` when the body reads it.

## Verification

The emitted IR must not load from the sret argument. Add an LLVM IR check
or a behavior test that returns `!PackedStruct` and checks every bit
through `@bitCast` under ReleaseSafe and ReleaseFast.

## Notes

`writeonly` on sret is still emitted on `origin/master`. The release fix
586601727a ("pack aggregates when LLVM aligns a field more strictly") is a
different bug.
