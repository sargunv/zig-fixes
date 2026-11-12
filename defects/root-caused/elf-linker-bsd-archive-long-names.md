---
title: Self-hosted ELF linkers misparse BSD-format archives, whose member names use the `#1/<len>` form
priority: 2
area: linker
targets: [x86_64-linux-ohos, x86_64-linux-musl, x86_64-linux-gnu]
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

The OpenHarmony SDK for macOS hosts ships such archives: its
`sysroot/usr/lib/<triple>/libm.a`, `libdl.a`, `libpthread.a` and `librt.a` are
88-byte BSD archives holding one `#1/12` member named `__.SYMDEF`. When
linking libc for `x86_64-linux-ohos` in a Debug build, Zig uses the
self-hosted backend and linker and loads those archives, so the link fails.

## Evidence

- Reproduced on 0.17.1 (macOS host) with the release binary, using a copy of
  the SDK's `libm.a` as `bsd.a` above.

## Root cause

In the BSD format, a member whose name does not fit in `ar_name` has
`ar_name = "#1/<len>"`, and its real name is the first `<len>` bytes of the
member data, which `ar_size` includes.

- `std.elf.ar_hdr.name` (`lib/std/elf.zig:3425-3430`) returns the text before
  the first `/`, so `#1/12` reads as a member named `#1`. The `isSymdef` checks
  compare `ar_name` against `__.SYMDEF` padded, which never matches the
  `#1/<len>` form.
- The old ELF linker (`src/link/Elf/Archive.zig:79-100`) then treats the
  symbol table as an object and fails reading it (`InputOutput`).
- The new ELF linker (`src/link/Elf2.zig:7307-7324`) does the same and fails
  with `bad ELF magic`.

## Fix sketch

In both linkers, recognize `#1/<len>`: read the name from the first `<len>`
bytes of the member, skip it if it is `__.SYMDEF` or `__.SYMDEF SORTED`, and
otherwise load the object at `offset + len` with size `size - len`. Roughly
10-20 lines each.

## Verification

The two commands in Symptom link. Then `zig build-exe hello.zig -target
x86_64-linux-ohos -lc --libc <libc file for the SDK>` links in Debug without
`-fllvm`.

## Notes

- Workaround: pass `-fllvm` (LLD is then used), or rewrite the archives with
  `llvm-ar --format=gnu`.
- Related: ohos-libc-support.
