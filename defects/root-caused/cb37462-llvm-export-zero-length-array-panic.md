---
title: LLVM backend panics "TODO: export zero-bit value" when exporting a zero-length array
priority: 1
area: codegen
targets: [all]
upstream: [codeberg#37462, github#8547]
affects-line: yes
---

## Symptom

Exporting a zero-bit value crashes the compiler with the LLVM backend:

```zig
export const empty_array = [0]u8{};
```

`zig build-obj test.zig -fllvm` aborts with
`panic: LLVM TODO: export zero-bit value`.

## Evidence

- Reported on 0.18.0-dev.738 (codeberg#37462, migrated from github#8547).
- Reproduced on 0.17.1 (aarch64-macos host):
  `zig build-obj test.zig -fllvm -target x86_64-linux-gnu` exits 134 with the
  panic above.
- A comment shows the self-hosted ELF path also fails on a variant
  (`assert(name.len > 0)` in `src/link/Elf/ZigObject.zig` updateSymtabSize).

## Root cause

`src/codegen/llvm.zig:1171-1174`: when the exported value lowers to an LLVM
constant rather than a global (zero-bit values have no storage), the export
loop hits `.constant => @panic("LLVM TODO: export zero-bit value")`.

## Fix sketch

Either reject zero-bit exports with a compile error in Sema, or emit a
zero-sized (or 1-byte padded) global for the export so the symbol exists. Small.

## Verification

`zig build-obj` of the one-line reproduction with `-fllvm` succeeds and the
object defines `empty_array`; add a behavior/link test.

## Notes

Not fixed on origin/master as of this sweep (same panic string present).
