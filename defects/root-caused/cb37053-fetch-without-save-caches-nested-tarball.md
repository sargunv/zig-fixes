---
title: zig fetch without --save leaks tmp/ and caches a tarball one directory too deep, breaking later builds
priority: 1
area: build-system
targets: [all]
upstream: [codeberg#37053, codeberg#37054]
affects-line: yes
---

## Symptom

`zig fetch <url>` (no `--save`) of a tarball with a single top-level directory
prints `warning(fetch): failed to delete temporary directory
.../tmp/.tmp-<hex>: DirNotEmpty`, leaves the unpacked package in
`$ZIG_GLOBAL_CACHE_DIR/tmp/` forever, and writes `p/<hash>.tar.gz` with an
extra directory level (`<hash>/pkg/build.zig` instead of `<hash>/build.zig`).
Any later `zig build` that has to restore the package from that global cache
tarball (fresh checkout, deleted `zig-pkg/`, CI cache) fails with
`error: hash mismatch: manifest declares pkg-0.0.1-... but the fetched package
has N-V-__8AA...` until the global cache is cleared. Using `zig fetch <url>`
to obtain a hash, the documented workflow, is enough to poison the cache.

## Evidence

- codeberg#37053 (0.17.0-dev.2384, confirmed on 0.17.0 by two commenters;
  zig2nix#62 and a Gentoo packaging PR hit it). codeberg#37557 mentions the
  same nested-tarball behaviour as a side note.
- Reproduced on 0.17.1, aarch64-macos, with the issue's script (`zig init -m`
  package tarred with `COPYFILE_DISABLE=1`, `zig fetch --save`, then `zig
  fetch` without `--save`, `rm -rf zig-pkg`, `zig build`): got the
  `DirNotEmpty` warning, `tmp/.tmp-*` left behind, the cached tarball listing
  `pkg-0.0.1-.../pkg/build.zig`, and the hash mismatch error.
- Related codeberg#37054: any fetch that fails after unpacking (bad
  `build.zig.zon`, unsupported tar entry) also leaves `.tmp-*` behind, in
  `zig-pkg/` with `--save`. Reproduced on 0.17.1 with a package whose
  `build.zig.zon` is `.{ .name = garbage`.

## Root cause

`lib/compiler/Maker/Fetch.zig:802`: without local storage, `runResource` sets
`f.package_root = tmp_directory_path` (the scratch directory) instead of
`package_sub_path` (the package root inside it, after the tarball's single
top-level directory is stripped). Recompression at line 809 then archives the
scratch directory, adding the extra level, and the `deleteDir` at line 814
fails because the directory is not empty. Reporter traces it to commit
`3a9b16db`. For #37054, `runResource` has no `errdefer` deleting the scratch
directory created at line 739.

## Fix sketch

Reporter's patch in #37053: use `package_sub_path` as `package_root`; when
there is no local storage, recompress inline (not via `job_queue.group.async`)
and then `deleteTree` the scratch directory. Add an `errdefer deleteTree` of
the scratch directory after it is created (#37054). Roughly 20 lines.

## Verification

Rerun the #37053 script: no warning, `tmp/` empty, cached tarball entries
start with `<hash>/build.zig`, and `zig build` after `rm -rf zig-pkg`
succeeds. A failed fetch leaves no `.tmp-*`.

## Notes

Not fixed on origin/master (Fetch.zig still assigns `tmp_directory_path`).
Workaround: clear `$ZIG_GLOBAL_CACHE_DIR/p/<hash>.tar.gz`, or only use
`zig fetch --save`.
