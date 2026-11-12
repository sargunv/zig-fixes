---
title: Concurrent compilations sharing a global cache deadlock on sub-compilation manifest locks
priority: 1
area: build-system
targets: [all]
upstream: []
affects-line: yes
---

## Symptom

Two compilations that share a global cache directory hang forever at 0% CPU.
Each has finished one runtime library (compiler_rt, ubsan_rt, libc, libc++,
…) and waits for another that the other process has finished. It takes two
compilations whose runtime libraries have the same cache manifest names but
different contents: the same compiler version and flags, but different
files under the Zig lib directory. That happens when several checkouts of
Zig, or of this repository, at the same commit but with different edits under
`lib/`, run with `--zig-lib-dir lib` and a shared global cache. Any edit under
`lib/std` reaches every runtime library that imports `std`.

```
$ zig build-exe m.c -fsanitize-c=full --zig-lib-dir lib1 --global-cache-dir G &
$ zig build-exe m.c -fsanitize-c=full --zig-lib-dir lib2 --global-cache-dir G &
# both hang
```

## Evidence

Reproduced on 0.17.1, aarch64-macos, with the release binary and the
reproduction script below: `lib1` and `lib2` are copies of `lib/` that differ
only in a comment appended to `compiler_rt.zig` and to `ubsan_rt.zig`. Two
concurrent `zig build-exe m.c -fsanitize-c=full` hung in 3 of 6 runs, and in
1 of 8 runs of the same pair started from a shell loop.

While hung, `lsof` showed each process with both runtime libraries' global
cache manifests open, in opposite orders. A non-blocking `flock` probe from
outside got `LOCK_SH` on both and was refused `LOCK_EX` on both. One process
had built ubsan_rt (its `o/<digest>` held `libubsan_rt.a` from `lib1`) and the
other compiler_rt (from `lib2`). Both processes were blocked in `flock`.

## Root cause

Line numbers are at 0.17.1.

A runtime library is a sub-compilation in whole cache mode. Its
`Compilation.update` checks its manifest in the global cache
(`src/Compilation.zig:2824`, `Manifest.check`). On a miss it builds the
library and writes the manifest, which downgrades the lock to shared, and
keeps that lock in `whole.lock` (`Compilation.zig:3140`). The parent takes
the lock over with `toCrtFile` (`Compilation.zig:7640`, `moveLock` at
`1435`) and keeps it in `comp.compiler_rt_lib`, `comp.ubsan_rt_lib` and the
like (`buildRt`, `Compilation.zig:7470`–`7472`) or in `comp.crt_files`
(`Compilation.zig:7614`). It releases it only when the parent compilation is
destroyed (`CrtFile.deinit`, `Compilation.zig:811`).

The parent builds its runtime libraries concurrently (`performAllTheWork`,
for example `Compilation.zig:4451`). When a sub-compilation's check misses
on a manifest that another process holds shared, `checkProgressless` blocks
in `upgradeToExclusiveLock` (`lib/std/Build/Cache.zig:994`, `2058`–`2059`)
until that process lets go, which is when it exits. So:

1. Process 1 builds ubsan_rt and keeps its manifest shared. Process 2 builds
   compiler_rt and keeps its manifest shared.
2. Process 1's compiler_rt check misses (the manifest records `lib2`'s
   files), and it blocks for an exclusive lock that process 2 keeps.
3. Process 2's ubsan_rt check misses the same way and blocks on process 1.

This is the same cycle as `cb37474-shared-cache-manifest-deadlock`, through a
different kind of kept lock. Other locks kept for a compilation's lifetime can
close the same cycle with these: glibc, FreeBSD, NetBSD and OpenBSD stub
libraries (`BuiltSharedObjects`, `src/libs/glibc.zig:643`–`650`, kept at
`724` and `1149`), mingw import libraries (`src/libs/mingw.zig:280`, `368`),
and the one `.manifest` Win32 resource of a compilation.

### Why those locks cannot simply be dropped

Unlike a C object's lock, these protect their outputs:

- A whole-cache output is built in a temporary directory and renamed to
  `o/<digest>` by `renameTmpIntoCache` (`Compilation.zig:3311`). If
  `o/<digest>` already exists, it deletes the directory first and renames
  again (`Compilation.zig:3338`; on Windows also on `AccessDenied`,
  `3332`). A process that misses with a digest whose directory another
  process is linking from would delete that directory under it. That happens
  when the manifest was rewritten by a third process with different contents.
  The kept shared lock stops the rewrite.
- The libc stub libraries are written in place into `o/<digest>`
  (`src/libs/glibc.zig:783`, `1142`). Without the kept lock, another process
  could rewrite them while this one links them, and the linker could read a
  half-written file.

## Fix sketch

Each candidate changes a guarantee the cache gives today, so none is a
focused fix:

1. **Publish once.** Never replace or delete an existing `o/<digest>`: when
   the rename finds the directory there, keep it and discard the new build,
   because the digest names the contents. Write every kept-locked output (libc
   stubs, mingw import libraries, the Win32 `.manifest` resource) to a
   temporary path first and rename it. Then no reader needs a kept lock, and
   all of these locks can be released when their update returns, as C objects
   now do. Cost: `renameTmpIntoCache` and several library builders change;
   a rebuild can no longer replace an output whose digest is the same, which
   is what `-ftime-report` (`ignore_hit`, `Compilation.zig:2816`) and a
   corrupted cache directory rely on today. A later cache garbage collector
   could no longer use the kept locks to see which outputs are in use.
2. **Miss without the exclusive lock.** When the upgrade would block, give
   up the lock and build privately: use a temporary output for this process's
   lifetime, and neither write the manifest nor rename into `o/`. That changes
   `Manifest.check`'s guarantee that a miss holds the exclusive lock, so every
   caller (`finalize` asserts it) must handle the new case, and the build is
   not cached.
3. **Keep the locks but never wait for an upgrade while holding one.** Cannot
   be done inside the cache, which does not know what its caller keeps; a
   caller would have to give up its kept locks first, which loses the same
   protection as option 1 without its publish-once rule.
4. **Make conflicting library directories use different manifests**, for
   example by hashing the Zig lib directory's path into sub-compilation
   manifests. This removes the case that hits this repository, but only
   makes the cycle less likely: one lib directory edited while two builds
   run can still form it. It also stops identical lib directories at
   different paths from sharing a cache.

A lock order is not possible: the runtime libraries are built in parallel,
in an order the parent does not control.

The decision needed: whether the cache may keep an existing `o/<digest>`
instead of replacing it (option 1), or whether a miss may proceed without the
exclusive lock (option 2).

## Verification

Make two copies of `lib/` that differ in `compiler_rt.zig` and `ubsan_rt.zig`,
and a C file:

```sh
E=$(mktemp -d)
for n in 1 2; do
  cp -cR lib "$E/lib$n"   # cp -R where clonefile is not available
  echo "// variant $n" >> "$E/lib$n/compiler_rt.zig"
  echo "// variant $n" >> "$E/lib$n/ubsan_rt.zig"
done
printf 'int main(int c, char**v){ return c + 1; }\n' > "$E/m.c"
python3 crt.py "$E" /absolute/path/to/zig 8
```

`crt.py` runs both builds concurrently with a fresh shared cache per run and
reports each run as `finished` or `TIMED OUT` (60 s; one build alone takes
about 4 s). Set `KEEP=1` to leave a hung pair running for inspection.

```python
import os, signal, subprocess, sys, tempfile
E, zig, runs = sys.argv[1], sys.argv[2], int(sys.argv[3])
for r in range(runs):
    C = tempfile.mkdtemp()
    ps = [subprocess.Popen([zig, "build-exe", "m.c", "-fsanitize-c=full", "--zig-lib-dir", f"{E}/lib{n}",
        "--cache-dir", f"{C}/local", "--global-cache-dir", f"{C}/global", f"-femit-bin={C}/m{n}"],
        cwd=E, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True) for n in (1, 2)]
    try:
        for p in ps: p.wait(timeout=60)
        print(r, "finished", [p.returncode for p in ps], flush=True)
    except subprocess.TimeoutExpired:
        print(r, "TIMED OUT", [p.poll() for p in ps], [p.pid for p in ps], C, flush=True)
        if os.environ.get("KEEP"): sys.exit(2)
        for p in ps:
            if p.poll() is None: os.killpg(p.pid, signal.SIGKILL)
            p.wait()
```

## Fix

## Notes

Found while root-causing `cb37474-shared-cache-manifest-deadlock`, which
fixes the same cycle for C objects and `.rc` Win32 resources, whose outputs
are renamed into place and never deleted.
