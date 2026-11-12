---
title: zig cc rejects LLVM/GCC-style target triples with a vendor field, such as --target=x86_64-unknown-linux-gnu
priority: 1
area: zig-cc
targets: [all]
upstream: []
affects-line: yes
---

## Symptom

```
$ zig cc --target=x86_64-unknown-linux-gnu -c x.c -o t.o
error: unable to parse target query 'x86_64-unknown-linux-gnu': UnknownOperatingSystem
```

Build tools that pass clang-style triples, notably cc-rs (used by the `ring`
crate's build script, among many others), fail when `zig cc` is the C
compiler, even though clang accepts these triples.

## Evidence

- Reproduced on Zig 0.17.1.
- cc-rs passes the four-component LLVM triple `x86_64-unknown-linux-gnu`,
  which Zig reads as os="unknown".
- No upstream issue found.

## Root cause

Verified by reading code at 0.17.1.
- In `zig cc` and `zig c++` mode, `src/main.zig:1998` stores clang's
  `--target`/`-target` value directly
  (`.target => target_arch_os_abi = it.only_arg`). (`src/main.zig:1415-1416`
  is the `-target` of `zig build-exe` and friends, which takes Zig triples
  and is not affected.)
- The value then goes to Zig's own triple parser,
  `std.Target.Query.parse` (`lib/std/Target/Query.zig:226-260`). That parser
  expects `arch-os[.ver]-abi[.ver]` with no vendor field, so the vendor
  `unknown` is read as the OS, and `parseOs`
  (`lib/std/Target/Query.zig:567-573`) returns `error.UnknownOperatingSystem`.
- An LLVM triple also carries more than Zig's `arch-os-abi`: an Arm
  sub-architecture (`armv6`, `thumbv7em`) selects a CPU, ISA mode and
  features, an omitted environment means glibc on Linux and MSVC on Windows,
  and clang picks a default CPU per target that is not always Zig's
  baseline. Dropping or ignoring any of these compiles for a different
  target than clang would.
- There is no LLVM-triple normalization step. Other LLVM spellings also fail
  or mismatch, for example `aarch64-apple-darwin`, `armv7-linux-androideabi`
  (arch `armv7`), and `i686-…` (all reproduced with a compiler built from
  the line, see Fix).

origin/master: `Query.zig` was refactored (about 196 lines changed), but no
vendor handling was found (not exhaustively checked).

## Fix sketch

Two options:

1. **Normalize LLVM triples in `zig cc` mode only (a few dozen lines).**
   - When `--target`/`-target` comes through the clang argument iterator and
     has four components, or a known vendor (`unknown`, `pc`, `apple`, `none`,
     `w64`, `linux` as vendor), drop the vendor.
   - Map LLVM OS and environment names to Zig's: `darwin`→`macos`,
     `gnueabihf` etc. pass through, `androideabi`, `windows-msvc`/`windows-gnu`.
   - Map LLVM arch spellings: `i686`→`x86`, `armv7`→`arm` plus CPU features,
     `riscv64gc`→`riscv64`.
   - Then call `Query.parse`. Keep `zig build-exe -target` strict.
   - There is prior art for this mapping in the reverse direction:
     `std.Target.Query.zigTriple` and `src/codegen/llvm.zig`'s
     `targetTriple`.
2. **Teach `Query.parse` an optional vendor slot.** Broader, and it changes a
   public std API used by build scripts. Not recommended.

## Verification

- `zig cc --target=<llvm triple> -c x.c` succeeds for the triples build
  tools pass (cc-rs, CMake toolchain files, the Android NDK's and Apple's
  spellings, bare-metal GCC triples).
- The object is for the target the bundled clang (`zig clang`) picks for the
  same triple: compare `-dM -E` target macros and `llvm-readelf -A` build
  attributes of `zig clang -target <t>` and `zig cc --target=<t>`.
- A triple Zig already accepted resolves to the same target as before.

## Fix

`src/main.zig`, `zig cc` and `zig c++` only. The `--target`/`-target` value
goes through a new `clangTargetToZig`, which returns a Zig triple and the CPU
clang picks for it. That CPU becomes the `-mcpu` unless the command line
gives `-mcpu` or `-march`. A value that already parses as a Zig triple is
returned unchanged with no CPU, so every triple accepted before keeps its
meaning. `zig build-exe -target` and `std.Target.Query.parse` are unchanged.

What it translates:

- Vendor fields (`unknown`, `pc`, `apple`, `w64`, any second of four fields);
  `i386`-`i686`, `amd64`, `arm64`; OS names `darwin` (kernel version mapped
  to the macOS version as LLVM does), `macosx`, `xros`, `mingw32`, `none`,
  `unknown`, `elf`, `wasip1`; versions glued to the OS or environment
  (`macosx11.0`, `android21`); `ios...-macabi` to Mac Catalyst with its
  version; `elf` as an environment (an object format) is dropped.
- An omitted environment is the one clang assumes: glibc on Linux (clang
  uses `/lib64/ld-linux-x86-64.so.2` for `x86_64-unknown-linux`, as for
  `-gnu`; Zig's default would be musl) and MSVC on Windows.
- Arm and Thumb sub-architectures (`armv4`-`armv9.7a`, `armv6k`, `armv6kz`,
  `armv6t2`, `armv7l`, `armv7r`, `armv7m`, `armv7em`, `armv8r`,
  `armv8m.base`, `armv8m.main`, `armv8.1m.main`, the `thumb` and big-endian
  `armeb`/`thumbeb`/`...eb` spellings and LLVM's synonyms) map to the CPU and
  features clang uses, from its `-###` output: the sub-architecture's default
  CPU plus its architecture feature (and, for a hard-float environment, the
  default FPU of an M-profile core),
  clang's per-OS overrides (FreeBSD and NetBSD for v6 and v7, Windows v7 as
  Thumb on Cortex-A9), its environment-based default for plain `arm`
  (`arm7tdmi`, or `arm1176jzf-s` for hard float), M-profile as Thumb and
  A-profile `thumb...` as Arm, and `+strict_align` where clang adds it
  (before v7 except NetBSD v6, v6-M, v8-M Baseline).
- Where clang's default CPU differs from Zig's baseline for the translated
  target: 32-bit x86 on FreeBSD (`i686`), NetBSD (`i486`), OpenBSD (`i586`)
  and Android (`i686+mmx+ssse3`); x86_64 on Android (`+sse4.2+popcnt+cx16`),
  macOS (`penryn`, `core2` before 10.12), the iOS/tvOS simulators and Mac
  Catalyst (`core2`); aarch64 on Android (Cortex-A53 erratum 835769 fix and
  outline atomics), the Apple simulators (`apple_m1`) and visionOS
  (`apple_a12`); bare-metal RISC-V (`rv32imac`/`rv64imac`, soft float);
  wasm32 (`generic`).
- A 32-bit Arm soft-float environment (`gnueabi`, `eabi`, `musleabi`,
  `androideabi`) on a CPU with an FPU, such as the NDK's
  `armv7a-linux-androideabi21` or `thumbv7em-none-eabi`. Clang uses
  `softfp` there: the base AAPCS calling convention, with floats in core
  registers, but FPU (and NEON) instructions inside functions. Zig has no
  `softfp`, so these get Zig's pure soft float on the CPU the triple names,
  exactly what the Zig spelling gives (`armv7a-linux-androideabi21` is
  byte-identical to `-target arm-linux-androideabi.21`). The calling
  convention is the same, so the objects link and call each other: neither
  carries `Tag_ABI_VFP_args`, and the cross-linked programs below return
  correct values. Only the code inside functions differs, and C code sees
  `__SOFTFP__` and no `__ARM_NEON`; see `cb36723-arm-softfloat-neon-left-enabled`
  for the related soft-float feature defect and the missing `softfp` mode.

Still rejected, with the reason:

- Architectures and OSes whose clang defaults were not matched here, so a
  translation would differ from clang: PowerPC (Zig always uses IEEE `long
  double`, clang uses IBM double-double), s390x, SPARC, MIPS o32 (clang
  `fpxx`), m68k, LoongArch32, Android RISC-V (clang enables RVA22 and V), and
  Haiku, DragonFly, Fuchsia and the other OSes outside the list above.
- 32-bit Arm outside Windows without an EABI environment (none, or `gnu`,
  `musl`, `ohos`, `android`): clang uses a non-EABI soft-float ABI
  (`__addsf3`, `__divdi3` instead of `__aeabi_*`), which Zig does not have.
  Arm on OpenBSD: clang ignores `gnueabihf` there and uses `softfp`, while
  the Zig target would be hard float, a different calling convention.
- A `native` component (`native-unknown-linux-gnu`,
  `x86_64-unknown-native-gnu`): not an LLVM component, and rejected with the
  same diagnostic as before.
- Obsolete or unknown Arm sub-architectures (`armv2`, `armv3`, `armv8m`),
  which clang silently treats as plain `arm`, and the Apple-only `armv7s`
  and `armv7k`.
- `riscv64gc-unknown-linux-gnu`: clang rejects it too (`error: unknown
  target triple 'riscv64gc-unknown-linux-gnu'`). It is a Rust target name;
  rustc and cc-rs pass `riscv64-unknown-linux-gnu` to the C compiler.

What still differs from clang for a translated triple is what `zig cc`
does for the equivalent Zig spelling too, and is not about the triple: Zig
always sets an OS version (an unversioned `darwin`, `freebsd` or `netbsd`
gets Zig's default, where clang leaves it unset or takes it from the SDK),
emits unwind tables, disables function multi-versioning, and marks ARM
objects with the float-ABI `e_flags` bit.

Test: `test clangTargetToZig` in `src/main.zig`, run by
`mise run zig-build -- test-unit -Dtest-filter=clangTargetToZig`. It fails
with the translation stubbed out and passes with it.

Verified with a compiler built from the line, against the bundled clang
(22.1.4, `zig clang`). Every triple that is now accepted had been rejected
by the unfixed compiler. For each, `zig cc --target=<t>` and
`zig clang -target <t>` were compared on `-dM -E` target macros, on the
objects' `llvm-readelf -A` attributes and e_flags, and on their undefined
symbols (which shows outline atomics and runtime-call names). This covered
the Arm, Thumb and big-endian sub-architectures from v4 to v9.7-A, with
v6-M, v7-M, v7E-M, v8-M and v8.1-M; Linux glibc, musl, Android and
OpenHarmony on x86, x86_64, aarch64, riscv32/64 and loongarch64; FreeBSD,
NetBSD and OpenBSD; Windows MSVC and MinGW; macOS, iOS, tvOS, visionOS and
their simulators; Mac Catalyst; bare metal (`aarch64-none-elf`,
`arm-none-eabi(hf)`, `riscv{32,64}-unknown-elf`); wasm32; and triples
without an environment. Apart from the Zig-wide differences listed above,
they match. For example, `armv6-unknown-linux-gnueabihf` gives
`CPU_name=arm1136jf-s`, `CPU_arch=ARM v6`, `THUMB_ISA_use=Thumb-1`,
`FP_arch=VFPv2`, unaligned access not permitted; `thumbv7em-none-eabihf`
gives `cortex-m4`, `ARM v7E-M`, no ARM ISA, Thumb-2, `VFPv4-D16`,
single-precision hard float; `x86_64-unknown-linux` uses glibc and
`/lib64/ld-linux-x86-64.so.2`. Objects built for Zig spellings
(`x86_64-linux-gnu`, `x86_64-linux`, `arm-linux-gnueabihf`, `aarch64-macos`,
`wasm32-wasi`, ...) are byte-identical to the unfixed compiler's, except
that COFF debug info embeds the compiler's own path. An explicit `-mcpu` or
`-march` still overrides the CPU that the triple implies.

Link compatibility of the `softfp` triples was run, not inferred, because
no NDK or Android device was available. For `armv7a-linux-androideabi21`
and `thumbv7em-none-eabi`, a caller and a callee passing and returning
`float`, `double`, mixed arguments and a `{float, double}` struct were each
compiled with `zig cc --target=<t>` and with `zig clang -target <t>`. Each
cross pairing (zig caller with clang callee, and the reverse) was linked
into a bare-metal image with the FPU enabled, and run under
`qemu-system-arm` (`-M virt -cpu cortex-a15` and `-M mps2-an386`, a
Cortex-M4) with semihosting. All four pairings reported correct values. As
a negative control, the same zig caller linked against a clang `gnueabihf`
or `eabihf` callee reported wrong values, so the harness detects a calling
convention mismatch.

Every input still rejected (each rejected test row, `native` components and
empty components) gives the release's diagnostic, byte for byte. A
Debug-built translator ran about a million generated triples (every
combination of 45 odd components in 2, 3 and 4 positions) without a panic.

## Notes

- **Workaround today:** call `zig cc` through a wrapper script that drops
  every incoming `--target=`, `--target`, and `-target` and always appends its
  own Zig triple. A side effect: one wrapper can't serve two targets, so each
  target needs its own. A wrapper stays useful after a fix to fold `cc`/`c++`
  into one executable path for CMake and cc-rs, and to pin the glibc floor in
  the triple (`x86_64-linux-gnu.2.17`), because an LLVM triple carries no
  glibc version.
- Related: `zig-cc-unknown-linker-args.md`, worked around in the same kind of
  wrapper.
