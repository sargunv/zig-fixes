---
title: zig build --libc applies the target libc file to the build script and to host-targeted compile steps too
priority: 1
area: build-system
targets: [all]
upstream: []
affects-line: yes
---

## Symptom

`zig build --libc <file>` (or `ZIG_LIBC`-style use through the build runner)
is meant for cross-compiling to the target. But Zig also passes it:
- when it compiles `build.zig` itself, which is always a host executable, and
- to every compile step that does not set its own libc file, including steps
  that build host tools (code generators, translate-c's own executables, and
  so on).

So a libc file for, say, the Android NDK or the iOS SDK breaks or
misconfigures the host side of the build. The only safe pattern is to avoid
`--libc` and pass the file per target step with `Compile.setLibCFile`.

## Evidence

- Verified by reading code at 0.17.1. Not reproduced end to end here.
- Seen in practice on Zig 0.17: a global `--libc` reached the build
  configurer and host tools. Passing the libc file to each target compile,
  translate-c step, and docs object instead avoided it.
- This leak blocks passing the SDK libc file through `zig build --libc` for
  iOS. That route is the workaround for `apple-device-sdk-libsystem.md`.

## Root cause

Verified by reading code at 0.17.1.
- `lib/compiler/Maker.zig:438-439` stores `--libc` in `graph.libc_file`.
- `lib/compiler/Maker.zig:1187-1189` appends `--libc <file>` to the command
  that compiles the build configurer (`build.zig`), which always targets the
  host.
- `lib/compiler/Maker/Step/Compile.zig:657-663`: a compile step without its
  own `libc_file` falls back to `graph.libc_file`, whatever its target.
- Nothing checks whether the step's target matches the target the libc file
  describes.

origin/master: unchanged. `Maker.zig:1243-1245` and
`Maker/Step/Compile.zig:670-672` keep the same logic (verified).

## Fix sketch

Two options:

1. **Scope it to non-host steps (a few dozen lines).** Never pass
   `graph.libc_file` to the build configurer. In `Compile.zig`, apply it only
   when the step's resolved target is not the host (or not native).
2. **Match by target.** Parse the libc file's implied target, or let users
   give `--libc` per target (`--libc <triple>=<file>`), and apply it only to
   steps whose target matches. More work, but unambiguous.

Either way, document that `--libc` is for target compiles.

## Verification

- With an Android NDK libc file, `zig build --libc android.txt -Dtarget=aarch64-linux-android.29`
  on a project whose `build.zig` also builds and runs a host code generator
  succeeds, and `--verbose` shows no `--libc` on the build-configurer and
  host-tool command lines.
- Same with an iOS SDK libc file from `zig libc -target aarch64-ios`.

## Notes

- **Workaround today:** do not pass `--libc` to `zig build`. Take the libc
  file through a build option (for example `-Dtarget-libc=<file>`) and call
  `Compile.setLibCFile` on each target compile and translate-c step. Keeping
  this after a fix is harmless.
- Using an SDK libc file for Apple device targets through `zig build --libc`
  depends on this fix, or on `apple-device-sdk-libsystem.md`.
