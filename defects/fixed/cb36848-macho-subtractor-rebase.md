---
title: Mach-O linker emits dyld fixups for SUBTRACTOR+UNSIGNED pairs, corrupting the difference
priority: 1
area: linker
targets: [aarch64-macos, x86_64-macos, aarch64-ios]
upstream: [codeberg#36848]
affects-line: yes
---

## Symptom

Assembly containing a position-independent difference such as
`.quad _extsym - .` (OpenSSL 1.1.1 `sha256-armv8.S` uses
`.LOPENSSL_armcap_P: .quad OPENSSL_armcap_P-.`) links, but the output has a
rebase entry pointing into `__TEXT,__text`. dyld then adds the slide to that
word (or rejects the image); `llvm-objdump --macho --rebase` reports
`truncated or malformed object (... bad offset, not in section ...)`.

The same happens when the minuend is a global weak definition
(`.weak_definition _w` ... `.quad _w - .`): the linker emits a weak-bind
entry for the word instead of a rebase, with the same result.

When one side of the difference is imported from a dylib
(`.quad _malloc - .`), the difference cannot be computed at link time and
ld64 rejects the input with `fixup error (kind=diff64) at ... target
'_malloc' does not have address`. Zig's linker links it. For an imported
minuend in a pointer-sized slot it emits a bind, so dyld replaces the slot
with `malloc`'s address and the program silently reads that as the
difference (`.quad _malloc - .` in `__data` printed `0x18eed5ce8`, the
address of `malloc`). For an imported subtrahend, or a 4-byte `.long`
difference, it writes a value computed as if the imported symbol were at
address 0.

## Evidence

- Reported on 0.15.2, 0.16.0 and 0.17.0-dev.2131 cross-compiling OpenSSL from
  Linux (codeberg#36848). Workaround: link with ld64.lld.
- Reproduced on 0.17.1 natively on aarch64-macos with the issue's `t.s` + `m.c`:
  `zig cc -target aarch64-macos m.c t.s -o repro2` succeeds, `llvm-objdump
  --macho --rebase repro2` errors as above, and running `./repro2` dies with
  exit 138 (SIGBUS).

## Root cause

`src/link/MachO/dyld_info/Rebase.zig:44-55` adds a rebase entry for every
8-byte `.unsigned` relocation of a live atom, without checking
`rel.meta.has_subtractor`. A SUBTRACTOR+UNSIGNED pair encodes `A - B`, which is
slide-independent and must not be rebased (`src/link/MachO/Atom.zig:700`
already resolves it as `S + A - SUB`).

`WeakBind.updateSize` in `src/link/MachO/dyld_info/bind.zig:308-321` has the
same omission: an 8-byte `.unsigned` extern relocation against a global weak
symbol gets a weak-bind entry even when it is the second half of a subtractor
pair, so dyld overwrites the difference with the symbol's address.

`Bind.updateSize` (`bind.zig:54-67`) likewise emits a bind for the pair's
`.unsigned` half when its target is imported. No fixup can be correct there:
an imported symbol has no address at link time. `Atom.scanRelocs`
(`src/link/MachO/Atom.zig:455`) never rejects a difference relocation
against an imported symbol, so the link succeeds and `resolveRelocInner`
writes `S + A - SUB` with the imported side's address taken as 0.

## Fix sketch

In `Rebase.updateSize` and `WeakBind.updateSize`, `continue` when
`rel.meta.has_subtractor` is set. In `Atom.scanRelocs`, report an error for
a `.subtractor` relocation or a `.unsigned` relocation with
`has_subtractor` whose extern target is imported, as ld64 does.

## Verification

Issue's `t.s`/`m.c`: no `__text` rebase entries, binary runs and returns 0.
`.quad _malloc - .` and `.quad . - _malloc`: link error.
`test/standalone/macho_subtractor` covers both.

## Fix

`src/link/MachO/dyld_info/Rebase.zig` and the `WeakBind` collector in
`src/link/MachO/dyld_info/bind.zig` now skip the `.unsigned` half of a
subtractor pair, as ld64 does for `diff64` fixups.

`Atom.scanRelocs` in `src/link/MachO/Atom.zig` now rejects a difference
relocation, on either side, whose target is imported, so the `Bind`
collector never sees one. The link fails with
`__TEXT$__text: 0x8: illegal difference relocation: imported symbol _malloc
does not have an address`. That is the same class of error as ld64's
`fixup error (kind=diff64) at '_main'+0x8 from im.o, target '_malloc' does
not have address`, worded like this linker's other relocation errors. ld64
rejects all four shapes the same way (diff64 and diff32, imported minuend
or subtrahend), and also under `-undefined dynamic_lookup`; so does the
fix. ld64.lld was not available on the machine to compare.

New standalone test `test/standalone/macho_subtractor` (native macOS only,
aarch64 or x86_64) links an assembly `.quad _extsym - .` and
`.quad _weaksym - .` in `__text`, against a global and a weak global
definition, and runs the result. With a compiler built from the line before
the fix it dies with SIGBUS on aarch64 natively and on x86_64 under Rosetta;
with the fix it exits 0 on both. (x86_64's assembler rejects an undefined
minuend, so the test defines both symbols in the assembly file.) The test
also links `.quad _malloc - .` and `.quad . - _malloc` for aarch64-macos on
any host and expects the new error. The base compiler links both without
error.

Verified with a compiler built from this checkout (`mise run build`):

- Issue's reproduction (`zig cc -target aarch64-macos m.c t.s`): before, the
  binary dies with SIGBUS (exit 138) and `llvm-objdump --macho --rebase`
  reports a bad offset; after, it exits 0, the rebase table is empty and
  `dyld_info -fixups` lists only the `__got` bind.
- The weak-definition variant: before (also with only the rebase half of the
  fix), SIGBUS and a malformed weak-bind table; after, exit 0 and an empty
  weak-bind table.
- Imported-symbol differences (`.quad`/`.long`, `_malloc - .` and
  `. - _malloc`): before, all four link; the `.quad _malloc - .` binary in
  `__data` prints malloc's address as the difference. After, all four fail
  with the new error.
- Plain absolute pointers (`.quad _extsym`, `.quad _w`, `.quad _malloc` in
  `__data`) still get their rebase, weak-bind and bind entries, and the
  program runs.
- A dylib built from the test's `aarch64.s` (exported global and weak
  minuends) links with no rebase, bind or weak-bind entry for the
  differences, and a program using it runs.
- x86_64 and aarch64 C++ exception programs (`__eh_frame` subtractor pairs)
  link and run.
- Other standalone tests that link on macOS pass with the fixed compiler:
  simple, extern, shared_library, global_linkage, mix_c_files, mix_o_files,
  static_c_lib, test_obj_link_run, load_dynamic_library, c_compiler, libcxx,
  dep_diamond.

## Notes

Unchanged on origin/master.
