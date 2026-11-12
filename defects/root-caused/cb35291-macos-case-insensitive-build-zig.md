---
title: zig build in a subdirectory picks up Build.zig as build.zig on case-insensitive file systems
priority: 1
area: build-system
targets: [aarch64-macos, x86_64-macos]
upstream: [codeberg#35291]
affects-line: yes
---

## Symptom

On macOS (APFS, case-insensitive by default), running `zig build` in a
subdirectory that contains a `Build.zig` source file (for example `lib/std` in
the Zig tree, or `src/` in zine) uses that file as the build script instead of
walking up to the project's `build.zig`:

```
lib/std/Build.zig:2156:44: error: root source file struct 'build' has no member named 'build'
```

## Evidence

- codeberg#35291 (0.16.0, macOS).
- Reproduced on 0.17.1, aarch64-macos: `zig init -m` project, `sub/Build.zig`
  containing `pub const x = 1;`, `cd sub && zig build` -> the error above.

## Root cause

`lib/compiler/Maker.zig:4106-4112` (`findBuildRoot`): the upward search tests
each directory with `Io.Dir.cwd().access(io, "<dir>/build.zig")`, which
succeeds for `Build.zig` on a case-insensitive file system.

## Fix sketch

After `access` succeeds, confirm the exact name: iterate the directory (or
`realpath` and compare the basename) and continue upward unless an entry is
exactly `build.zig`. Only needed on case-insensitive file systems, so it can
be done on match only. Small.

## Verification

The reproduction above builds the parent project. Running `zig build` from
`lib/std` in the Zig tree builds the Zig project.

## Notes

Not fixed on origin/master. The reporter suggests also preferring a directory
that has `build.zig.zon`.
