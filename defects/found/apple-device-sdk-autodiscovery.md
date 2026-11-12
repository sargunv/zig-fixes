---
title: The compiler does not find the installed SDK for Apple device targets on a Mac
priority: 3
area: compiler
targets: [aarch64-ios, aarch64-tvos, aarch64-visionos, aarch64-watchos]
upstream: []
affects-line: yes
---

## Symptom

This is a missing convenience, not a regression. No Zig release has found
an Apple device SDK by itself.

On a Mac with Xcode, `zig build-exe hello.zig -target aarch64-ios` does not
use the installed iPhoneOS SDK. The SDK has to be passed with `--sysroot`
(see `apple-device-sdk-libsystem`) or with a `--libc` file. A native macOS
build, by contrast, finds the macOS SDK through `xcrun` with no flags.

The same holds for tvOS, visionOS and watchOS, and for their simulators. The
simulators link against Zig's bundled macOS stub, so their output records
SDK 27.0 from Zig's own `SDKSettings.json` instead of the real SDK's version.

## Evidence

- 0.15.2 and 0.16.0 fail with "unable to find libSystem system library" for
  `-target aarch64-ios` with no flags. 0.17.1 fails with about 100 undefined
  symbols. Verified on macOS (Apple silicon) with Xcode 26.4.1.
- `LibCInstallation.findNative` (`lib/std/zig/LibCInstallation.zig:186-199`)
  already resolves these SDKs through `std.zig.system.darwin.getSdk`, and
  `zig libc -target aarch64-ios` prints a usable libc file. But the compiler
  calls `findNative` only for the native ABI
  (`lib/std/zig/LibCDirs.zig:40` and `:75-88`), and naming an OS in
  `-target` makes the ABI non-native.

## Root cause

Not a defect in existing code. Automatic discovery was never implemented for
non-native Darwin targets. Upstream generally keeps cross builds from
consulting the host system.

## Fix sketch

On a Darwin host, for an iOS, tvOS, visionOS or watchOS target with neither
`--libc` nor `--sysroot`, call `LibCInstallation.findNative` and use the SDK
it finds. Fall back to the current behavior when there is none. About 12
lines in `src/Compilation.zig`, on top of `apple-device-sdk-libsystem`.

## Verification

On a Mac with Xcode, `zig build-exe hello.zig -target aarch64-ios` links,
with `LC_BUILD_VERSION` platform 2 and the installed SDK's version.

## Notes

- This is outside the fork's stated Scope (defect fixes only). Whether to
  carry it is the owner's decision.
