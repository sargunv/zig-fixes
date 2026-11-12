---
title: Variadic integer and bool arguments get no signext/zeroext attribute in LLVM calls
priority: 1
area: codegen
targets: [riscv64-linux-gnu, riscv64-linux-musl, loongarch64-linux-gnu, loongarch64-linux-musl, aarch64-linux-gnu, aarch64-linux-musl]
upstream: []
affects-line: yes
---

## Symptom

When Zig calls a C variadic function, the variadic arguments get no `signext`
or `zeroext` attribute, though clang adds one.

- On targets whose C ABI requires a 32-bit int argument to be extended to the
  full register (riscv64, loongarch64, mips64, powerpc64, s390x), a `c_int`
  or `c_uint` passed through `...` keeps whatever upper bits its register
  held.
- On every target, a `bool` passed through `...` arrives as `i1`/`i8` with
  undefined upper bits. C promotes `bool` to `int`, so a C callee reads it with
  `va_arg(ap, int)`.

A Zig caller that computes the values by truncating wider ones (which costs
no instruction, so the register keeps its upper bits):

```zig
extern fn show(n: c_int, ...) void;
var wide_i: u64 = 0x1234_5678_ffff_ffff;
var wide_u: u64 = 0x1234_5678_8000_0000;
var wide_b: u64 = 0x1234_5678_0000_0003;
pub fn main() void {
    const i: c_int = @bitCast(@as(u32, @truncate(@as(*volatile u64, &wide_i).*)));
    const u: c_uint = @truncate(@as(*volatile u64, &wide_u).*);
    const b: bool = @bitCast(@as(u1, @truncate(@as(*volatile u64, &wide_b).*)));
    show(3, i, u, b);
}
```

and a C callee compiled with `-O2` that reads `i` and `u` with
`va_arg(ap, long)` and `b` with `va_arg(ap, int)`. Built with
`zig build-exe main.zig show.c -cflags -O2 -- -lc -target <t> -O ReleaseFast`
on Zig 0.17.1 and run under QEMU:

```
riscv64:     i=1311768469162688511 (expect -1)  u=1311768467015204864 (expect -2147483648)  b=1 (expect 1)
loongarch64: i=1311768469162688511 (expect -1)  u=1311768467015204864 (expect -2147483648)  b=3 (expect 1)
aarch64:     i=1311768469162688511 (expect -1)  u=1311768467015204864 (expect -2147483648)  b=3 (expect 1)
x86_64:      i=1311768469162688511 (expect -1)  u=1311768467015204864 (expect -2147483648)  b=1 (expect 1)
```

The `bool` result is wrong under portable C: `va_arg(ap, int)` on a promoted
`bool` must give 0 or 1. Reading the 32-bit ints as `long` relies on the
riscv64 and loongarch64 psABIs, which make the sign extension part of the
calling convention. Callees that read an `int` argument as `long` exist,
musl's `syscall(long, ...)` among them. On aarch64 and x86_64 the `i`/`u`
values are not a defect, because those ABIs do not extend 32-bit ints.

## Evidence

- Reproduced with Zig 0.17.1 (the release binary) for riscv64, loongarch64,
  aarch64 and x86_64 Linux musl, using the program above, under
  `qemu-riscv64`/`qemu-loongarch64`/`qemu-x86_64` 8.2.2 and natively on
  aarch64.
- The c_abi test added with the fix fails with the 0.17.1 compiler on
  riscv64-linux-musl and loongarch64-linux-musl/-muslsf (all optimize modes)
  and on aarch64-linux-musl (ReleaseSafe, ReleaseFast, ReleaseSmall).
- Found while comparing LoongArch C ABI lowering against clang for
  `loongarch-c-abi-struct-passing`.

Call-site attributes on the variadic arguments of
`vari(1, c_int, c_uint, i8, i16, u8, u16, bool)`, Zig 0.17.1 against
`zig cc` for the C equivalent. The narrow integers are promoted by both: Zig's
Sema turns them into `c_int`/`c_uint`, C into `int`.

| Target | clang: ints | clang: bool | Zig 0.17.1 | Zig with the fix |
|---|---|---|---|---|
| riscv64-linux-musl | `i32 signext` (all) | `i32 signext` | `i32` (no attribute), bool `i8` | ints match; bool `i8 zeroext` |
| loongarch64-linux-musl | `i32 signext` (all) | `i32 signext` | `i32`, bool `i1` | ints match; bool `i1 zeroext` |
| mips64-linux-muslabi64 | `i32 signext` (all) | `i32 signext` | `i32`, bool `i1` | ints match; bool `i1 zeroext` |
| powerpc64le-linux-musl | `signext`; `zeroext` for `unsigned` | `i32 signext` | `i32`, bool `i1` | ints match except promoted `u8`/`u16`: `zeroext` (Zig promotes to `c_uint`), same bits; bool `i1 zeroext` |
| s390x-linux-musl | as powerpc64 | `i32 signext` | `i32`, bool `i1` | as powerpc64 |
| x86_64-linux-musl | `i32` | `i32` | `i32`, bool `i8` | ints unchanged; bool `i8 zeroext` |
| aarch64-linux-musl | `i32` | `i32` | `i32`, bool `i1` | ints unchanged; bool `i1 zeroext` |
| aarch64-macos | `i32` | `i32` | `i32`, bool `i1` | ints unchanged; bool `i1 zeroext` |
| arm-linux-musleabihf | `i32` | `i32` | `i32`, bool `i1` | ints unchanged; bool `i1 zeroext` |
| wasm32-wasi | `i32` | `i32` | `i32`, bool `i1` | ints unchanged; bool `i1 zeroext` |

Enums cannot be passed to a variadic function in Zig at all:
`coerceVarArgParam` (`src/Sema.zig:29891`) treats them as integers and fails
to coerce them to `c_int` (`expected type 'c_int', found 'E'`). So no enum
case reaches codegen.

## Root cause

`src/codegen/llvm/FuncGen.zig:915-918` (in `buildCall`) adds the call's
argument attributes by walking the parameters again with `it.next()`, which
stops at the end of `fn_info.param_types`. Variadic arguments are visited only
by the first walk (`it.nextCall(arg_types)`, line 816), which builds the
argument values but adds no attributes. So `addByValParamAttrs`
(`src/codegen/llvm.zig:3969`, the `ccAbiPromoteInt` branch) never runs for
them.

`ccAbiPromoteInt` (`FuncGen.zig:7834`) already gives the right extension for a
promoted `c_int`/`c_uint` on each target. A `bool` needs more than its rule for
fixed parameters, which leaves `bool` unextended on aarch64 outside Apple
platforms. C has no `bool` variadic argument: it promotes it to `int`, so the
callee reads 32 bits, and those bits must be 0 or 1 on every target.

## Fix sketch

Superseded by `## Fix`.

## Verification

- The IR comparison above shows the extension attributes.
- The c_abi test `variadic promoted integers and bool` passes on riscv64,
  loongarch64, x86_64 and aarch64.

## Fix

`buildCall` (`src/codegen/llvm/FuncGen.zig`) continues the attribute walk past
the fixed parameters with `it.nextCall(arg_types)`. Each variadic argument
lowered as `.byval` or `.abi_sized_int` gets:

- `zeroext` if it is a `bool`;
- otherwise, if it is an integer, the extension `ccAbiPromoteInt` gives a
  fixed parameter of that type;
- nothing otherwise.

Floats, pointers and aggregates are unchanged.

New c_abi test `variadic promoted integers and bool` (`test/c_abi/main.zig`,
`c_varargs_promoted_ints` in `test/c_abi/cfuncs.c`). It passes a `c_int` of
-1, a `c_uint` of `0x80000000` and `true`, each truncated from a wider value.
The C side checks the full register (`va_arg(ap, long)`) on the targets whose
ABI extends 32-bit ints, and `va_arg(ap, int)`/`unsigned` elsewhere. It
always reads the `bool` as `int`.

Verified on an Apple silicon Mac:

- c_abi suite, built from this checkout with `zig build test-c-abi
  -Dtest-target-filter=<triple>` (the `mise run zig-build` flags, a
  private cache, all four optimize modes). Each test executable was run in an
  `ubuntu:24.04` arm64 container: natively for aarch64, under
  `qemu-riscv64`, `qemu-loongarch64` and `qemu-x86_64` 8.2.2 otherwise.
  - Before (the 0.17.1 release compiler, same test sources): the new test
    panics on riscv64-linux-musl and loongarch64-linux-musl/-muslsf in all
    modes, and on aarch64-linux-musl in ReleaseSafe, ReleaseFast and
    ReleaseSmall. It passes on x86_64.
  - After: no failures on riscv64-linux-musl, loongarch64-linux-musl,
    loongarch64-linux-muslsf, aarch64-linux-musl and x86_64-linux-musl (LLVM
    and the self-hosted backend, three CPU levels). x86_64-linux-muslx32 was
    built but not run, because QEMU user mode cannot run x32 executables.
- The IR comparison in Evidence, for the ten targets listed there.
- Targets whose ABI needs no extension: the LLVM IR of the whole c_abi test
  (`zig test test/c_abi/main.zig -lc -O ReleaseFast`, with std) was
  compared between the 0.17.1 compiler and this one for x86_64-linux-musl,
  aarch64-linux-musl, arm-linux-musleabihf and wasm32-wasi. Apart from the
  embedded version string, the only change is `zeroext` on the new test's
  `bool` argument.

## Notes

- The self-hosted x86_64 backend passes the new test (it was run with the
  c_abi suite); the C backend leaves promotion to the C compiler. Other
  self-hosted backends were not checked.
- Related: `loongarch-c-abi-struct-passing`.
