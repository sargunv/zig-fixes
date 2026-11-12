---
title: zig cc replaces -lgcc_s with its own statically linked libunwind, duplicating unwinders that other archives already bundle
priority: 1
area: zig-cc
targets: [x86_64-freebsd, all]
upstream: []
affects-line: yes
---

## Symptom

`-lgcc_s` never links a shared `libgcc_s`. Zig builds its own libunwind from
source and links it statically into the output, even when the target's sysroot
has `libgcc_s.so`. Run
`zig cc -target x86_64-freebsd.14.0-none -shared -o fb.so x.c -lgcc_s -v`: the
verbose output shows `ar rcs .../libunwind.a .../libunwind.o .../UnwindLevel1.o ...`
being built and linked.

Consequences:

1. **A segfault at the first panic.** A Rust test binary cross-linked for
   FreeBSD with `zig cc` (rustc passes `-lgcc_s`) got Zig's static libunwind
   plus the private copy of libunwind/libc++abi/libc++ inside a C library's
   static archive. The linker kept one COMDAT group of each name and discarded
   the other copy's members, leaving the archive's localized code pointing at
   discarded sections:
   ```
   * thread #2, stop reason = signal SIGSEGV: invalid permissions for mapped object
       frame #0: 0x000015ab71b84000   # the image base: a zeroed UnwindCursor vtable slot
   ```
2. **A missing `_Unwind_Resume` in reverse.** A C program linking a Rust
   static archive with plain `zig cc` on glibc could not resolve
   `_Unwind_Resume`, because nothing asked for an unwinder.

## Evidence

- Code behavior verified at 0.17.1 (below), and the libunwind build observed
  with `-v`.
- The crash was reproduced in a FreeBSD cross build. Dissolving the COMDAT
  groups in the archive that bundles the private unwinder avoids it.
- The missing symbol was resolved by adding `-lgcc_s` to the link on glibc.

## Root cause

Verified by reading code at 0.17.1.
- `src/target.zig:388-394` (`classifyCompilerRtLibName`) classifies `gcc_s`
  as `.both`. Its comment says libgcc_s carries the exception-handling
  functions, so "zig needs to instead link libunwind". The library name is
  consumed and replaced with Zig's compiler-rt plus a static libunwind, built
  by `src/libs/libunwind.zig`.
- This is a deliberate design choice, not a typo. It is self-consistent for
  programs built entirely by Zig. It conflicts with inputs that already carry
  a private unwinder whose COMDAT groups survive.
- The crash itself is partly the archive's fault: it localized the symbols
  but left the `.group` sections in place.

origin/master: unchanged (`src/target.zig:421-424`, verified).

## Fix sketch

Two options:

1. **Honor a real `libgcc_s` when one exists (a few dozen lines).** When a
   sysroot or libc installation provides `libgcc_s.so` (glibc targets,
   FreeBSD with a real base system), link it dynamically. Substitute the
   static libunwind only when no system copy is available (bundled glibc
   stubs, musl).
   - This needs a `libgcc_s` stub for Zig's bundled glibc. Zig's glibc
     abilists don't currently include it (not checked).
   - It also needs a policy for FreeBSD, where `libgcc_s.so.1` is a base
     library.
2. **Keep the substitution, but make it opt-out (a few lines).** Add a flag
   (for example `-fno-substitute-gcc-s`, or honor an explicit
   `-l:libgcc_s.so.1`). Document that `-lgcc_s` means "Zig's static
   libunwind", so archives that bundle a private unwinder know to strip their
   COMDAT groups.

## Verification

- With option 1, `zig cc -target x86_64-linux-gnu.2.17 -shared -o t.so x.c -lgcc_s`
  produces `NEEDED libgcc_s.so.1` and no libunwind objects in `--verbose-link`.
- Link a Rust test binary for x86_64-freebsd with `zig cc` against a static
  archive that bundles a localized private unwinder with its `.group`
  sections left in place. It should not crash on the first panic.

## Notes

- **Workarounds today:**
  - Dissolve the COMDAT groups of an archive that bundles a private unwinder,
    with `objcopy --remove-section=.group`. It is good hygiene regardless.
  - On glibc, add `-lgcc_s` to the C consumer's link libraries (for example
    in pkg-config `Libs`). It stays correct with either fix.
- Related: Zig links executables with a 16 MiB `PT_GNU_STACK`. That can mask
  a musl thread-stack issue, but it is not a defect.
