---
title: Package whose paths exclude build.zig.zon gets a different hash when restored from cache
priority: 1
area: build-system
targets: [all]
upstream: [codeberg#31251]
affects-line: yes
---

## Symptom

If a dependency's `build.zig.zon` lists `.paths` that do not include
`build.zig.zon` itself, the first `zig build` succeeds, but after deleting
`zig-pkg/` (or building the same project from a second checkout) the build
fails:

```
error: hash mismatch: manifest declares pkg-0.0.1-g4Ga... but the fetched
package has N-V-__8AAGYAAAD56nAaoB-...
```

The digest part is identical; only the name/version prefix is lost. The
reporter hit it with allyourcodebase/ffmpeg (its libmp3lame and libogg deps).

## Evidence

- codeberg#31251 (0.16.0-dev.2619). A commenter identified the trigger:
  `build.zig.zon` missing from the dependency's `paths`.
- Reproduced on 0.17.1, aarch64-macos: package from `zig init -m` with
  `.paths = .{ "build.zig", "src" }`, tarred, `zig fetch --save
  file://.../pkg.tar.gz`, `zig build` (ok), `rm -rf zig-pkg .zig-cache`,
  `zig build` -> the hash mismatch above. The global cache tarball
  `p/<hash>.tar.gz` contains only `build.zig` and `src/root.zig`.

## Root cause

`lib/compiler/Maker/Fetch.zig:762` loads the manifest (name, version) before
filtering, so the first hash carries the `name-version-` prefix. Then
`computeHash` deletes every file the filter excludes, including
`build.zig.zon` (`Fetch.zig:1764`; `Filter.includePath` at line 2019 has no
exception for the manifest). The `zig-pkg` copy and the recompressed global
cache tarball (`recompressFallible`, line 392) therefore lack the manifest, and
re-extracting computes a naked `N-V-` hash.

## Fix sketch

Always keep `build.zig.zon` at the package root (treat it as included in
`Filter.includePath`, or skip deleting it in `computeHash`); it is already part
of the hash identity through name and version. Alternatively reject such
packages with a clear error. A few lines; check that the content digest is
unchanged so existing hashes stay valid.

## Verification

The reproduction above: the second `zig build` succeeds and `p/<hash>.tar.gz`
contains `build.zig.zon`.

## Notes

Not fixed on origin/master. Separate from cb37053 (wrong directory level in
the cached tarball), though both surface as the same "hash mismatch" error.
