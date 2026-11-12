---
title: Inline asm "m" input operands get the address of a stack copy instead of the value's memory (LLVM backend)
priority: 1
area: codegen
targets: [all]
upstream: [codeberg#31022, codeberg#37205, codeberg#36335, github#10367]
affects-line: yes
---

## Symptom

An `asm` input with a memory-only constraint (`"m"`) reads the wrong memory:
the operand refers to a stack slot holding a *pointer* to the value, not the
value itself.

```zig
noinline fn loadThroughM(v: u32) u32 {
    return asm volatile ("movl %[m], %[out]"
        : [out] "=r" (-> u32),
        : [m] "m" (v),
    );
}
```

returns garbage with `-fllvm` in every optimize mode. Same for
`fldcw %[cw]` (#31022) and `ldmxcsr %[bits]` (#36335, which then faults with a
general protection exception). The self-hosted x86_64 backend is correct.

## Evidence

- codeberg#31022 (0.16.0-dev), #37205 (0.18.0-dev.146), #36335 (0.17.0-dev);
  all describe the same lowering. Migrated from github#10367.
- Reproduced on 0.17.1: the `loadThroughM` test built for `x86_64-macos`
  `-fllvm -O ReleaseSafe` and run under Rosetta fails with
  `expected 3735928559, found 36275108`. `fldcw` built for `x86_64-linux
  -O ReleaseSmall` disassembles to `lea rax,[rbp-2]; mov [rax],di;
  mov [rbp-0x10],rax; fldcw [rbp-0x10]`.

## Root cause

`src/codegen/llvm/FuncGen.zig:2710-2731`: a non-by-ref input whose constraint
does not allow a register is spilled to an alloca and the alloca *pointer* is
passed, but the constraint is copied verbatim (`m`). In LLVM, a direct `m`
operand means "this SSA value, in memory", so LLVM spills the pointer itself.
Clang emits `*m` with `elementtype(<ty>)` for this case. By-ref inputs with a
memory-allowing constraint (`FuncGen.zig:2700-2702`) have the same problem.
`elementtype` is only attached when the user wrote `*` (`FuncGen.zig:2743`).

## Fix sketch

When the input is passed as a pointer because of memory placement (spilled or
by-ref), emit `*` before the constraint and set `llvm_param_attrs` to the
element type. A commenter on #31022 tested a hack along these lines. Small
change in `airAssembly`.

## Verification

The `loadThroughM` test above passes with `-fllvm` in all modes; `fldcw`
disassembles to a single store and `fldcw` of that slot.

## Notes

Workaround: pass a pointer with `"*m"` or use the LLVM intrinsic
(`llvm.x86.sse.ldmxcsr`) as in #36335. Not fixed on origin/master.
