---
title: zig cc parses `-u symbol` as a flag plus an input file
priority: 1
area: zig-cc
targets: [all]
upstream: [codeberg#30613]
affects-line: yes
---

## Symptom

`zig cc test.c -o test -u __llvm_profile_runtime` fails with
`error: __llvm_profile_runtime: unrecognized file extension`. `-Wl,-u,sym`
works. Breaks Rust coverage builds and Bazel `hermetic_cc_toolchain`
(uber/hermetic_cc_toolchain#243).

## Evidence

- Reported in codeberg#30613 (no version given; links master source).
- Reproduced on 0.17.1: `zig cc -target x86_64-linux-musl m.c -o m -u foo_sym`
  prints `error: foo_sym: unrecognized file extension`.

## Root cause

`src/clang_options.zon:268-272` has the MSVC/clang-cl `/u` entry
(`.name = "u"`, `.psl = true`, default `.flag` syntax) mapped to
`.force_undefined_symbol`. The matcher in `src/main.zig:5460-5468` walks the
table in order and takes the first `.flag` match, so `-u` hits this entry
before the GNU `joined_or_separate` entry at `src/clang_options.zon:5130-5134`,
leaving the symbol name as a positional argument.

## Fix sketch

Drop the `ze = .force_undefined_symbol` mapping from the clang-cl `u` entry
(it means "undefine all macros" there, not a linker option), or make
`tools/update_clang_options.zig` not attach it to the `psl` variant, then
regenerate. Small.

## Verification

`zig cc m.c -o m -u foo_sym` links (with `foo_sym` undefined-forced, e.g.
via `-Wl,--trace-symbol`), and `-ufoo_sym` also works.

## Notes

Still present on origin/master (`src/clang_options.zon:274`).
