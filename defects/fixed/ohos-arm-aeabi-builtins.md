---
title: arm-linux-ohoseabi programs that link libc fail with undefined `__aeabi_*` helpers
priority: 1
area: lib/std
targets: [arm-linux-ohoseabi, thumb-linux-ohoseabi]
upstream: [codeberg#31427]
affects-line: yes
---

## Symptom

With a libc file pointing at the OpenHarmony SDK's `arm-linux-ohos` sysroot
(as in ohos-libc-support, with `arm-linux-ohos` in place of
`aarch64-linux-ohos`), every Zig program that links libc fails:

```
$ zig build-exe hello.zig -target arm-linux-ohoseabi -lc --libc libc-arm.txt
error: ld.lld: undefined symbol: __aeabi_dadd
    note: referenced by arm.zig:302 (compiler_rt/arm.zig:302)
    note:               compiler_rt_zcu.o:(compiler_rt.arm.__aeabi_drsub) in archive libcompiler_rt.a
    ...
    note: referenced 348 more times
```

39 distinct `__aeabi_*` symbols are missing: integer division
(`__aeabi_idiv`, `__aeabi_uidiv`), and single and double precision
arithmetic, comparison and conversion (`__aeabi_dadd`, `__aeabi_fcmplt`,
`__aeabi_d2lz`, `__aeabi_l2d`, ...). `zig cc` fails the same way for C
code that uses those operations, and for any `-static` program, because the
SDK's `libc.a` calls them:

```
$ ZIG_LIBC=libc-arm.txt zig cc -target arm-linux-ohoseabi -static hello.c
ld.lld: error: undefined symbol: __aeabi_uidiv
>>> referenced by malloc_common.c
>>>               malloc_common.o:(calloc) in archive <sdk>/native/sysroot/usr/lib/arm-linux-ohos/libc.a
```

A dynamic C hello world links, since it pulls nothing from compiler_rt.

## Evidence

- Reproduced on this line (0.17.1 plus ohos-libc-support, with a compiler
  built from it) against OpenHarmony SDK 7.0 on a macOS aarch64 host. The
  libc file sets `sys_include_dir` and `crt_dir` to the `arm-linux-ohos`
  directories and `cc_dir` to
  `native/llvm/lib/clang/15.0.4/lib/arm-linux-ohos`.

## Root cause

`want_aeabi` (`lib/compiler_rt.zig:216-227`) lists the ARM EABI ABIs for
which compiler_rt exports the `__aeabi_*` run-time helpers. It has
`.androideabi` and the musl and gnu EABI ABIs but not `.ohoseabi`, so
compiler_rt exports only the generic names (`__udivsi3`, `__adddf3`, ...).
LLVM uses the `__aeabi_*` names for the `ohos` environment, both in code
compiled for it and in compiler_rt itself, and so does OpenHarmony's libc.

## Fix sketch

As done; see Fix.

## Verification

- `mise run zig-build -- test-cases -Dtest-filter=arm_ohoseabi`: links an
  `arm-linux-ohoseabi` executable that needs no libc or SDK and uses 64-bit
  division and double arithmetic and conversion. It fails with 38
  undefined `__aeabi_*` symbols without the fix.
- The commands in Symptom link, and the programs run and print correct
  results on 32-bit ARM. See Fix for how they were run.

## Fix

- `lib/compiler_rt.zig`: `want_aeabi` includes `.ohoseabi`.
- `test/cases/arm_ohoseabi_aeabi_helpers.zig`: the test case above. It
  defines its own `_start` and uses `std.debug.no_panic`, because a
  no-libc OpenHarmony executable that uses std's threadlocals still fails
  to link (ohos-emutls-without-libc). Run through the harness, it fails
  with 38 undefined `__aeabi_*` symbols without the `want_aeabi` change
  and passes with it.

No other switch needed the ABI. In `lib/compiler_rt/`, `lib/std/Target.zig`
and `src/target.zig`, every list that names `.androideabi` or the musl/gnu
EABI ABIs either already has `.ohoseabi` (`Abi.float`, which makes it soft
float like `.androideabi`; `isMusl`; the libc link flags) or is not
reached for it: `gnu_f16_abi` is true for all ARM ABIs but `.eabi` and
`.eabihf`, as it is for `.androideabi`, and the EHABI personality routines
and `__aeabi_read_tp` in `lib/compiler_rt/arm.zig` key on the architecture
and OS. `src/Air.zig:2645` and `src/Air/Legalize.zig:3344` repeat the
`want_aeabi` list without `.ohoseabi`, but they name compiler_rt calls only
for backends that ask `Legalize` for soft-float lowering. No backend does
that for ARM (the LLVM backend does not, and the C backend never emits
`legalize_compiler_rt_call`), so they are not reached here.

Verified with a compiler built from ohos-libc-support (`0.17.1+fixes.25bb243aa`),
before and after this change, on a macOS aarch64 host against SDK 7.0. The
test programs: C and Zig hello worlds, and a C and a Zig program that,
through `volatile` operands, do 32- and 64-bit signed and unsigned
division and remainder, single and double precision add, subtract,
multiply, divide and compare, conversions between them and 32- and 64-bit
integers, and (in Zig) `f16` extension.

- **Before:** `zig build-exe hello.zig` and the Zig helpers program fail
  with 39 undefined `__aeabi_*` symbols, the C helpers program likewise,
  and `zig cc -static hello.c` fails on `__aeabi_uidiv` from `libc.a`.
  `thumb-linux-ohoseabi` fails the same way (38 symbols).
- **After:** all of them link, dynamic and `-static`, Zig in Debug and
  ReleaseSafe. `llvm-nm` shows the helpers (`__aeabi_dadd`,
  `__aeabi_uldivmod`, `__aeabi_l2d`, ...) defined in the executables and
  none undefined.
- **Running, dynamic:** there is no 32-bit ARM OpenHarmony system image
  here, so upstream musl's soft-float ARM loader (Debian 13's `musl`
  1.2.5 armel package, `libc.so` installed as `/lib/ld-musl-arm.so.1`)
  stood in for OpenHarmony's, with `qemu-arm -L` (qemu 8.2.2) in a Linux
  container. The C and Zig hello worlds and both helper programs (Zig in
  Debug and ReleaseSafe, and with `-mcpu cortex_a7`) exit 0, and their
  output is identical to the same programs built for and run on the host.
  The SDK Clang's own builds of the C programs give the same output.
- **Running, `-static`:** these stop with SIGILL before `main`, and so do
  the SDK Clang's own static builds of the same C programs. The trap is
  `__stack_chk_fail_local`, called from `__init_libc` in the SDK's
  `libc.a`: the SDK's static startup, not Zig's code.
- `thumb-linux-ohoseabi` executables now link but crash at startup,
  because they get no dynamic linker (ohos-thumb-no-dynamic-linker).

## Notes

- Split out of ohos-libc-support, which covers aarch64 and x86_64.
- Other 32-bit ARM OpenHarmony gaps: std-c-pthread-rwlock-32bit-size,
  ohos-thumb-no-dynamic-linker and cb36723-arm-softfloat-neon-left-enabled.
- The SDK's static ARM `libc.a` cannot start an executable under qemu-arm
  (see Fix). That is the SDK's, so it has no entry here.
