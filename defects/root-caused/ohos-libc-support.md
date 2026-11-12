---
title: OpenHarmony targets cannot build any program, because std.c has no pthread_mutex_t layout for the ohos ABI and Zig ships no OpenHarmony libc
priority: 1
area: lib/std
targets: [aarch64-linux-ohos, x86_64-linux-ohos, arm-linux-ohoseabi]
upstream: [codeberg#31427]
affects-line: yes
---

## Symptom

This entry covers three defects that block OpenHarmony in sequence: 1a, 1b,
and 1c.

**1a.** With libc from an OpenHarmony SDK libc file, the compiler_rt build
fails:

```
$ zig build-exe a.zig -target aarch64-linux-ohos -lc --libc libc.txt
error: sub-compilation of compiler_rt failed
    lib/std/c.zig:8185:21: note: unsupported ABI
                else => @compileError("unsupported ABI"),
    referenced by:
        c.pthread_mutex_t__struct_26: lib/std/c.zig:8174:16
        init_mutex: lib/compiler_rt/emutls.zig:151:5
```

`zig cc -target aarch64-linux-ohos` reportedly fails the same way while
building compiler-rt (not reproduced here).

**1b.** Without a libc file:

```
$ zig build-exe a.zig -target aarch64-linux-ohos -lc
error: unable to provide libc for target "aarch64-linux.5.10...7.2-ohos"
info: zig can provide libc for related target aarch64-linux.3.7.0-gnu.2.17
info: zig can provide libc for related target aarch64-linux.3.7.0-musl
```

**1c.** Without libc:

```
$ zig build-exe a.zig -target aarch64-linux-ohos
error: ld.lld: undefined symbol: __emutls_get_address
    note: referenced by debug.zig:578 (lib/std/debug.zig:578)
    note:               .../a_zcu.o:(debug.defaultPanic)
```

`a.zig` is `const std = @import("std"); pub fn main() void { std.debug.print("hi\n", .{}); }`.
The `libc.txt` used for 1a is a stub with every key present. Its `include_dir`,
`sys_include_dir`, `crt_dir`, and `cc_dir` point at empty directories, and the
rest are empty.

## Evidence

- All three reproduced on Zig 0.17.1 (macOS host), with probe programs and a
  patched copy of the lib directory. Neither was kept.
- Upstream issue: https://codeberg.org/ziglang/zig/issues/31427.
- Upstream PR #31637 vendored the OpenHarmony libc. andrewrk closed it
  unmerged on 2026-04-07: he refused vendoring by non-core contributors, and
  xtex objected to musl-fallback hacks.

## Root cause

All verified by reading code at 0.17.1, and 1a/1c by reproduction.

OpenHarmony is otherwise a recognized ABI:
- `Target.Abi` has `.ohos` and `.ohoseabi` (`lib/std/Target.zig:839-840`).
- `isMusl()` counts them as musl (`lib/std/Target.zig:1016`).
- The dynamic linker is `/lib/ld-musl-<arch>.so.1` (`lib/std/Target.zig:2619-2625`).
- On master, `ohoseabi` is renamed `ohossf` (eac8d0f78b).

**1a, `pthread_mutex_t` layout (std).**
- `src/target.zig:130` turns on emulated TLS for every OpenHarmony target.
  That matches LLVM's default for OpenHarmony, so it is right for
  interoperating with OpenHarmony-clang C code (inferred).
- `lib/compiler_rt/emutls.zig:20-22` exports `__emutls_get_address` when
  linking libc on Android, OpenHarmony, or OpenBSD.
- That code uses `std.c.pthread_mutex_t` (`emutls.zig:151`, `:228`).
- `lib/std/c.zig:8176-8186` sizes `pthread_mutex_t` from an explicit ABI list
  (`.musl, .musleabi, .musleabihf`) instead of `isMusl()`. OpenHarmony falls
  through to `@compileError`.
  - The same list also misses other musl ABIs such as `muslx32`, `muslsf`,
    and `muslf32`.
- After adding `.ohos, .ohoseabi` to that list in a copy of the lib directory
  (`--zig-lib-dir`), the program compiled cleanly. The only remaining errors
  came from the empty stub libc (missing `crt1.o`, `-lc`). No other `std.c`
  switch over the ABI lacks OpenHarmony; the rest use `isMusl()` or
  `isAndroid()`.
- **Possible second defect (inferred):** `pthread_rwlock_t`
  (`lib/std/c.zig:8288-8302`) falls back to a fixed 56-byte layout. That is
  right for 64-bit musl, but upstream musl's 32-bit size is 32 bytes. This
  would matter only for 32-bit `arm-linux-ohoseabi`. codeberg#31427 proposes
  Android sizes there; check them against the OpenHarmony SDK's
  `bits/alltypes.h` first.

**1b, no bundled libc (bundled-libc and target definitions).**
`lib/std/zig/target.zig:14ff` (`available_libcs`) has no OpenHarmony entry, so
a libc file pointing at the SDK sysroot is required. That libc file has its
own pitfalls (verified):
- `cc_dir` must be non-empty for any Linux target, and every key must be
  present (`lib/std/zig/LibCInstallation.zig:85-125`). See
  `android-libc-file-cc-dir.md`.
- For non-Android Linux, Zig looks in `cc_dir` for GCC-style
  `crtbegin.o`/`crtend.o` or `crtbeginS.o`/`crtendS.o`
  (`LibCInstallation.zig:765-797`, `:1033-1044`).
- The OpenHarmony SDK has only `clang_rt.crtbegin.o`/`clang_rt.crtend.o` in
  its clang resource directory (inferred; no SDK on this machine).

**1c, emutls without libc (target definitions).** `src/target.zig:130`
forces emulated TLS, but `emutls.zig:20` provides `__emutls_get_address`
only with libc. `requiresLibC` (`lib/std/Target.zig:2320-2325`) forces libc
for old Android but not for OpenHarmony.

origin/master: unchanged for all three. The `std.c` audit (9da2875656,
"second round of `std.c` ABI auditing") reworked this area and still has no
OpenHarmony arm (verified).

## Fix sketch

- **1a:** about 1 line. Change the `pthread_mutex_t` arm in
  `lib/std/c.zig:8177` to `native_abi.isMusl()`, or add `.ohos, .ohoseabi`.
  Audit `pthread_rwlock_t` and `pthread_cond_t` for 32-bit OpenHarmony
  against the SDK headers.
- **1b:** two options.
  - Keep requiring a libc file, and add an OpenHarmony case beside the Android
    one at `LibCInstallation.zig:749` that uses the clang_rt crt basenames and
    accepts `crt_dir` when `cc_dir` is empty. About 10–20 lines.
  - Or vendor OpenHarmony's musl variant, which is a new libc port and large.
    Upstream refused a contributed vendoring (PR #31637).
- **1c:** about 1 line. Add `target.abi.isOpenHarmony()` to `requiresLibC` in
  `lib/std/Target.zig:2324`.
- 1a and 1c are `lib/` changes, so a fork can ship them as a patched
  `--zig-lib-dir` without rebuilding the compiler.

## Verification

- With the OpenHarmony SDK (`OHOS_SDK_NATIVE`): write a libc file with
  `include_dir`/`sys_include_dir` set to `$OHOS_SDK_NATIVE/sysroot/usr/include/aarch64-linux-ohos`
  and `.../usr/include`, and `crt_dir` set to
  `$OHOS_SDK_NATIVE/sysroot/usr/lib/aarch64-linux-ohos`.
  - `zig build-exe a.zig -target aarch64-linux-ohos -lc --libc libc.txt` links.
  - The program runs on the Oniro x64 emulator for `x86_64-linux-ohos`.
- `zig cc -target aarch64-linux-ohos --libc libc.txt hello.c` links.
- `zig build-exe a.zig -target aarch64-linux-ohos` either links or reports
  that libc is required.
- The end-to-end link against a real SDK sysroot is unverified: no
  OpenHarmony SDK was on the investigating machine.

## Notes

- **Workaround today:** build C code for OpenHarmony with the OpenHarmony
  SDK's clang instead of `zig cc`.
