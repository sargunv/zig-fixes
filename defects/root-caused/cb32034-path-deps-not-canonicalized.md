---
title: Same path dependency reached by two relative paths becomes two packages and fails to compile
priority: 1
area: build-system
targets: [all]
upstream: [codeberg#32034]
affects-line: yes
---

## Symptom

In a monorepo, `lib/bar` depends on `../../app/foo` and `../baz`, and
`app/foo` depends on `../../lib/baz`. Both point at the same `lib/baz`, but
`zig build` in `lib/bar` treats them as two packages and the compile fails:

```
lib/baz/build.zig:1:1: error: file exists in modules '../../lib/baz' and '../baz'
note: files must belong to only one module
```

## Evidence

- codeberg#32034 (0.16.0, milestone Urgent), repro repo
  codeberg.org/mrjbq7/zig-dep-issue.
- Reproduced on 0.17.1, aarch64-macos: three `zig init -m` packages laid out
  as above with `.path` dependencies; `zig build` in `lib/bar` prints the
  error above.

## Root cause

`lib/compiler/Maker/Fetch.zig:985-986`: a path dependency's identity is
`relativePathDigest(new_root)`, where `new_root` is
`f.package_root.resolvePosix(rel_path)`. `Path.resolvePosix`
(`lib/std/Build/Cache/Path.zig:39`) resolves lexically relative to the build
root, so `../../lib/baz` and `../baz` stay different strings when the walk
climbs above the build root and comes back down. Two `Fetch` entries, two
`dependencies.zig` modules with the same root `build.zig`.

## Fix sketch

Canonicalize before hashing: resolve against the absolute build root path
(or `realpath`) and re-relativize, so all spellings of a directory map to one
key. Watch for the cache-key and `--fork` code that reuses
`relativePathDigest`. Small to medium.

## Verification

The layout above builds. Add a standalone test with the three-package layout.

## Notes

Not fixed on origin/master. Upstream has an unmerged `package-conflicts`
branch that reworks package namespaces; not checked whether it covers this.
