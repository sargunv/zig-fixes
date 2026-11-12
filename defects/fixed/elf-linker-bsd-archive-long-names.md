---
title: Self-hosted ELF linkers misparse BSD-format archives, whose member names use the `#1/<len>` form
priority: 2
area: linker
targets: [x86_64-linux-ohos, x86_64-linux-musl, x86_64-linux-gnu, aarch64-linux-musl]
upstream: []
affects-line: yes
---

## Symptom

Linking an archive written in BSD `ar` format (as produced by macOS `ar` or
`llvm-ar --format=bsd`) with Zig's own ELF linker fails, even when the
archive holds nothing but its symbol table:

```
$ zig build-exe m.zig -target x86_64-linux-musl bsd.a
error: failed to parse archive: InputOutput
    note: while parsing bsd.a
$ zig build-exe m.zig -target x86_64-linux-musl bsd.a -fnew-linker
error: bad ELF magic
    note: while parsing bsd.a
```

`m.zig` is `pub fn main() void {}`. With `-fllvm -flld`, or with the same
archive rewritten by `llvm-ar rcs --format=gnu`, it links.

An archive that also holds objects fails the same way with the new linker,
and with `error: not an ELF file` with the old one: its symbol table is
larger, so the old linker reads it far enough to find no ELF magic. Neither
linker gets as far as the objects.

The OpenHarmony SDK for macOS hosts ships such archives: its
`sysroot/usr/lib/<triple>/libm.a`, `libdl.a`, `libpthread.a` and `librt.a` are
88-byte BSD archives holding one `#1/12` member named `__.SYMDEF`. When
linking libc for `x86_64-linux-ohos` in a Debug build, Zig uses the
self-hosted backend and linker and passes `libm.a` and `libdl.a` to it, for
dynamic and `-static` executables alike, so the link fails.

## Evidence

- Reproduced on 0.17.1 (macOS host) with the release binary, using a copy of
  the SDK's `libm.a` as `bsd.a` above, and with an archive of three
  `x86_64-linux-musl` objects made by `llvm-ar rcs --format=bsd` (LLVM 23).

## Root cause

In the BSD format, a member whose name does not fit in `ar_name`, or holds a
space, has `ar_name = "#1/<len>"`, and its real name is the first `<len>`
bytes of the member data, which `ar_size` includes; `llvm-ar` pads the name
with NULs and uses this form for every member. A name that does fit is
stored in `ar_name` padded with spaces, without GNU's terminating `/`.

- `std.elf.ar_hdr.name` (`lib/std/elf.zig:3425-3430`) returns the text before
  the first `/`, so `#1/12` reads as a member named `#1`. The `isSymdef` checks
  compare `ar_name` against `__.SYMDEF` padded, which never matches the
  `#1/<len>` form.
- The old ELF linker (`src/link/Elf/Archive.zig:79-100`) then treats the
  symbol table as an object at the start of the member data, which begins
  with the name, and fails reading it (`InputOutput` or `not an ELF file`).
- The new ELF linker (`src/link/Elf2.zig:7307-7329`) does the same and fails
  with `bad ELF magic`.
- Both report a short BSD name with its trailing spaces, since there is no
  `/` to stop at.

## Fix sketch

In both linkers, recognize `#1/<len>`: read the name from the first `<len>`
bytes of the member, skip it if it is `__.SYMDEF` or `__.SYMDEF SORTED`, and
otherwise load the object at `offset + len` with size `size - len`. Roughly
10-20 lines each.

## Verification

The two commands in Symptom link. Then `zig build-exe hello.zig -target
x86_64-linux-ohos -lc --libc <libc file for the SDK>` links in Debug without
`-fllvm`.

## Fix

Both linkers now read the BSD form: `src/link/Elf/Archive.zig` and
`src/link/Elf2.zig` parse `#1/<len>`, take the name from the member data up
to its first NUL, skip `__.SYMDEF` and `__.SYMDEF SORTED`, and load the
object at `offset + len` with size `size - len`. A short name has its
trailing spaces trimmed. GNU archives take the same paths as before.
`std.elf` is unchanged.

The new standalone test `test/standalone/elf_bsd_archive` archives two C
objects with `zig ar rcs --format=bsd` and links a program against both with
each linker, for `x86_64-linux`, running it where the host can. It fails
with the release binary (`not an ELF file`, `bad ELF magic`) and passes with
the fix. `test/link.zig` would not run it: its target matrix holds only
Windows targets.

Verified with a compiler built from this change, on a macOS aarch64 host:

- Three `x86_64-linux-musl` C objects, `short.o`, `a_very_long_object_name.o`
  and `sp ace.o`, were archived four ways: `llvm-ar rcs --format=bsd`
  (`#1/` for every member), a hand-written BSD archive in the FreeBSD
  layout (plain `__.SYMDEF` and `short.o`, `#1/` only for the long name and
  the one with a space, without NUL padding so that object data starts at an
  odd offset), `llvm-ar rcs --format=gnu` (with its `//` name table), and
  `--thin`. A Zig program calling a function from each object was linked
  with both linkers. The BSD and GNU archives link, and every binary exits 0
  under `qemu-x86_64`, which it does only if all three functions returned
  their values. Thin archives fail with `BadMagic` with the release binary
  and the fix alike; Zig's ELF linkers have never read them.
- With objects that reference an undefined symbol, the old linker reports
  `bsd.a(short.o)` and `bsd.a(a_very_long_object_name.o)` for both BSD
  layouts. The new linker's `--debug-log link`, in a Debug build, shows
  `loadObject(...(short.o))` and `loadObject(...(a_very_long_object_name.o))`.
- The SDK's `libm.a` links with both linkers.
- `zig build-exe hello.zig -target x86_64-linux-ohos -lc --libc <libc file>`
  in Debug links with the old linker, dynamic (the default) and `-static`.
  With `-fnew-linker` it now gets past the archives and stops at
  elf2-writable-eh-frame-conflict, an unrelated defect in the SDK's
  `clang_rt.crtbegin.o`.

The x86_64 binaries were run with `qemu-x86_64` in an arm64 container. Under
Docker's `linux/amd64` emulation in Colima, every binary from the old linker
segfaults, including the release binary's output for an empty program with no
archive, so that runner was not used.

- For `aarch64-linux-musl`, the old linker is reached with `-fllvm
  -fno-lld`. The same three objects, built for aarch64 and archived with
  `llvm-ar` as BSD and GNU and by hand in the FreeBSD layout, fail with
  `not an ELF file` with the release binary for the BSD archive. With the
  fix all three link, and the binaries exit 0 natively in an arm64
  container. The new linker does not support aarch64 (it panics with
  `AARCH64`). With `-fno-llvm` the aarch64 build never reaches a linker:
  see cb37477-aarch64-selfhosted-runaway-memory, which happens without any
  archive and is not this defect.

## Notes

- Workaround: pass `-fllvm` (LLD is then used), or rewrite the archives with
  `llvm-ar --format=gnu`.
- The 64-bit symbol table names `__.SYMDEF_64` and `__.SYMDEF_64 SORTED`,
  which `llvm-ar` writes only for archives with offsets past 4 GiB, are still
  not recognized.
- Related: ohos-libc-support, elf2-writable-eh-frame-conflict.
