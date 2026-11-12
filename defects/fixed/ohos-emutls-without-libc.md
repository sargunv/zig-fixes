---
title: OpenHarmony programs that do not link libc fail with an undefined `__emutls_get_address`
priority: 1
area: target-defs
targets: [aarch64-linux-ohos, x86_64-linux-ohos, arm-linux-ohoseabi]
upstream: [codeberg#31427]
affects-line: yes
---

## Symptom

```
$ zig build-exe empty.zig -target aarch64-linux-ohos
error: ld.lld: undefined symbol: __emutls_get_address
    note: referenced by debug.zig:578 (lib/std/debug.zig:578)
    note:               .../empty_zcu.o:(debug.defaultPanic)
```

`empty.zig` is `pub fn main() void {}`. Every executable built with the LLVM
backend fails this way, because the default panic handler uses a
threadlocal. That includes `zig test` and x86_64 with `-fllvm` or in a
release mode. x86_64 Debug builds with the self-hosted backend link, because
that backend does not emit emulated TLS.

## Evidence

- Reproduced on 0.17.1 (macOS host) with the release binary, for
  `aarch64-linux-ohos`, `x86_64-linux-ohos -fllvm` and `zig test`. On
  `arm-linux-ohoseabi` it is among the undefined symbols, next to those of
  ohos-arm-aeabi-builtins.
- `zig build-obj` and `zig build-lib` (static and dynamic) without libc
  work on 0.17.1. Their output uses emulated TLS (`__emutls_v.*` symbols,
  an undefined `__emutls_get_address`), as the OpenHarmony SDK Clang's does.

## Root cause

- `src/target.zig:125-136` (`useEmulatedTls`) turns on emulated TLS for
  every OpenHarmony target, matching LLVM, whose
  `Triple::hasDefaultEmulatedTLS` is true for `isOHOSFamily()`. The SDK's
  Clang 15 emits `__emutls_v.x` and a call to `__emutls_get_address` for a
  `_Thread_local` by default, and takes `__emutls_get_address` from
  `libclang_rt.builtins.a` (`emutls.c.o`, built on pthread keys).
- `lib/compiler_rt/emutls.zig:20-22` exports `__emutls_get_address` only
  when linking libc, since it is built on `pthread_key_create`.
- So a build without libc emits emulated TLS accesses and nothing defines
  the helper. An object or library leaves it undefined, to be resolved when
  it is linked with libc; an executable cannot.

The platform does support native TLS. OpenHarmony's libc is musl: the
SDK's `libc.so` exports `__tls_get_addr`, and its `libc.a` has musl's
`static_init_tls` and `__copy_tls`. A C program built by the SDK Clang with
`-fno-emulated-tls` (`PT_TLS`, TLSLE relocations) ran correctly in the main
thread and in a pthread against OpenHarmony's real loader. A program
without libc never involves that libc: Zig's `_start` sets up the thread
pointer and the `PT_TLS` block itself (`lib/std/os/linux/tls.zig`), with
plain Linux syscalls.

## Fix sketch

The two candidates considered:

- **A. Make `requiresLibC` true for OpenHarmony**, as for Android before
  API 29. Rejected. `requiresLibC` does much more than give an error:
  `std.os.targetRequiresLibC` (`lib/std/os.zig:15`) then turns libc on for
  `build-obj` and `build-lib` too (`src/Compilation/Config.zig:239`), which
  changes what std code in those objects calls; `requiresPic`
  (`src/target.zig:77`) forces PIC for every output; and
  `src/Compilation/Config.zig:257-263` makes `-static` with libc an error
  (`LibCRequiresDynamicLinking`), which would break the static aarch64
  executables that ohos-libc-support made work. Every executable without a
  libc file would also fail, including x86_64 Debug ones that link today.
- **B. Use native TLS when no libc is linked.** Taken, but only for
  executables. An object or library built without `-lc` is the usual way to
  produce code that the OpenHarmony toolchain later links into an app, so
  it must keep the emulated TLS that the SDK's C code uses. An executable
  without libc is the whole program, sets up native TLS itself, and has
  nothing that could provide `__emutls_get_address`.

Upstream `master` still turns on emulated TLS for every OpenHarmony target
and has no fix to take.

## Verification

`zig build-exe empty.zig -target aarch64-linux-ohos` (and `x86_64-linux-ohos
-fllvm`) links, and the binary runs on Linux. `build-obj` and `build-lib`
without libc still produce `__emutls_v.*` symbols.

`mise run zig-build -- test-cases -Dtest-filter=ohos_threadlocal_without_libc`
with the built compiler as the build runner (see Fix).

## Fix

- `src/target.zig`: `useEmulatedTls` takes the output mode and whether libc
  is linked. For OpenHarmony it is false only for an executable that does
  not link libc.
- `src/codegen/llvm.zig`: passes them from the compilation's config.
- `test/cases/ohos_threadlocal_without_libc.zig`: a run case for
  `aarch64-linux-ohos` and `x86_64-linux-ohos` with the LLVM backend. It
  reads and writes a threadlocal in the main thread and in a spawned thread.

Verified with a compiler built from this change on a macOS aarch64 host,
against the 0.17.1 release (given this checkout's `lib/` where outputs are
compared):

- **The defect:** `build-exe` of `empty.zig`, a hello world with a
  threadlocal, and the test case's program now link for both targets in
  Debug and ReleaseSafe (LLVM backend), with no `__emutls` symbols and a
  `PT_TLS` segment. So does `zig test --test-no-exec`. All failed before.
  On `arm-linux-ohoseabi` `__emutls_get_address` is gone from the undefined
  symbols; the rest is ohos-arm-aeabi-builtins.
- **They run:** the aarch64 binaries exited 0 with the expected output in a
  scratch Docker image (static, no loader) on the Colima aarch64 Linux VM.
  The x86_64 ones did under `qemu-x86_64` 7.0 in that VM. x86_64 Debug
  binaries from the self-hosted backend crash under that qemu for every
  target, plain `x86_64-linux-musl` included, so x86_64 was run with
  `-fllvm` or in ReleaseSafe.
- **The test case:** with the 0.17.1 release as the build runner,
  `mise run zig-build -- test-cases -Dtest-filter=ohos_threadlocal_without_libc`
  fails with the undefined `__emutls_get_address` on both targets. With the
  built compiler (`zig-out/bin/zig build` with the flags the task passes) it
  compiles and links both; the run steps are skipped as foreign on macOS.
- **Objects and libraries without libc are unchanged:** `build-obj` and
  `build-lib` (static) of a library with an exported function using a
  threadlocal, for aarch64, x86_64 and arm OpenHarmony in Debug and
  ReleaseSafe. Before and after, the same `__emutls_v.*`/`__emutls_t.*`
  symbols and an undefined `__emutls_get_address`, and no TLS relocations.
  After `llvm-strip --strip-all` the objects are byte-identical, except
  that x86_64 Debug differs in `.debug_line` size, as plain
  `x86_64-linux-musl` does between the same two compilers. Archive members
  are identical; only their temporary path names differ. `build-lib
  -dynamic` still has its undefined `__emutls_get_address`.
- **Programs that link libc are unaffected:** with the libc files of
  ohos-libc-support, the Zig hello world, a C hello world (`zig cc`) and a
  threaded program (two threads, 100,000 `std.c.pthread_mutex_t` locks
  each, plus a threadlocal) link for both targets, dynamic in Debug and
  ReleaseSafe, and `-static` on aarch64. The Zig ones still use emulated
  TLS. All the aarch64 ones exited 0 with the expected output against
  OpenHarmony's real `ld-musl-aarch64.so.1` (from the HarmonyOS 6.0.2
  emulator image, as in ohos-libc-support), and so did the static ones.
- **Other targets are unaffected:** `build-exe`, `build-obj` and
  `build-lib` for `aarch64-linux-android.28` (exe: the same "unable to
  provide libc" error), `aarch64-linux-android.29`,
  `x86_64-linux-android.29`, `aarch64-linux-musl` and `x86_64-linux-musl`,
  and musl with `-lc`, in Debug and ReleaseSafe: stripped outputs are
  byte-identical, apart from the x86_64 Debug `.debug_line`/`.strtab` and
  archive member path differences above, which this change cannot cause.
  Android 28 still has its `__emutls_v.*` symbols; the others have none.

## Notes

- Split out of ohos-libc-support, which covers builds that link libc.
- An executable without libc that links objects using emulated TLS (a Zig
  static library built separately without `-lc`, or C compiled for an
  OpenHarmony triple) still fails with the same undefined symbol. That is
  ohos-emutls-objects-without-libc.
