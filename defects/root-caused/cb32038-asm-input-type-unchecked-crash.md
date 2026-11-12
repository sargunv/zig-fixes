---
title: Inline asm inputs are not type-checked; a function body as input crashes codegen
priority: 1
area: compiler
targets: [all]
upstream: [codeberg#32038]
affects-line: yes
---

## Symptom

Passing a function (instead of `&func`) as an inline assembly input crashes
the LLVM backend instead of producing a compile error:

```zig
export fn foo() void {}
pub fn main() void {
    asm volatile ("br %[func]" :: [func] "r" (foo));
}
```

The reporter found that inputs of type `type`, `void`, `noreturn`, `null`,
`undefined`, error sets/unions, enum literals, enums, unions, functions,
opaque and `anyframe` all crash or misbehave. It compiled with 0.15.2, so this
is a regression since 0.16.0.

## Evidence

- Reported on 0.17.0-dev.128; trace ends at `assert(ty.hasRuntimeBits(zcu))`
  in `codegen/llvm.zig` `lowerValue`.
- Reproduced on 0.17.1 (aarch64-macos, LLVM backend): `zig build-exe
  repro.zig` exits 133 with no diagnostic.

## Root cause

`src/Sema.zig:15503-15523` (`zirAsm`, input loop) only coerces
`comptime_int`/`comptime_float` and otherwise passes the operand through
unchecked. Outputs get a full type switch with "invalid inline assembly output
type" errors (`src/Sema.zig:15418-15487`). The LLVM backend then hits
`src/codegen/llvm.zig:3164`.

## Fix sketch

Mirror the output type validation for inputs (reject zero-bit and
comptime-only types; for `.@"fn"` add a note suggesting `&foo`). Small.

## Verification

The repro gives a compile error suggesting `&foo`. Add compile-error cases for
fn, void, type, and enum-literal inputs.

## Notes

alexrp agrees in the issue that this is a missing frontend error.
