---
title: Apple device targets link against Zig's bundled macOS libSystem.tbd instead of the platform SDK, so every libc symbol is undefined
priority: 1
area: compiler
targets: [aarch64-ios, aarch64-tvos, aarch64-visionos]
upstream: [codeberg#37298]
affects-line: yes
---

## Symptom

A cross build for an Apple device target with no `--libc` file links about 100
libc symbols as undefined. Even hello world fails:

```
$ zig build-exe hello.zig -target aarch64-ios
error: undefined symbol: __NSGetExecutablePath
error: undefined symbol: ___error
error: undefined symbol: _malloc
error: undefined symbol: _pthread_create
... (99 errors in total)
```

tvOS fails the same way (88 errors), and so does visionOS (102 errors). The
`-ios-simulator`, `-tvos-simulator`, and `-visionos-simulator` targets link,
but only by accident (see Root cause).

The link line Zig runs has no `-syslibroot`. It takes the SDK version, 27.0,
from Zig's own bundled `SDKSettings.json`:

```
zig ld -dynamic -platform_version ios 18.0.0 27.0 -e _main -o hello .../hello_zcu.o -lSystem .../libcompiler_rt.a
```

Passing `--sysroot $(xcrun --sdk iphoneos --show-sdk-path)` does not help: it
still gives 102 undefined symbols (verified).

## Evidence

- Reproduced on Zig 0.17.1 on macOS with Xcode 26.4.1 (iPhoneOS26.4.sdk). The
  probe files were not kept.
- **A plausible diagnosis is wrong.** The failure has been blamed on "the
  SDK's `libSystem` stub is tagged `arm64e-ios`, which Zig does not accept for
  `arm64-ios`". Zig accepts `arm64e-<platform>` for every aarch64 target
  (`src/link/MachO/Dylib.zig:716`, from 13b1050d4c, which has been in every
  release since 0.16.0).
- **codeberg#37298 is a different bug**, in the new MachO2 linker's `.tbd`
  handling. That linker runs only with `-fnew-linker` or incremental builds
  (`src/Compilation/Config.zig:444-458`), so it does not affect default
  builds. With `-fnew-linker --libc` on iOS, Zig 0.17.1 panics with
  `TODO(MachO2): load archive`.
  - Upstream PR #37522 ("Eliminate old Mach-O linker implementation") would
    make #37298 matter for default builds later.
- `src/Compilation.zig:2451-2461` loads the bundled stub for every
  `isDarwinLibC()` target and ignores `--sysroot`.
- The build system's `--libc` leak (`build-libc-flag-leaks-to-host.md`) breaks
  the obvious route of passing the SDK as a libc file through
  `zig build --libc`.
- The SDK side (verified):
  - In the Xcode 26.4 iPhoneOS SDK, 35 of the 37 documents in
    `usr/lib/libSystem.tbd` list only `[ arm64e-ios ]`.
  - The SDK has no `usr/lib/system/` directory: the re-exported libraries are
    inline documents in that one file.
  - The macOS SDK has the same shape, which is why 13b1050d4c exists.

## Root cause

Verified by reading code at 0.17.1 and by reproduction:

1. **Zig never looks for the platform SDK.** In `lib/std/zig/LibCDirs.zig:66-95`:
   - Naming an OS in `-target` makes `is_native_abi` false
     (`lib/std/Target/Query.zig:403`).
   - Zig cannot build an iOS libc: `canBuildLibC` in
     `lib/std/zig/target.zig:125` matches only macOS entries in
     `available_libcs`.
   - So `detect` returns no libc installation and no sysroot. It never calls
     `LibCInstallation.findNative`, which already finds the iOS, tvOS, and
     visionOS SDKs through `std.zig.system.darwin.getSdk`
     (`lib/std/zig/system/darwin.zig:38`).
2. **It silently falls back to the bundled macOS stub.** With no libc
   installation, `src/Compilation.zig:2451-2461` queues
   `lib/libc/darwin/libSystem.tbd` and `lib/libc/darwin/SDKSettings.json` for
   every `target.isDarwinLibC()` target. That stub lists only macOS and Mac
   Catalyst targets, so a device target matches no document and every libc
   symbol stays undefined.
   - The fallback came with c1ce1a2da7 ("compiler: move darwin libSystem
     resolution to the frontend"), first released in 0.17.0.
   - In 0.15.1 the old path ended with an explicit "unable to find libSystem
     system library" error instead.
3. **The simulators link by accident.** `src/link/MachO/Dylib.zig:733-736`
   also accepts `<arch>-macos` entries for simulator platforms, so they link
   against the bundled macOS stub. Their output records SDK 27.0 from Zig's
   file, not the real SDK.

This is the old self-hosted Mach-O linker (`src/link/MachO.zig`). LLD is never
used for Mach-O (`src/target.zig:281-286`).

origin/master: `LibCDirs.detect`, the `Compilation.zig` fallback, and the
`Dylib.zig` matcher have only refactors (verified).

## Fix sketch

Two candidate fixes, which can be combined:

1. **Find the SDK.** In `LibCDirs.detect`, when the
   host is Darwin and the target is a Darwin OS that `canBuildLibC` rejects,
   call `LibCInstallation.findNative` even for a non-native ABI. Then, in
   `Compilation.zig:2451`, use the bundled stub only for macOS and Mac
   Catalyst. For other Darwin targets with no libc installation, fail with
   "pass --libc or install the SDK" instead of linking against the wrong stub.
   About 10–20 lines.
2. **Honor `--sysroot`.** In
   `Compilation.zig:2451-2461`, take `libSystem.tbd` (and `SDKSettings.json`)
   from `<sysroot>/usr/lib` when a sysroot is given and the bundled stub does
   not cover the target. This also helps non-Darwin hosts that have a copied
   SDK. A few dozen lines.

Either way, the simulator path should stop relying on the macOS fallback.

## Verification

- `zig build-exe hello.zig -target aarch64-ios` either links with
  `-syslibroot <iPhoneOS SDK>` and `-platform_version ios <min> 26.4`, or fails
  with a clear "no SDK" error. It should never report undefined `_malloc`.
- Repeat for `aarch64-tvos`, `aarch64-visionos`, and each `-simulator` variant.
  The simulator output's SDK version must match the real SDK.
- `zig build-exe hello.zig -target aarch64-ios --sysroot $(xcrun --sdk iphoneos --show-sdk-path)`
  should link if fix 2 is taken.
- Run `otool -l hello | grep -A4 LC_BUILD_VERSION` and check platform 2 (iOS)
  with the real SDK version.

## Notes

- **Workaround today (verified for hello world only):** pass the SDK as a libc
  file:
  ```
  zig libc -target aarch64-ios > libc.txt
  zig build-exe hello.zig -target aarch64-ios --libc libc.txt
  ```
  This links, with `-platform_version ios 18.0.0 26.4 -syslibroot .../iPhoneOS26.4.sdk`.
  The same works for tvOS and visionOS.
  - It has not been tried on a larger build that links frameworks and
    `libc++.tbd`.
  - In `zig build`, the file has to go to each target compile step
    (`Compile.setLibCFile`), not through `zig build --libc`, because of
    `build-libc-flag-leaks-to-host.md`.
- **Related:**
  - Zig 0.17.0 also failed earlier on these targets: the
    `std.Io.Threaded.NullFile` `fd` error, fixed in 0.17.1 by 6171a2be74 and
    f842de1845, and the `MinimalDisplayName` SDK version parse, fixed in
    0.17.1 by d760b840ec. Neither is in this backlog because both are fixed.
  - Probably the same gap: translate-c has been seen to turn integer handle
    typedefs into opaque structs on the device SDK only. Device builds got no
    SDK headers then either (inferred, not reproduced).
