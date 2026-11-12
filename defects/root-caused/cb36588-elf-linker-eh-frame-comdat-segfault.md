---
title: ELF linker segfaults on C++ objects whose FDEs point at discarded COMDAT sections
priority: 1
area: linker
targets: [x86_64-linux-gnu, x86_64-linux-musl, x86_64-linux-android]
upstream: [codeberg#36588, github#25997]
affects-line: yes
---

## Symptom

Debug builds for x86_64 Linux (self-hosted backend, so Zig's own ELF linker)
crash when linking a relocatable object made from two C++ files that both
instantiate the same templates (e.g. `std::vector<std::string>`). With a debug
compiler: `panic: attempt to use null value` at
`src/link/Elf/eh_frame.zig:43 in atom`, from `Object.zig` FDE sort in
`parseObject`. `use_llvm = true` or a single C++ file avoids it.

## Evidence

- Reported on 0.17.0-dev.1818 (codeberg#36588, migrated from github#25997);
  maintainer stack trace in the comments.
- Reproduced on 0.17.1 from aarch64-macos:
  `zig build-obj foo.cpp bar.cpp -lc++ -target x86_64-linux-gnu -femit-bin=hello.o`
  then `zig build-exe main.zig hello.o -lc++ -target x86_64-linux-gnu -fno-llvm`
  exits 139 (segfault).

## Root cause

`src/link/Elf/eh_frame.zig:38-43` (`Fde.atom`) unwraps
`object.atom(atom_index).?`; for an FDE whose target section was a COMDAT
group member discarded as a duplicate, there is no atom, so the sort comparator
at `src/link/Elf/Object.zig:531-539` dereferences null.

## Fix sketch

Skip (mark dead) FDEs whose target atom is absent or discarded before sorting,
as LLD does. Upstream tried "Elf: correctly handle relocations of discarded
COMDAT sections" (e9432528ab) and reverted it (fe6ee5d4b3, 2026-10-28), both
on master only; review why it was reverted before backporting.

## Verification

The two-step reproduction above links and the program prints its message on
x86_64 Linux. Add a `test/link/elf.zig` case with duplicate COMDAT + eh_frame.

## Notes

Old ELF linker (`src/link/Elf`) is what Debug x86_64-linux uses in 0.17.1
(`src/target.zig:311-331`).
