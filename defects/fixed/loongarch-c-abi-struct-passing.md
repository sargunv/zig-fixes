---
title: LoongArch C calling convention splits all-integer small structs across registers and uses wrong field offsets, corrupting extern calls
priority: 1
area: codegen
targets: [loongarch64-linux-gnu, loongarch64-linux-musl, loongarch32-linux-gnu]
upstream: [codeberg#35798]
affects-line: yes
---

## Symptom

Calling a C function that takes or returns a small struct by value from Zig,
or exporting one to C, passes the wrong registers.

- A struct of two `u32`s is passed in two GPRs instead of being packed into
  one. Every later argument shifts by one register.
- Mixed and float structs keep the right signature, but their second field
  is read from the wrong offset and becomes garbage.

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

The same comparison, extended, shows more mismatches with 0.17.1 (Zig's
lowering first, clang's second):

| Case | Zig 0.17.1 | clang |
|---|---|---|
| return `{u32,u32}` | `{ i32, i32 }` | `i64` |
| return `{u32,u64}` | `{ i32, i64 }` | `[2 x i64]` |
| `struct { float a[2]; }` | `i64` | `float, float` |
| `{f32, ?*u8}` | `float, ptr` | `[2 x i64]` |
| `{u8,f32}` after 8 `double`s (FARs used up) | `i8, float` | `i64` |
| `{f32,f64}` after 7 `double`s | `float, double` | `[2 x i64]` |
| `{u8,f32}` after 8 `u64`s (GARs used up) | `i8, float` | `i64` |
| `u128`, or a 16-byte-aligned struct, after 9 `u64`s | `[2 x i64]` | `i128` |
| variadic `{f32,f64}`, `{[2]f32}` | `float, double`, `i64` | `[2 x i64]`, `i64` |
| variadic 16-byte-aligned struct after one `int` | `i64, i64` | `i128` |

The last three rows differ in placement too: an `i128` gets a 16-byte-aligned
stack slot and, when variadic, an even-odd GAR pair. `[2 x i64]` gets neither.

Arguments larger than 2×GRLEN were passed as a pointer to the caller's own
value, marked `readonly`. The C callee owns that memory and may write to it, so
`c_modify_by_ref_param` in `test/c_abi` crashed writing into a read-only
constant.

## Evidence

- Reproduced on Zig 0.17.1, both with the release binary and with a compiler
  built from this line, using the probe in Verification.
- First seen on Zig 0.17.0. The crash was observed under `qemu-loongarch64`
  10.2.3 and confirmed with a standalone Zig-calls-C probe
  (`width=0 height=0 completion=0x8`).
- Upstream already knows: `test/c_abi/main.zig` skipped 110 tests with
  `if (builtin.cpu.arch == .loongarch64) return error.SkipZigTest;`, 26 more
  with `if (builtin.cpu.arch.isLoongArch()) return error.SkipZigTest;`, 3 with
  `... and builtin.abi.float() == .hard`, and 9 exported-function blocks with
  `break :skip`. `test/c_abi/cfuncs.c` left out the matching C side under
  `#ifndef __loongarch__` (bool vectors and six struct tests in
  `run_c_tests`) and complex numbers on soft float.
- The C ABI support was added by 703baa4cd6 ("llvm: implement c abi for
  loongarch", first released in 0.17.0), which closed codeberg#35798.

## Root cause

Read at 0.17.1. Clang's reference is `classifyArgumentType` and
`detectFARsEligibleStructHelper` in `clang/lib/CodeGen/Targets/LoongArch.cpp`.

1. **Wrong classification** (`src/codegen/loongarch/abi.zig:16-29`).
   `Class.combineMember` turns any two scalar members into `.member_pair`
   (line 26) without checking that at least one is a float. Like RISC-V, the
   LoongArch psABI passes a struct in FARs only when it flattens to one float,
   two floats, or a float and an integer. An all-integer struct of at most
   2×GRLEN is coerced to `i64`, `[2 x i64]` or `i128`. It also treats
   pointers as integer members (line 93); clang's `isIntegralOrEnumerationType`
   does not, so a struct holding a pointer is never FAR-eligible.
2. **No flattening.** `combineMember` returns `.address` for a nested
   `.member_pair`. So `struct { float a[2]; }` and `{ {f32}, f64 }` fall back to
   integer coercion instead of being flattened. The array case at lines 94-103
   has the same problem.
3. **Wrong offsets** (`src/codegen/llvm/FuncGen.zig:7186-7197`). The
   `.member_pair` lowering computes the second member's size from
   `member_tys[0]` (line 7192). It builds offsets as
   `{0, first_size, first_size + second_size}`, which ignores alignment and
   padding. These offsets set the alloca size and the load/store positions at
   the call site (`FuncGen.zig:869-880`) and in the callee prologue
   (`FuncGen.zig:265-276`). `.member` likewise sizes the alloca by the member,
   not the struct.
4. **Return path** (`FuncGen.zig:7609-7616`). `.member`/`.member_pair` become
   a `.mem_cast` to the LLVM type `{T0, T1}`, which reinterprets the return
   value's memory with LLVM's natural layout. That puts the second member at
   the wrong offset for over-aligned or packed members (for example
   `extern struct { a: f32 align(8), b: f32 align(8) }`). For `.member` the
   call site allocas only the member's size and then reads the whole struct
   from it. A layout-preserving `mem_cast` type cannot fix this: padding fields
   would take return registers.
5. **No register accounting.** Nothing tracks the remaining argument
   registers, as clang's `GARsLeft`/`FARsLeft` do, and nothing tells fixed
   arguments from variadic ones. A float+int struct is still split once the
   FARs or GARs run out, where clang coerces it to integers. Variadic structs
   are split, where clang never passes a variadic argument in FARs.
6. **2×GRLEN-aligned arguments** (`FuncGen.zig:7216-7224`). `.memory_gar_pair`
   always becomes `[2 x i64]`. Clang passes a 16-byte-aligned aggregate as
   `i128`, and `__int128`/`long double` directly, so the backend gives them an
   aligned stack slot and, when variadic, an aligned register pair.
7. **Indirect arguments** (`FuncGen.zig:7226-7230`). `.address` becomes
   `.byref`, which passes the caller's value itself. The callee may modify an
   indirect argument, so it needs a copy. That is `.byref_mut`, which the RISC-V
   and AArch64 lowerings use.
8. **FRLEN from CPU features** (`abi.zig:52-57`). Clang takes FRLEN from the
   float ABI (`lp64s`/`lp64f`/`lp64d`). Zig took it from the `f`/`d` CPU
   features, which the soft-float ABIs (`muslsf`, `gnusf`) still have. Before,
   this only mattered by accident. Once structs flatten correctly, floats in
   structs go to FARs that soft-float C code does not use. Upstream fixed this
   on master in 4cb76bab3f ("compiler: base loongarch float abi on target.abi
   rather than cpu features").

origin/master: not fixed (verified). Apart from 4cb76bab3f and the
`packed`→`bitpack` rename, `loongarch/abi.zig` is unchanged. The
`second_size` typo and the c_abi skips remain.

## Fix sketch

Superseded by `## Fix`.

## Verification

- Remove the LoongArch skips in `test/c_abi/main.zig` and the matching C-side
  exclusions in `test/c_abi/cfuncs.c`. Then run the c_abi suite for
  `loongarch64-linux-musl` and `loongarch64-linux-musl` soft float under QEMU.
- Compare Zig's IR with clang's for the probe structs. Every struct
  signature and call should match.

## Fix

`src/codegen/loongarch/abi.zig` now classifies a struct the way clang's
`detectFARsEligibleStructHelper` does. It flattens nested extern structs and
arrays (including sentinels) to their scalar members, with each member's byte
offset. A struct qualifies for FARs only when it flattens to one float, two
floats, or a float and an integer. Each integer must be at most GRLEN, each
float at most FRLEN, and pointers, unions and vectors disqualify it. Anything
else is classified by size (`classifyMemory`). FRLEN now comes from the float
ABI. That hunk is upstream's 4cb76bab3f, taken verbatim so the next merge is
trivial. 4cb76bab3f's `src/link/Elf2.zig` half is unrelated to this defect and
was not taken.

`src/codegen/llvm/FuncGen.zig`:

- `ParamTypeIterator.classifyLoongArch` counts GARs and FARs as clang's
  `classifyArgumentType` does, starting from 8 of each, less one GAR for
  `sret`. A FAR-eligible struct or float is passed in FARs only if it is a
  fixed argument and enough registers are left. Otherwise it is passed like
  any other value of its size. Variadic 2×GRLEN-aligned arguments use an
  even-odd GAR pair.
- `.member`/`.member_pair` arguments load and store each member at its own
  offset, in an alloca sized to the whole struct.
- A 2×GRLEN-aligned `.memory_gar_pair` argument is passed as one integer:
  directly for ints and floats, as `i128` for aggregates.
- `.address` arguments use `.byref_mut`.
- Struct returns use a new `FnReturnStrat.fields`. The LLVM return type is the
  member type or `{T0, T1}` (packed when the second member is misaligned, as in
  clang). Each member is moved to or from its own offset in the Zig value
  (`loadReturnFields`/`storeReturnFields`). No other calling convention
  produces `.fields`.

Tests: the loongarch skips listed in Evidence are removed. One stays: `f16
bare`, which tests a scalar `f16` and is skipped on most architectures for an
unrelated reason. On the C side, `ZIG_NO_RAW_F16` and `ZIG_NO_F128` stay;
`main.zig` gates those tests by an allow-list that does not include LoongArch.

Verified on an Apple silicon Mac with a ReleaseSafe compiler built from this
branch (`mise run build`):

- c_abi suite: the real `test-c-abi` step was built with
  `zig-out/bin/zig build test-c-abi -Dtest-target-filter=<triple>` (with the
  `mise run zig-build` flags and a private cache), in all four optimize modes.
  The step does not run foreign executables on this host, so each
  `test-c-abi-*` executable it produced was run in an `ubuntu:24.04` arm64
  container under `qemu-loongarch64` 8.2.2 (`qemu-user` package).
  - Before (compiler built from the base commit, same un-skipped tests,
    Debug): `loongarch64-linux-musl` fails `struct u8, u8`,
    `struct u16, u16`, `struct u32, u32`, `struct [2]f32` and
    `struct [1:sentinel]f32`, then aborts at `struct i32 i32` (`zig_panic
    called from C` in `c_mut_struct_i32_i32`). `loongarch64-linux-muslsf`
    panics in the first C-calls-Zig check in `run_c_tests`.
  - After: `loongarch64-linux-musl` and `loongarch64-linux-muslsf`: 189
    passed, 14 skipped, 0 failed, in Debug, ReleaseSafe, ReleaseFast and
    ReleaseSmall. All 14 remaining skips are generic: `f16 bare`, the f80 and
    f128 tests (gated by `have_f80`/`have_f128`), and tests for x86-only
    calling conventions.
- IR comparison: Zig's IR was compared with `zig cc` for 47 cases, covering
  the table in Symptom plus f16 and bool members, a packed misaligned
  `{u8, f32 align(1)}`, single over-aligned floats, unions and zero-size
  members, nested arrays of structs, `double`+int returns, and `long double`
  on the stack and variadic. All struct signatures and calls match for
  `loongarch64-linux-gnu`, `-musl`, `-muslsf` and `-gnuf32`. Two
  differences remain, neither a struct and neither a register mismatch:
  - A variadic `c_int` gets no `signext`; see
    `variadic-int-args-missing-extension-attrs`, which affects RISC-V too.
  - A scalar `long double` return is `[2 x i64]` where clang uses `fp128`.
    Both come back in a0/a1.
- Other targets: the c_abi suite for `x86_64-linux-musl` (LLVM and
  self-hosted, three CPU levels), `aarch64-linux-musl` and
  `riscv64-linux-musl` was built and run in all four modes (aarch64
  natively, x86_64 and riscv64 under QEMU): no failures.
  `x86_64-linux-muslx32` was built but not run, because QEMU user mode
  cannot run x32 executables.

## Notes

- Not verified: `loongarch32` (no C ABI tests or QEMU target in this setup),
  and the `gnu` targets at run time (only their IR was compared; the run-time
  suite is musl only).
- Workaround before this fix was to wrap such functions and pass the struct
  as a `u64`, which covered only integer structs of at most 8 bytes.
- Related: `variadic-int-args-missing-extension-attrs`.
