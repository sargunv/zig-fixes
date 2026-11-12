---
title: OpenHarmony programs that link libc against the SDK sysroot fail to build, or crash when statically linked
priority: 1
area: lib/std
targets: [aarch64-linux-ohos, x86_64-linux-ohos]
upstream: [codeberg#31427]
affects-line: yes
---

## Symptom

Zig ships no OpenHarmony libc, so linking libc for `*-linux-ohos` needs a
libc file that points at the OpenHarmony SDK's sysroot, for example for
aarch64 (`<sdk>` is the SDK root, e.g. `mise where ohos-sdk@7.0`):

```
include_dir=<sdk>/native/sysroot/usr/include
sys_include_dir=<sdk>/native/sysroot/usr/include/aarch64-linux-ohos
crt_dir=<sdk>/native/sysroot/usr/lib/aarch64-linux-ohos
cc_dir=<sdk>/native/llvm/lib/clang/15.0.4/lib/aarch64-linux-ohos
msvc_lib_dir=
kernel32_lib_dir=
darwin_sdk_dir=
```

With that file, five defects stop a hello world, one after another.
`hello.zig` prints with `std.debug.print`; `hello.c` calls `puts`.

**1. compiler_rt does not compile.** Both `zig build-exe hello.zig -target
aarch64-linux-ohos -lc --libc libc.txt` and `ZIG_LIBC=libc.txt zig cc
-target aarch64-linux-ohos hello.c` fail:

```
error: sub-compilation of compiler_rt failed
    lib/std/c.zig:8185:21: note: unsupported ABI
                else => @compileError("unsupported ABI"),
    referenced by:
        c.pthread_mutex_t__struct_26: lib/std/c.zig:8174:16
        init_mutex: lib/compiler_rt/emutls.zig:151:5
```

**2. The wrong crtbegin/crtend are looked up.**

```
error: ld.lld: cannot open <sdk>/native/llvm/lib/clang/15.0.4/lib/aarch64-linux-ohos/crtbegin.o: No such file or directory
error: ld.lld: cannot open <sdk>/native/llvm/lib/clang/15.0.4/lib/aarch64-linux-ohos/crtend.o: No such file or directory
```

**3. Dynamically linked Zig programs reference `statx`,** which the SDK's
`libc.so` does not export:

```
$ zig build-exe hello.zig -target aarch64-linux-ohos -lc --libc libc.txt -dynamic
error: ld.lld: undefined symbol: statx
    note: referenced by Threaded.zig:4063 (lib/std/Io/Threaded.zig:4063)
```

**4. Statically linked Zig programs crash.** Static was the default link
mode, because OpenHarmony counts as musl. Even `pub fn main() void {}`
overflows its stack at startup, and a program with a C `main` overflows it
at `exit`:

```
#.. compiler_rt.emutls.__emutls_get_address (control=<__emutls_v.heap.SmpAllocator.thread_index>)
#.. heap.SmpAllocator.Thread.lock () at lib/std/heap/SmpAllocator.zig:75
#.. c.malloc.posix_memalign (...) at lib/c/malloc.zig:187
#.. compiler_rt.emutls.simple_allocator.advancedAlloc (...) at compiler_rt/emutls.zig:50
#.. compiler_rt.emutls.__emutls_get_address (control=<__emutls_v.Thread.maybeAttachSignalStack.global.signal_stack>)
#.. Thread.maybeAttachSignalStack () at lib/std/Thread.zig:1757
#.. start.main (...) at lib/std/start.zig:754
```

**5. On x86_64, the default (static) executable cannot start at all,**
whether written in C or Zig, and whichever compiler built it. The SDK
Clang's own `clang --target=x86_64-linux-ohos -static hello.c` fails the
same way:

```
--- SIGSEGV {si_signo=SIGSEGV, si_code=1, si_addr=0x0000000000000028} ---
```

## Evidence

- 1 to 4 reproduced on this line (0.17.1, macOS host) against OpenHarmony
  SDK 7.0 (`mise where ohos-sdk@7.0`). 1 and 2 were reproduced with the
  release binary, 3 and 4 with a compiler built from this checkout. SDK 6.1
  has the same layout and the same `libc.so` exports.
- 4 was found by running static aarch64 binaries under Docker on aarch64
  Linux, with gdb for the backtrace above. The SDK Clang's own static
  binaries run there.
- 5 was found by running the SDK Clang's static x86_64 binary under
  `qemu-x86_64 -strace` and disassembling `__init_libc`.
- Upstream issue: https://codeberg.org/ziglang/zig/issues/31427. Upstream PR
  #31637 vendored an OpenHarmony libc and was closed unmerged. Vendoring is
  out of scope here.

## Root cause

Zig already recognizes OpenHarmony. `Target.Abi` has `.ohos` and
`.ohoseabi`, and `isMusl()` includes them (`lib/std/Target.zig:1016`). The
dynamic linker is `/lib/ld-musl-<arch>.so.1`, the same one the SDK Clang
uses. `src/target.zig:130` turns on emulated TLS for OpenHarmony, as LLVM
does, so compiler_rt's emutls (`lib/compiler_rt/emutls.zig:20-22`) is built
whenever libc is linked.

1. `std.c.pthread_mutex_t` (`lib/std/c.zig:8176-8186`) sizes the type from
   an explicit ABI list without `.ohos`/`.ohoseabi`, so emutls hits
   `@compileError`. The SDK Clang gives the same sizes as musl: 40 bytes,
   align 8, on aarch64 and x86_64, and 24 bytes, align 4, on arm.
2. `LibCInstallation.CrtBasenames.get`
   (`lib/std/zig/LibCInstallation.zig:749-797`) uses the GCC names
   `crtbegin.o`/`crtbeginS.o` for every non-Android Linux target, and looks
   them up in `cc_dir` (`:1033-1044`). OpenHarmony uses compiler-rt's
   `clang_rt.crtbegin.o`/`clang_rt.crtend.o` from Clang's resource directory
   in every link mode, as `clang --target=aarch64-linux-ohos -###` shows.
   This code is compiled into the compiler.
3. `statx_use_c` (`lib/std/Io/Threaded.zig:2089`) calls libc's `statx` when
   `std.c.versionCheck` passes, and `versionCheck` (`lib/std/c.zig:57-60`)
   passes for every musl ABI. OpenHarmony's `libc.so` (the NDK's public API)
   exports no `statx`, and its headers do not declare it. std calls four
   other functions through `versionCheck`: `copy_file_range`, `getrandom`,
   `memfd_create` and `fchmodat`. The SDK's `libc.so` exports all of them.
4. `wantsZigC` (`src/target.zig:480-482`) links libzigc into every static
   musl-ABI program. libzigc completes Zig's bundled musl. OpenHarmony never
   uses that musl, but libzigc was linked anyway. Its weak `malloc` and
   `posix_memalign` (`lib/c/malloc.zig:25-38`) sit in the same object as the
   Zig code, so they were used instead of the SDK `libc.a`'s. That `malloc`
   reads a threadlocal (`lib/std/heap/SmpAllocator.zig:48`). Under emulated
   TLS that read calls `__emutls_get_address`, which allocates with
   `posix_memalign` (`lib/compiler_rt/emutls.zig:50`), and so on without
   end.
5. The SDK's x86_64 `libc.a` reads the stack-protector canary from
   `%fs:40` in `__init_libc` before `static_init_tls` sets up FS. FS is
   zero at `exec`, so every static x86_64 executable faults at address
   0x28 before `main`. That is the SDK's code, not Zig's. But Zig chose
   static for OpenHarmony by default (`src/Compilation/Config.zig:267-286`)
   only because OpenHarmony counts as musl, while the SDK Clang links
   dynamically by default. So a plain `zig build-exe -target
   x86_64-linux-ohos -lc` produced a binary that cannot run.

## Fix sketch

As done; see Fix.

## Verification

With the libc file above, for `aarch64-linux-ohos` and `x86_64-linux-ohos`:

- `zig build-exe hello.zig -target <t> -lc --libc libc.txt` links,
  dynamically by default and statically with `-static`. `zig build-lib
  -dynamic` links too.
- `ZIG_LIBC=libc.txt zig cc -target <t> hello.c` links dynamic, PIE,
  `-static` and `-shared`.
- The dynamic binaries run against OpenHarmony's loader (see Fix for how),
  and so do static ones on aarch64. Static x86_64 binaries cannot start
  (Root cause 5).
- `zig test lib/std/std.zig --zig-lib-dir lib --test-filter CrtBasenames`.

## Fix

- `lib/std/c.zig`: `pthread_mutex_t` uses musl's layout for `.ohos` and
  `.ohoseabi`.
- `lib/std/zig/LibCInstallation.zig`: for OpenHarmony, `CrtBasenames.get`
  returns `clang_rt.crtbegin.o`/`clang_rt.crtend.o`, plus musl's
  `crt1.o`/`Scrt1.o`/`rcrt1.o`, `crti.o` and `crtn.o`. A test checks the
  dynamic PIE case.
- `lib/std/Io/Threaded.zig`: on OpenHarmony, `statx` uses the raw syscall,
  as it does on Linux targets whose libc lacks `statx`.
- `src/target.zig`: `wantsZigC` is false for OpenHarmony.
- `src/Compilation/Config.zig`: executables and shared libraries that link
  libc are dynamic by default on OpenHarmony, as with the SDK Clang and as
  Zig already does for the BSDs. `-static` still works where the SDK's
  static libc does (aarch64).

Verified with a compiler built from this change, against SDK 7.0, on a
macOS aarch64 host. The libc files are the one in Symptom, and the same
with `x86_64-linux-ohos` in place of `aarch64-linux-ohos`. The test
programs:

- C and Zig hello worlds.
- A Zig program that takes a `std.c.pthread_mutex_t` 100,000 times in each of
  two threads, checks the count, writes a file, and then stats it through
  both `statx` paths (`File.stat` and `Dir.statFile`), exiting 0 only if
  all agree.
- A C++ program built with `zig c++` (Zig's bundled libc++): four threads
  sharing a `std::mutex`, and a thrown and caught exception.

What was run:

- **Links and layout:** every program links on both targets: dynamic,
  PIE, `-static`, `build-lib -dynamic` and `zig cc -shared`, in Debug and
  ReleaseSafe. Executables are now dynamic by default. Their program
  headers match the SDK Clang's: `/lib/ld-musl-<arch>.so.1` and
  `NEEDED libc.so`. Three weak undefined symbols are not exported by the
  SDK's `libc.so`: `__register_frame_info`, `__deregister_frame_info` and
  `__at_fini`. They come from the SDK's `clang_rt.crtbegin.o`, and the SDK
  Clang's output has them too.
- **aarch64, with OpenHarmony's real libc:** the SDK's `libc.so` is an NDK
  link stub with no code, so the loader came from the HarmonyOS 6.0.2
  (API 22) aarch64 emulator image that DevEco Studio installs. It was read
  with `debugfs dump /system/lib/ld-musl-aarch64.so.1`, opened read-only.
  Run in a scratch image (`docker import`) holding only that loader, at
  `/lib/ld-musl-aarch64.so.1`, and the binaries. Each of these exited 0
  with the expected output:
  - C, C PIE and C++.
  - Zig hello in Debug and ReleaseSafe, and Zig PIE.
  - The mutex/`statx` program in Debug and ReleaseSafe.
  - `-static` C and the `-static` mutex/`statx` program in Debug and
    ReleaseSafe.
- **x86_64, dynamic:** there is no x86_64 OpenHarmony system image here, so
  upstream musl's loader (Alpine 3.22.8's `/lib/ld-musl-x86_64.so.1`) stood
  in for OpenHarmony's. Run with `qemu-x86_64 -L <dir holding it>`
  (qemu 7.0) in the Colima VM. C, C PIE, C++, Zig hello (Debug,
  ReleaseSafe, PIE) and the mutex/`statx` program (Debug, ReleaseSafe)
  all exited 0 with the expected output.
  - Docker's own amd64 emulation is not usable for the `statx` check. Even
    0.17.1-release `x86_64-linux-musl` and `x86_64-linux-gnu` programs get
    `EBADF` from `statx(fd, "", AT_EMPTY_PATH)` there.
- **x86_64, `-static`:** these exit with SIGSEGV, as the SDK Clang's own
  static binaries do (Root cause 5). This is now opt-in.
- x86_64 Debug builds of Zig code use the self-hosted linker. It still fails
  on the SDK's BSD-format `libm.a` (elf-linker-bsd-archive-long-names).
  With `-fllvm` or in a release mode, they link; the x86_64 binaries above
  used one of those.
- **Other targets:** the same Zig and C programs were built for
  `x86_64-linux-musl` and `aarch64-linux-musl` (bundled musl), and for
  `aarch64-linux-android.29` (NDK libc file). Builds from this compiler and
  from the 0.17.1 release are byte-identical after `llvm-strip --strip-all`.
- The `CrtBasenames` std test passes, and fails without the fix.

Split out and not covered here:

- 32-bit ARM: ohos-arm-aeabi-builtins and std-c-pthread-rwlock-32bit-size.
- Builds without libc: ohos-emutls-without-libc.
- The self-hosted ELF linker: elf-linker-bsd-archive-long-names.

## Notes

- A libc file is still required. Zig provides no OpenHarmony libc, and
  vendoring one is out of scope. `cc_dir` must point at the SDK Clang's
  resource directory for the target, which holds the `clang_rt.crt*.o`
  objects.
- The SDK's x86_64 `libc.a` cannot start a static executable (Root cause
  5). That is a defect in the SDK, not in Zig, so it has no entry here. On
  x86_64, `-static` produces a binary that crashes before `main`.
- The SDK's `libc.so` is a link stub. Running a dynamic binary needs a
  device, an emulator, or a loader taken from a system image.
