---
title: Zig's bundled FreeBSD libc provides no libkvm, libmemstat, libprocstat or libdevstat, so links that name them fail
priority: 1
area: bundled-libc
targets: [x86_64-freebsd, aarch64-freebsd, riscv64-freebsd, powerpc64-freebsd, x86-freebsd, arm-freebsd-eabihf]
upstream: []
affects-line: yes
---

## Symptom

```
$ zig cc -target x86_64-freebsd.14.0-none -shared -o fb.so x.c -lkvm
error: unable to find dynamic system library "kvm" using strategy paths_first. searched paths: none
```

The same happens for `-lmemstat`, `-lprocstat`, and `-ldevstat` (inferred from
the library table; only `kvm` was run). The Rust `libc` crate emits these link
names for FreeBSD, so any Rust binary cross-linked with `zig cc` as the linker
for `x86_64-unknown-freebsd` fails, even though nothing calls into these
libraries.

## Evidence

- Reproduced for `-lkvm` on Zig 0.17.1 (macOS host).
- No upstream issue found.

## Root cause

Verified by reading code at 0.17.1.
- Zig links FreeBSD's libc from stub shared objects generated from
  `lib/libc/freebsd/abilists`. The set of libraries it can stub is the table
  `src/libs/freebsd.zig:263-274`: `m`, `stdthreads`, `thr`, `c`, `dl`, `rt`,
  `ld`, `util`, `execinfo`, and `sys` (15.0+).
- `kvm`, `memstat`, `procstat`, and `devstat` are not in the table or in the
  abilists, so the linker treats `-lkvm` as an ordinary system library and
  finds nothing without a sysroot.
- Their headers aren't bundled either: `lib/libc/include/generic-freebsd` has
  `libutil.h` but no `kvm.h`, `memstat.h`, `libprocstat.h`, or `devstat.h`.
  That matters only to C code that includes them.
- The abilists file was added in be566a4c11 (0.15.0) and extended for FreeBSD
  15 in 6906460d56. Per `tools/update_freebsd_libc.zig:11-12`, it "is
  maintained by a separate project and does not come from FreeBSD" (the
  libc-abi-tools generator).

origin/master: the `src/libs/freebsd.zig` table is unchanged apart from
renumbering (verified).

## Fix sketch

Two options:

1. **Full stubs (moderate, mostly mechanical).** Add `kvm` (sover 7),
   `memstat` (3), `procstat` (1), and `devstat` (7) to `src/libs/freebsd.zig`.
   Then regenerate `lib/libc/freebsd/abilists` with the separate abilists
   generator, run over FreeBSD 14.x and 15.x base systems, so those libraries'
   symbols are included. Bundle their public headers if C users should be able
   to include them. Check the sovers against the FreeBSD releases (unverified
   above).
2. **Empty stubs (a few dozen lines).** Teach the FreeBSD stub generator to
   produce symbol-less stubs for a list of "known system libraries without
   symbol data". That is the same trick as the workaround in Notes: links
   succeed, and a real call fails at link time with an undefined symbol
   instead of at configure time.

Option 1 is correct; option 2 is cheap and covers the Rust `libc` crate case.

## Verification

- `zig cc -target x86_64-freebsd.14.0-none -shared -o fb.so x.c -lkvm -lmemstat -lprocstat -ldevstat`
  succeeds. `readelf -d fb.so` shows `NEEDED libkvm.so.7` and so on.
- A Rust binary for `x86_64-unknown-freebsd` with `zig cc` as the linker
  links without a stub directory.

## Notes

- **Workaround today:** nothing calls into these libraries, so empty ones can
  stand in at link time. Build empty `lib{kvm,memstat,procstat,devstat}.so`
  with `zig cc -shared -x c /dev/null` and pass `-L native=<stub_dir>` in
  `RUSTFLAGS`.
- Related: Zig links FreeBSD's libc from its own stubs, which start at 14.0.
  That floor follows from the abilists versions Zig ships.
