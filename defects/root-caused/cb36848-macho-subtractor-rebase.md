---
title: Mach-O linker emits a rebase for SUBTRACTOR+UNSIGNED pairs, corrupting __text
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

## Fix sketch

In `Rebase.updateSize`, `continue` when `rel.meta.has_subtractor` is set. Check
the bind/weak-bind collectors in `src/link/MachO/dyld_info/bind.zig:54,308` for
the same omission. A few lines.

## Verification

Issue's `t.s`/`m.c`: no `__text` rebase entries, binary runs and returns 0.
Add a `test/link/macho.zig` case with a `sym - .` quad in `__text`.

## Notes

Unchanged on origin/master.
