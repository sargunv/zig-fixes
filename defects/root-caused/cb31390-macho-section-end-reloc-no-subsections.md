---
title: Mach-O linker rejects relocations to a section's end in objects without MH_SUBSECTIONS_VIA_SYMBOLS
priority: 1
area: linker
targets: [aarch64-macos, x86_64-macos]
upstream: [codeberg#31390]
affects-line: yes
---

## Symptom

Linking an object whose non-extern pointer relocation targets the end of a
section (addr + size) fails:
`error: __DATA,__noptrdata: 0x808: bad relocation` / `note: while parsing
.../go.o`. Seen with cgo on Go 1.21 and older using
`CC="zig cc -target aarch64-macos.11.0"`. ld64 accepts it.

## Evidence

- Reported on 0.15.2 (codeberg#31390), cross-compiling from linux/amd64.
- Maintainer diagnosis in comments: the end-of-section case is handled only for
  objects with `MH_SUBSECTIONS_VIA_SYMBOLS`; the fix is to apply the same in
  `initSections`.
- Not reproduced (needs an old Go toolchain); code read at 0.17.1.

## Root cause

`src/link/MachO/Object.zig:411-431` (`initSubsections`) adds a zero-size
`<seg>$<sect>$end` atom so relocations to `addr + size` resolve.
`initSections` (`src/link/MachO/Object.zig:435-...`), used for objects without
`MH_SUBSECTIONS_VIA_SYMBOLS` (Go's object files), creates one atom per section
and no end atom, so `findAtomInSection` (line 817) finds nothing for the
end address.

## Fix sketch

Add the same dummy end-of-section atom (and subsection entry) in `initSections`.
Small.

## Verification

Hand-written asm object without `.subsections_via_symbols` containing
`.quad Lsect_end` where the label is at the end of a `__DATA` section links
and the pointer has the right value; or the issue's cgo reproduction with Go 1.21.

## Notes

The issue carries a hacky local patch (return the last atom); prefer the
maintainer's approach.
