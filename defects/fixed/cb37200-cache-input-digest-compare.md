---
title: Cache compares a re-hashed input file with itself, giving spurious misses and false hits
priority: 1
area: build-system
targets: [all]
upstream: [codeberg#37200]
affects-line: yes
---

## Symptom

Two symptoms, one cause.

- **Spurious miss.** After `touch a.c`, or after replacing `a.c` with an
  identical copy, `zig build` recompiles `a.c` although its contents did not
  change. Caches restored in CI always miss for this reason, because restoring
  changes every file's inode and mtime.
- **False hit.** Two compilations that share `--cache-dir` and compile files
  with the same path relative to their build roots but different contents,
  in the same order. The second one waits for the first one's manifest lock,
  misses, upgrades its lock, checks the manifest again, and that second check
  reports a hit. Its digest names an output directory that nobody built:

  ```
  error: failed to open cache/o/c07b898f72df9086e4987716e7535d5b/a.o: FileNotFound
  ```

## Evidence

- codeberg#37200 (closed by upstream commit 9343d0fe4b on master, not on
  `0.17.x`) reports the spurious miss, with a shell reproduction.
- The false hit, reproduced on the 0.17.1 release binary, aarch64-macos: the
  reproduction script in the Verification section of this entry, with
  `--same-order`, printed `finished: [0, 1]` and the error above in 3 of 3
  runs, and once more on a kept run whose cache directory showed no
  `o/c07b…` directory.

## Root cause

`Manifest.checkInputPath` (`lib/std/Build/Cache.zig:1346` at 0.17.1)
compares an input file with its manifest entry. When the file's stat
differs from the entry's, it re-hashes the file into `disk_file.digest`,
overwriting the digest the manifest recorded (`Cache.zig:1421`, `1458`,
`1506`, `1518`), and then compares that with `input_file.digest`
(`Cache.zig:1423`, `1474`, `1528`).

- On a first check, `input_file.digest` was never computed (zero), so the
  comparison always fails: a spurious miss, whatever the contents.
- On a second check, after `checkProgressless` missed under a shared lock and
  upgraded it (`Cache.zig:994`–`1001`), the first check's miss path has already
  computed `input_file.digest` from the file (`populateInputPath`,
  `Cache.zig:1173`). The re-hash then writes the same value into
  `disk_file.digest`, so the comparison is the file against itself and always
  succeeds: a hit, whatever the manifest recorded. The hit digest (`hitDigest`) is computed from the
  file's own contents, so it names an output that the manifest never
  described and that may not exist.

## Fix sketch

Hash into `input_file.digest` and copy it into `disk_file.digest` only on a
miss. That is upstream's 9343d0fe4b.

## Verification

- `zig test lib/std/std.zig --zig-lib-dir lib --test-filter "Build.Cache.test"`
  runs upstream's new test, "changed metadata of input file but same digest
  causes hit".
- With a compiler built from this line, the reproduction script kept in the
  `cb37474-shared-cache-manifest-deadlock` entry, run with `--same-order`,
  prints `finished: [0, 0]` and `outputs ok`.

## Fix

Cherry-picked upstream's 9343d0fe4b ("std.Build.Cache: fix cache miss when
metadata changes") unchanged. It hashes the file into `input_file.digest`
and copies it over `disk_file.digest` only when they differ, so the
comparison is always between the file and the manifest's record. It also
adds the test above.

Verified on aarch64-macos:

- `zig test lib/std/std.zig --zig-lib-dir lib --test-filter
  "Build.Cache.test"` with the 0.17.1 release binary: all 6 cache tests pass,
  including the new one.
- With a compiler built from this branch, the reproduction script with
  `--same-order` (two processes, same input order, shared cache): 5 of 5
  runs printed `finished: [0, 0]` and `outputs ok`, where 0.17.1 failed 3 of
  3. Each run took 16 s, because the second process still waits for the
  first to exit before it can write the manifest; the default, swapped order
  still hung in 2 of 2 runs, which is
  `cb37474-shared-cache-manifest-deadlock`.
- The `build.zig` from codeberg#37200 with two C sources: after `touch a.c`,
  0.17.1 recompiled `a.c` and the compiler from this branch reported the
  step `cached` and wrote no new object.

## Notes

`cb37474-shared-cache-manifest-deadlock` depends on this fix: once that
deadlock is gone, the second check after a lock upgrade runs every time
two compilations race on a manifest, and without this fix it reports the
false hit.
