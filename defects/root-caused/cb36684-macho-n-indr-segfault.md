---
title: Mach-O linker segfaults or misresolves N_INDR (.set alias) symbols
priority: 1
area: linker
targets: [aarch64-macos, x86_64-macos, aarch64-ios]
upstream: [codeberg#36684]
affects-line: yes
---

## Symptom

An object with an indirect symbol, e.g. assembly `.globl bare` / `.set bare, _main`,
crashes the linker when a call goes through it, or links to an address equal to
the string-table offset when data goes through it:

```c
extern int viewed(void) __asm__("bare");
int x; int main(void) { return x ? viewed() : 0; }
```

`zig cc crash.c crash.s` segfaults; the data variant links but `nm` shows
`0000000000000001 T bare2` and the binary segfaults. Apple ld64 handles both.

## Evidence

- Reported on 0.17.0-dev.1933 (codeberg#36684, repro repo
  eval-and-prosper/zig-macho-indr-crash).
- Reproduced on 0.17.1 natively on aarch64-macos: `zig cc crash.c crash.s`
  exits 139; `zig cc mis.c mis.s` succeeds and `./mis-zig` exits 139.

## Root cause

The Mach-O linker has no handling for `N_INDR` at all (`grep -rn INDR
src/link/MachO` finds nothing). `src/link/MachO/Object.zig:896-934` treats
every non-undef nlist as a definition and sets `symbol.value = nlist.n_value`;
for `N_INDR`, `n_value` is a string-table index naming the target symbol, so
the symbol gets a bogus value and no atom.

## Fix sketch

When parsing nlists, treat `n_type == N_INDR` as an alias: resolve the name at
`n_value` in the string table and make the symbol resolve to that target
(or report a clear "unsupported N_INDR" error as a first step). Moderate.

## Verification

Both reproductions from the issue link and run (exit 0); add a
`test/link/macho.zig` case.

## Notes

Not fixed on origin/master.
