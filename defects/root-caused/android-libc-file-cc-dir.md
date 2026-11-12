---
title: An Android libc paths file must set a non-empty cc_dir, because Zig looks for the NDK's crtbegin objects there instead of in crt_dir
priority: 1
area: lib/std
targets: [aarch64-linux-android, x86_64-linux-android, x86-linux-android, arm-linux-androideabi]
upstream: []
affects-line: yes
---

## Symptom

A libc paths file (`--libc`, `Compile.setLibCFile`) for an Android target
fails to parse unless `cc_dir` is set:

```
error: cc_dir may not be empty for linux
```

Every key must be present, even keys that don't apply to the target:
`msvc_lib_dir=`, `kernel32_lib_dir=`, and `darwin_sdk_dir=`. A missing key
fails with `missing field: <name>`. The NDK has no separate "cc" directory.
Its `crtbegin_dynamic.o`, `crtbegin_so.o`, and `crtend_*.o` live in the
per-API-level `crt_dir` (`sysroot/usr/lib/<triple>/<api>`), so the file has
to repeat `crt_dir` as `cc_dir`.

## Evidence

- Verified by reading code at 0.17.1 (below).
- The `cc_dir` workaround is still needed on 0.17.1.
- Every key is required, and `darwin_sdk_dir` must be non-empty for Darwin
  targets (`lib/std/zig/LibCInstallation.zig:85-125`, verified).
- The `crtbegin` requirement arrived with c269a604b6 ("fix: crtbegin/crtend
  not being linked on linux (#32064)", 2026-07-14, first released in 0.17.0),
  verified with `git tag --contains`.

## Root cause

Verified by reading code at 0.17.1.
- `lib/std/zig/LibCInstallation.zig:85-90` rejects a file that is missing any
  key.
- `LibCInstallation.zig:107-110` rejects an empty `cc_dir` for every
  `os_tag == .linux` target, including Android ABIs.
- When resolving crt objects for `.haiku, .serenity, .linux`
  (`LibCInstallation.zig:1034-1045`), `crtbegin`/`crtend` are joined onto
  `cc_dir` (`lci.cc_dir orelse return error.LibCInstallationMissingCcDir`).
- The Android basenames (`crtbegin_so.o`, `crtbegin_dynamic.o`,
  `crtbegin_static.o`, from `LibCInstallation.zig:749-760`) exist only in the
  NDK's `crt_dir`.
- By contrast, `findNative` for Android (`LibCInstallation.zig:463`) searches
  for `crtbegin_dynamic.o` as the `crt_dir` marker.

origin/master: unchanged. `cc_dir may not be empty` at
`LibCInstallation.zig:107` still covers `.linux` (verified).

## Fix sketch

Small, a few lines in `LibCInstallation.zig`:
- In `parse`, don't require `cc_dir` when `target.abi.isAndroid()`.
- In the crt resolution, use `crt_dir` for Android `crtbegin`/`crtend` (or
  fall back to `crt_dir` whenever `cc_dir` is null).
- Optionally, treat absent keys as empty instead of failing with
  `missing field`. That is friendlier for hand-written files, but it changes a
  file format that `zig libc` prints. Two choices: accept omissions only for
  keys that don't apply to the target, or accept all omissions.
- The same `crt_dir` fallback would serve OpenHarmony, whose clang_rt crt
  objects also don't fit the GCC layout. See `ohos-libc-support.md`.

## Verification

- A libc file for `aarch64-linux-android.29` with only `include_dir`,
  `sys_include_dir`, and `crt_dir` (NDK paths) links a hello-world executable
  and a shared library. `--verbose-link` shows `crtbegin_dynamic.o` and
  `crtbegin_so.o` taken from `crt_dir`.

## Notes

- **Workaround today:** set `cc_dir` to the same directory as `crt_dir`, and
  write empty `msvc_lib_dir=`, `kernel32_lib_dir=`, and `darwin_sdk_dir=`
  lines.
