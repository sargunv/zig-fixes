---
title: Concurrent compilations sharing a cache directory deadlock on C object and Win32 resource manifest locks
priority: 1
area: build-system
targets: [all]
upstream: [codeberg#37474]
affects-line: yes
---

## Symptom

Two `zig build-lib` processes that share `--cache-dir` can hang forever, both
at 0% CPU. One compiles C sources `a.c, b.c` and the other `b.c, a.c`, with
different contents but the same paths relative to their build roots. Separate
cache directories avoid the hang. Concurrent `zig build` / `zig cc` runs
from several worktrees or CI jobs that share a cache can hit this.

`.rc` Win32 resources deadlock the same way: two compilations for a Windows
target with `a.rc, b.rc` and `b.rc, a.rc`.

## Evidence

- codeberg#37474 (0.18.0-dev.738), found through the Acton build system. A
  comment gives a Python reproduction; an extended version is kept in
  Verification below.
- Reproduced on 0.17.1, aarch64-macos, with the release binary: the script
  printed `timed out: [None, None]` in 6 of 6 runs (30–60 s timeouts; the
  same build alone finishes in 5.1 s), and with four processes, four files
  and shuffled orders in 1 of 1 run.
- Inspected while hung, with a ReleaseSafe build of this line (unfixed):
  `lsof` showed each process holding both object manifests open, with the
  manifests opened in opposite orders. A non-blocking `flock` probe from
  outside got `LOCK_SH` on both manifests and was refused `LOCK_EX` on
  both: both are held shared, and neither exclusively. `lldb` showed both
  processes' main threads in `flock` with this stack:

  ```
  Io.File.lock(l=exclusive)                     File.zig:638
  Build.Cache.Manifest.upgradeToExclusiveLock   Cache.zig:2059
  Build.Cache.Manifest.checkProgressless        Cache.zig:994
  Build.Cache.Manifest.check                    Cache.zig:897
  Compilation.updateCObject                     Compilation.zig:5531
  ```

  with `c_object.src.src_path` `…/1/b.c` in the first process and `…/2/a.c`
  in the second.

## Root cause

Line numbers are at 0.17.1.

`updateCObject` checks the object's manifest (`src/Compilation.zig:5531`,
`Manifest.check`), on a miss compiles the object and renames it into
`o/<digest>/` (`Compilation.zig:5872`), writes the manifest
(`Compilation.zig:5897`, `Manifest.finalize`, which downgrades the lock to
shared, `lib/std/Build/Cache.zig:2032`), and then keeps the shared lock:
`.lock = man.toOwnedLock()` (`Compilation.zig:5909`) stores it in
`CObject.status.success.lock` (`Compilation.zig:848`). It is released only
when the object is next updated or the compilation is destroyed
(`CObject.clearStatus`, `Compilation.zig:1138`), so for the life of the
process.

Checking the next object's manifest, `Manifest.checkProgressless` tries an
exclusive lock without blocking; if another process holds the file, it opens
it with a shared lock instead (`Cache.zig:918`–`971`). When that check is a
miss, it must write the manifest, so it upgrades: `upgradeToExclusiveLock`
unlocks and then blocks in `flock(LOCK_EX)` (`Cache.zig:994`, `2058`–`2059`)
until every other holder lets go.

So with a shared cache:

1. Process 1 compiles `a.c` and keeps a shared lock on manifest A. Process 2
   compiles `b.c` and keeps a shared lock on manifest B.
2. Process 1 checks `b.c`: manifest B holds process 2's file digests, so it
   misses, and it blocks for an exclusive lock on B, which process 2 holds
   until it exits.
3. Process 2 checks `a.c` and blocks for an exclusive lock on A, which
   process 1 holds until it exits.

Neither ever exits. A miss on a manifest that another process holds shared
is enough to block; the cycle needs only two processes that reach their
objects' manifests in different orders. Identical file contents do not
deadlock, because the check under the shared lock hits and never upgrades.
`-j1` makes the order fixed; with more jobs the order varies run to run,
and the threads of one process can each hold one object and wait for
another.

### Other locks of the same kind

A compilation keeps other shared manifest locks for its lifetime, and
blocking on an upgrade while keeping them can form cycles too:

- **`.rc` Win32 resources** keep their manifest lock in the same way
  (`updateWin32Resource`, `Compilation.zig:6171`, kept in
  `Win32Resource.status.success.lock`, `1165`). Reproduced on aarch64-macos
  with the reproduction script for resources in Verification below: two
  `zig build-lib -dynamic -target x86_64-windows-gnu` compilations with two
  large `.rc` files in opposite orders hung in 6 of 6 runs with a build of
  this line that had only the C object part of this fix. `lldb` showed both
  blocked in `upgradeToExclusiveLock` called from `updateWin32Resource`
  (`Compilation.zig:6066` at 0.17.1). The 0.17.1 release binary did not hang
  in 9 runs of the same script; its two processes ran one after the other,
  for a reason not found. The output is compiled to `tmp/` and renamed into
  `o/<digest>/` (`Compilation.zig:6150`), like a C object's.
- **The `.manifest` Win32 resource** keeps its lock too
  (`Compilation.zig:6051`), and its lock does protect its output: the `.rc`
  wrapper and the `.res` are written in place into `o/<digest>/`
  (`Compilation.zig:5985`, `6017`, `6036`). A compilation has at most one
  `.manifest` file (`src/main.zig:1923`, `2069`), so with C object and `.rc`
  locks no longer kept, it cannot close a cycle with them.
- **Sub-compilations** (compiler_rt, ubsan_rt, libc, …), libc stub libraries
  and mingw import libraries keep their locks for the parent's lifetime, and
  those locks protect outputs that are deleted and replaced or written in
  place. They form the same cycle with each other; that is
  `shared-cache-subcompilation-lock-cycle`, not fixed here.

## Fix sketch

Do not keep a C object's or an `.rc` resource's manifest lock after it is
done. Every lock such an update takes is then held only while that update
runs, and nothing it waits for while holding one is held for longer, so no
cycle can go through these manifests.

Alternatives considered:

- **Release or downgrade before blocking.** The cache does not know which
  other locks its caller keeps, and the caller cannot give them up in the
  middle of a check without the same loss of protection as not keeping them.
- **Non-blocking upgrade with back-off and retry.** The locks in the cycle are
  held until the other process exits, so retrying never succeeds; it turns
  the hang into a busy loop. Giving up after a while, and compiling without
  the exclusive lock, changes `Manifest.check`'s guarantee for every caller.
- **A canonical lock order.** The manifest names are only known one object at
  a time, objects are compiled in parallel, and a process's order of objects
  is the user's input order. Sorting would mean taking every object's lock
  before compiling any, which serializes the build, and still leaves the other
  holders above.

## Verification

The reproduction script below (an extension of the one from codeberg#37474)
builds `--procs` roots with `--files` C files of 15000 functions each,
compiles them concurrently with one shared `--cache-dir` and
`--global-cache-dir`, and checks that each archive holds one object per
source, with the right symbols, and that the first function of each root
returns its own constant. By default even-numbered processes take the files
in reverse order; `--shuffle` shuffles each process's order; `--same-order`
keeps them all the same.

```
ZIG=/absolute/path/to/zig python3 repro.py [--procs N] [--files K] [--shuffle] [--same-order]
```

```python
#!/usr/bin/env python3
import argparse, os, random, signal, subprocess, tempfile, time
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("--procs", type=int, default=2)
ap.add_argument("--files", type=int, default=2)
ap.add_argument("--funcs", type=int, default=15000)
ap.add_argument("--timeout", type=float, default=60)
ap.add_argument("--shuffle", action="store_true")
ap.add_argument("--same-order", action="store_true")
ap.add_argument("--keep-hung", action="store_true")
a = ap.parse_args()

zig = os.environ.get("ZIG", "zig")
root = Path(tempfile.mkdtemp()).resolve()
print(root, flush=True)
names = [chr(ord("a") + i) for i in range(a.files)]
for n in range(1, a.procs + 1):
    d = root / str(n)
    d.mkdir()
    for name in names:
        (d / (name + ".c")).write_text("".join(
            f"int {name}{i}(int x) {{ return x + {i+n}; }}\n" for i in range(a.funcs)))

procs = []
orders = []
for n in range(1, a.procs + 1):
    order = list(names)
    if a.shuffle:
        random.shuffle(order)
    elif n % 2 == 0 and not a.same_order:
        order.reverse()
    orders.append(order)
start = time.time()
try:
    for n, files in zip(range(1, a.procs + 1), orders):
        d = root / str(n)
        args = [zig, "build-lib", "-j1", "-OReleaseFast", "--name", "repro",
                "--build-root", str(d), "--cache-dir", str(root / "cache"),
                "--global-cache-dir", str(root / "global"),
                "-femit-bin=" + str(d / "librepro.a")]
        args += [str(d / (f + ".c")) for f in files]
        with open(root / f"{n}.log", "wb") as log:
            procs.append(subprocess.Popen(args, cwd=root, stdout=log, stderr=log, start_new_session=True))
    deadline = start + a.timeout
    for p in procs:
        p.wait(timeout=max(0.1, deadline - time.time()))
    rcs = [p.returncode for p in procs]
    print("finished:", rcs, "orders:", orders, "in %.1fs" % (time.time() - start), flush=True)
    ok = all(rc == 0 for rc in rcs)
    for n in range(1, a.procs + 1):
        lib = root / str(n) / "librepro.a"
        if not lib.exists() or rcs[n-1] != 0:
            print("BAD: process", n, "exit", rcs[n-1], (root / f"{n}.log").read_text()[:300].strip()); ok = False; continue
        members = sorted(m for m in subprocess.check_output(["ar", "t", str(lib)], text=True).split() if not m.startswith("__.SYMDEF"))
        want = sorted(f"{x}.o" for x in names)
        if members != want:
            print("BAD members", n, members); ok = False
        syms = subprocess.check_output(["nm", "-g", str(lib)], text=True)
        for x in names:
            if f"_{x}0" not in syms and f" {x}0" not in syms:
                print("BAD missing symbol", n, x); ok = False
        # The first function of root n returns x + 1 + n.
        dis = subprocess.check_output(["objdump", "-d", f"--disassemble-symbols=_{names[0]}1", str(lib)], text=True, stderr=subprocess.DEVNULL)
        if f"#0x{1+n:x}" not in dis and f"#{1+n}" not in dis:
            print("BAD content", n, dis[-300:]); ok = False
    print("outputs ok" if ok else "OUTPUTS BAD", flush=True)
except subprocess.TimeoutExpired:
    print("timed out:", [p.poll() for p in procs], "pids:", [p.pid for p in procs], "orders:", orders, flush=True)
    if a.keep_hung:
        raise SystemExit(2)
finally:
    if not a.keep_hung:
        for p in procs:
            if p.poll() is None:
                try: os.killpg(p.pid, signal.SIGKILL)
                except ProcessLookupError: pass
            p.wait()
```

The content check uses `objdump` syntax for aarch64-macos.

For `.rc` resources, the script below builds two Windows DLLs from roots
with large `RCDATA` resources (300000 strings each with `--strings 300000`;
the default is too small to overlap) in opposite orders, and checks that
each DLL holds its own root's resources. `--global-cache` points at a
global cache warmed by a single run, so the runs do not each rebuild the
same libraries. (The `zig rc` child process ran from the default global
cache, `~/.cache/zig/o/…`, whatever `--global-cache-dir` said.)

```
ZIG=/absolute/path/to/zig python3 rc_repro.py --strings 300000 --global-cache <dir> [--procs N] [--files K] [--shuffle]
```

```python
import argparse, os, random, signal, subprocess, tempfile, time
from pathlib import Path
ap = argparse.ArgumentParser()
ap.add_argument("--procs", type=int, default=2)
ap.add_argument("--files", type=int, default=2)
ap.add_argument("--strings", type=int, default=20000)
ap.add_argument("--timeout", type=float, default=60)
ap.add_argument("--shuffle", action="store_true")
ap.add_argument("--keep-hung", action="store_true")
ap.add_argument("--global-cache")
a = ap.parse_args()
zig = os.environ.get("ZIG", "zig")
root = Path(tempfile.mkdtemp()).resolve()
print(root, flush=True)
names = [chr(ord("a") + i) for i in range(a.files)]
for n in range(1, a.procs + 1):
    d = root / str(n); d.mkdir()
    (d / "main.c").write_text("__declspec(dllexport) int f(void) { return 0; }\n")
    for k, name in enumerate(names):
        body = ",\n".join(f'  "{name} {n} {i}"' for i in range(a.strings))
        (d / (name + ".rc")).write_text(f"{k + 1} RCDATA\nBEGIN\n" + body + "\nEND\n")
orders = []
for n in range(1, a.procs + 1):
    o = list(names)
    if a.shuffle: random.shuffle(o)
    elif n % 2 == 0: o.reverse()
    orders.append(o)
procs = []; start = time.time()
try:
    for n, files in zip(range(1, a.procs + 1), orders):
        d = root / str(n)
        args = [zig, "build-lib", "-dynamic", "-j1", "-target", "x86_64-windows-gnu", "--name", "repro",
                "--build-root", str(d), "--cache-dir", str(root / "cache"),
                "--global-cache-dir", a.global_cache or str(root / "global"), "-fno-entry", "-femit-bin=" + str(d / "repro.dll"),
                str(d / "main.c")] + [str(d / (f + ".rc")) for f in files]
        with open(root / f"{n}.log", "wb") as log:
            procs.append(subprocess.Popen(args, cwd=root, stdout=log, stderr=log, start_new_session=True))
    deadline = start + a.timeout
    for p in procs: p.wait(timeout=max(0.1, deadline - time.time()))
    rcs = [p.returncode for p in procs]
    print("finished:", rcs, "orders:", orders, "in %.1fs" % (time.time() - start), flush=True)
    ok = all(rc == 0 for rc in rcs)
    for n in range(1, a.procs + 1):
        if rcs[n-1] != 0:
            print("BAD: process", n, (root / f"{n}.log").read_text()[:300].strip()); continue
        data = (root / str(n) / "repro.dll").read_bytes()
        for name in names:
            # RCDATA strings are stored as bytes.
            if f"{name} {n} 1".encode() not in data:
                print("BAD: process", n, "missing strings from", name); ok = False
    print("outputs ok" if ok else "OUTPUTS BAD", flush=True)
except subprocess.TimeoutExpired:
    print("timed out:", [p.poll() for p in procs], "pids:", [p.pid for p in procs], "orders:", orders, flush=True)
    if a.keep_hung: raise SystemExit(2)
finally:
    if not a.keep_hung:
        for p in procs:
            if p.poll() is None:
                try: os.killpg(p.pid, signal.SIGKILL)
                except ProcessLookupError: pass
            p.wait()
```

No test is added. Upstream's suite has no way to run two compilations
against one cache in a chosen interleaving, and a test that relies on timing
to hit the race is flaky by construction.

## Fix

`src/Compilation.zig`:

- `updateCObject` no longer keeps the object's manifest lock
  (`man.toOwnedLock()`); `man.deinit()` releases it when the update returns.
  `CObject.status.success.lock` and its release in `clearStatus` are removed,
  and `clearStatus` and `destroy` lose the `Io` argument that only the release
  used.
- `updateWin32Resource` does the same for `.rc` files:
  `Win32Resource.status.success.lock` becomes optional, and only the
  `.manifest` file, whose `.res` is written in place, still keeps it.
- Both rename their output into `o/<digest>/` with a new
  `renameTmpFileIntoCache`. It is `Io.Dir.rename`, except that on Windows,
  when the rename fails with `AccessDenied` and the file at the destination
  has the same bytes as the new one, it keeps the existing file and deletes
  the new one. Any other error, a destination that is missing or differs,
  or a failure to compare them still fails the rename as before. It compares
  bytes rather than trusting the digest because with `disable_c_depfile`
  the digest does not cover included headers.

Not keeping these locks is safe because nothing they protected needs them:

- The output is compiled to `tmp/` and renamed into `o/<digest>/`
  (`Compilation.zig:5872`, `6150` at 0.17.1). The rename is atomic, so a
  reader sees a complete file, old or new.
- `o/<digest>` is named by the hash of the inputs, flags and contents, so
  another process writes that name only for an identical file. Nothing
  deletes these outputs. The exception is `disable_c_depfile`, whose digest
  leaves out included headers. There another process could already rename a
  different object over `o/<digest>` while the lock was kept: that check runs
  after compiling, its shared lock hits, and the rename follows either way
  (`Compilation.zig:5848`–`5872`). Releasing the lock does not change that.
- The manifest itself is still read and written under its lock, as before:
  `finalize` writes it under the exclusive lock, and the lock is released only
  after that.

What changes: while a compilation is still running, another process with
different contents for the same object can now rewrite the object's manifest
instead of waiting for the first process to exit. The first process's object
stays in its own `o/<digest>`. If a third process then compiles the first
one's contents again, it renames an identical file over the one the first
process may still be reading. POSIX systems, and Windows 10 and later on
NTFS (`FILE_RENAME_POSIX_SEMANTICS`), replace an open file. On older Windows
or on FAT32, std falls back to a plain rename (`lib/std/Io/Threaded.zig:7791`
–`7855`), which cannot replace an open file and returns `AccessDenied`
(`Threaded.zig:7895`). Without the fallback above, the third process would
fail with a rename error where it used to wait; with it, that process uses
the file already there once it has checked that the bytes are the same. **The Windows path was compiled but never
executed:** this machine has no Windows and no Wine.

This depends on `cb37200-cache-input-digest-compare`. With the deadlock gone,
a process that misses under a shared lock always gets the upgrade and checks
the manifest a second time, and without that fix the second check reports a
false hit on a digest that names no object.

No unit test covers `renameTmpFileIntoCache`'s fallback: it acts only when
the OS refuses a rename over an open file, which no test on a POSIX host can
cause, and upstream's tests do not run on Windows FAT32 or pre-Windows-10.
Factoring the decision out to test it on its own would be a refactor.

### Verification results

C objects, aarch64-macos (compilers built from this branch, on top of
`cb37200-cache-input-digest-compare`):

- Before (0.17.1 release binary, and a ReleaseSafe build of this line
  without the fix): the script hung in 6 of 6 runs with the release binary,
  1 of 1 with the build, and 1 of 1 with four processes and shuffled orders.
- After, two processes in opposite orders: 20 of 20 consecutive runs printed
  `finished: [0, 0]` and `outputs ok`, in 8.2–10.4 s each.
- After, `--procs 3 --files 3 --shuffle`: 10 of 10 finished, outputs ok.
- After, `--procs 4 --files 4 --shuffle`: in a first batch, 9 of 10
  finished; one hit the script's 120 s timeout at a load average of about
  21 from other builds, and was killed before it could be inspected. Then
  8 of 8 with `--keep-hung`, and later 20 of 20 with `--keep-hung` and a
  300 s limit, all with outputs ok. At load 3–5 those took 21–34 s; two runs
  during load spikes took 37 s (load 14) and 73 s (load 20). Run time follows
  load and no run kept a hung process, so the timeout was load, not a third
  cycle. The same configuration passed 10 of 10 on Linux.
- After, `--same-order`: 5 of 5 finished, outputs ok.

C objects, aarch64-linux-musl: the compiler cross-built from this branch
(and, for "before", from the line's base) with the Linux devkit, run in an
`ubuntu:24.04` container on its own overlay filesystem, with a POSIX `sh`
port of the script that checks each archive by linking it into a test
program that calls one function from every file:

- Before: 3 of 3 two-process runs in opposite orders hung (and every earlier
  attempt). `/proc/locks` showed the cycle directly: each `zig` held a
  `FLOCK READ` on one object manifest and waited (`->`) for `FLOCK WRITE` on
  the other's, both in `locks_lock_inode_wait`.
- After: 20 of 20 two-process runs in opposite orders, 10 of 10 three-process
  and 10 of 10 four-process runs with shuffled orders, and 5 of 5 same-order
  runs finished with outputs ok.

`.rc` resources, aarch64-macos, `rc_repro.py --strings 300000`:

- Before (this branch with only the C object part): 6 of 6 two-process runs
  hung, with the `lldb` stacks above.
- After: 20 of 20 two-process runs in opposite orders, and 5 of 5
  three-process runs with shuffled orders, finished with outputs ok. A DLL
  with a `.manifest` resource, built twice, embeds the manifest both times
  and leaves one `.res` in the cache: the second build hit.

Windows: the compiler's Zig code, with `have_llvm` on, passes semantic
analysis (`zig build-exe -fno-emit-bin` of `src/main.zig` with the build's
own options module) for `x86_64-windows-gnu` and `aarch64-windows-gnu`. A
deliberate type error placed in an existing Windows-only branch on the same
rename path made the same check fail, so the check does analyze that code.
A full cross-build of the compiler for Windows was not possible here: its
C++ sources need Windows LLVM headers, and only the macOS and Linux devkits
are available.

Other:

- `zig test lib/std/std.zig --zig-lib-dir lib --test-filter
  "Build.Cache.test"`: all 6 cache tests pass.
- A `build.zig` with a library of two C sources, built twice with fresh
  cache directories: the second `zig build --summary all` reported the
  compile step `cached` and wrote no new object files.

## Notes

The manifest doc comment (`Cache.zig:278`) promises that several processes can
use one cache directory at the same time.

Compilations whose whole-compilation manifests have the same name (the same
input paths in the same order and the same flags) but different contents
still serialize: the second waits until the first process exits, because the
first keeps its whole-cache lock (`Compilation.zig:2846`, `3140`). That is a
wait, not a cycle, as long as the first process waits for nothing the second
holds. `shared-cache-subcompilation-lock-cycle` is the case where it does.
