---
title: LoongArch C calling convention splits all-integer small structs across registers and uses wrong field offsets, corrupting extern calls
priority: 1
area: codegen
targets: [loongarch64-linux-gnu, loongarch64-linux-musl, loongarch32-linux-gnu]
upstream: [codeberg#35798]
affects-line: yes
---

## Symptom

Calling a C function that takes a small struct by value from Zig, or exporting
one to C, passes the wrong registers.

- A struct of two `u32`s is passed in two GPRs instead of being packed into
  one. Every later argument shifts by one register.
- Mixed and float structs keep the right signature, but their second field
  becomes garbage.

A C function taking `struct { uint32_t width, height; }` by value followed by
a pointer receives the second field as the pointer. Called from Zig with
`.{ .width = 0, .height = 8 }`, the callee dereferenced 8:

```
Segmentation fault at address 0x8
```

Minimal reproduction. `p.zig` declares `extern struct`s Size `{u32,u32}`, IL
`{u32,u64}`, CF `{u8,f32}`, and FD `{f32,f64}`, plus
`extern fn take_X(s: X, after: u32) void`, and exports
`call_X(s) { take_X(s, 7); }`. `p.c` is the same in C.

```
zig build-obj p.zig -target loongarch64-linux-gnu -O ReleaseFast -femit-llvm-ir=z.ll -fno-emit-bin
zig cc -target loongarch64-linux-gnu -O2 -S -emit-llvm p.c -o c.ll
```

Zig 0.17.1 against clang (from the same `zig`):

```
Zig: call void @take_size(i32 %0, i32 %1, i32 signext 7)     C: call void @take_size(i64 %0, i32 noundef signext 7)
Zig: call void @take_il(i32 %0, i64 0, i32 signext 7)        C: call void @take_il([2 x i64] %0, i32 noundef signext 7)
Zig: call void @take_cf(i8 %0, float undef, i32 signext 7)   C: call void @take_cf(i8 %0, float %1, i32 noundef signext 7)
Zig: call void @take_fd(float %0, double undef, i32 signext 7) C: call void @take_fd(float %0, double %1, i32 noundef signext 7)
```

Assembly and return-path results (second-hand):
- In the asm, Zig loads `after` with `ori $a2, $zero, 7` and C with
  `ori $a1, $zero, 7`.
- For a function returning Size, Zig declares `{ i32, i32 } @get_size()` while
  C declares `i64 @get_size()`. Reading `.height` gives `addi.w $a0, $a1, 0` in
  Zig and `srai.d $a0, $a0, 32` in C.
- `struct { float a[2]; }` lowers as `(i64, ...)` in Zig and
  `(float, float, ...)` in C.
- The Debug IR for FD shows `alloca [8 x i8]`, a 16-byte memcpy into it (a
  stack overflow), and `load double` at offset 4 instead of 8.

The same probe on RISC-V matches clang in all cases.

## Evidence

- Reproduced on Zig 0.17.1. The probe files were not kept.
- First seen on Zig 0.17.0. The crash was observed under `qemu-loongarch64`
  10.2.3 and confirmed with a standalone Zig-calls-C probe
  (`width=0 height=0 completion=0x8`).
- Upstream already knows: `test/c_abi/main.zig` skips 110 tests with
  `if (builtin.cpu.arch == .loongarch64) return error.SkipZigTest;`, including
  `test "struct u32, u32"` at line 15667 and `test "struct i32 i32"`.
- The C ABI support was added by 703baa4cd6 ("llvm: implement c abi for
  loongarch", first released in 0.17.0), which closed codeberg#35798.

## Root cause

Verified by reading code at 0.17.1 (the classification and the `second_size`
line first-hand; the other FuncGen line ranges second-hand).

1. **Wrong classification** (`src/codegen/loongarch/abi.zig:16-29`).
   - `Class.combineMember` turns any two scalar members into `.member_pair`
     (line 26) without checking that at least one member is a float (`.far`).
   - The LoongArch LP64 psABI, like RISC-V's, splits a struct into separate
     registers only for float+float or float+int. An all-integer aggregate of
     at most 2×GRLEN must be packed into one or two GPRs.
   - Zig's RISC-V classifier gets this right: `src/codegen/riscv64/abi.zig:24-39`
     returns `.fields` only when `any_fp`, and otherwise uses
     `.integer`/`.double_integer`.
2. **Wrong offsets** (`src/codegen/llvm/FuncGen.zig:7186-7197`).
   - The `.member_pair` lowering has a copy-paste bug at line 7192:
     `const second_size = member_tys[0].abiSize(zcu);` (should be
     `member_tys[1]`).
   - It builds offsets as `{0, first_size, first_size + second_size}`,
     ignoring field alignment and padding.
   - These offsets set the alloca size and the load/store positions at the
     call site (`FuncGen.zig:869-880`) and in the callee prologue
     (`FuncGen.zig:265-276`). The result is an undersized alloca and fields
     read from the wrong place for `{u32,u64}`, `{u8,f32}`, and `{f32,f64}`.
3. **Return path** (`FuncGen.zig:7609-7614`). `.member_pair` becomes an LLVM
   `{T0, T1}` return, which comes back in a0 and a1. C returns an all-integer
   struct packed in a0.
4. **Lesser gaps (inferred, not probed except `[2]f32`):**
   - Nested structs and arrays are not flattened: `combineMember` returns
     `.address` for a nested `.member_pair`, so `struct { float a[2]; }` goes
     in a GPR.
   - Nothing tracks the remaining argument registers (clang's
     `GARsLeft`/`FARsLeft`), so float+int structs are wrong once the FPRs run
     out.
   - Variadic arguments are not special-cased.

origin/master: not fixed (verified).
- The only changes to `loongarch/abi.zig` are 4cb76bab3f, which derives
  `frlen` from `target.abi.float()` instead of CPU features, and the
  `packed`→`bitpack` rename.
- The `second_size` typo and the c_abi skips remain.
- 1a0778dc20/586601727a ("llvm: pack aggregates when LLVM aligns a field more
  strictly than Zig") and bca1cc3eef (padding fixes) do not touch this path.

## Fix sketch

Core fix, about 40–80 lines across `loongarch/abi.zig` and `FuncGen.zig`:
- Have `.member` record whether each member is GPR or FPR, and allow
  `.member_pair` only when at least one is FPR. Otherwise fall through to the
  existing size-based `.memory_gar`/`.memory_gar_pair`, which already produce
  clang's `i64`/`[2 x i64]`.
- Record each flattened member's real byte offset (via `structFieldOffset`,
  including inside nested structs and arrays) and use it at both FuncGen sites
  and in the return lowering.
- Fix line 7192, and size the alloca to the aggregate's `abiSize`.

Full parity with clang's `clang/lib/CodeGen/Targets/LoongArch.cpp` adds
flattening, register-count tracking, and variadic handling: perhaps 150–250
lines in total. Modeling it on Zig's RISC-V classifier is the shortest path.

## Verification

- Remove the loongarch64 `SkipZigTest` lines in `test/c_abi/main.zig` (110 of
  them) and run the c_abi tests for `loongarch64-linux-gnu` and
  `loongarch64-linux-musl` under QEMU.
- The `p.zig`/`p.c` IR comparison above shows identical signatures and no
  `undef`/`0` second fields.

## Notes

- **Workaround today:** wrap each extern function that takes such a struct
  and pass the struct as a `u64`. This covers only "two or more integers in
  at most 8 bytes". Structs like `{u32,u64}` (`[2 x i64]`) and float+int
  structs are still miscompiled.
