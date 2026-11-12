---
title: zig cc rejects -Wp, preprocessor options other than -MD/-MMD/-MT
priority: 1
area: zig-cc
targets: [all]
upstream: [codeberg#30734]
affects-line: yes
---

## Symptom

`zig cc -c foo.c -Wp,-DSOME_FLAG=1` fails with
`error: unsupported preprocessor arg: -DSOME_FLAG`. GCC and Clang forward
`-Wp,` arguments to the preprocessor; build systems that use it break under
`zig cc`.

## Evidence

- Reported on 0.14.0 (codeberg#30734).
- Reproduced on 0.17.1: `zig cc -target x86_64-linux-musl -c m.c -o m.o
  -Wp,-DSOME_FLAG=1` exits 1 with the message above.

## Root cause

`src/main.zig:3064-3076`: the `-Wp,` argument loop only accepts `-MD`, `-MMD`
and `-MT` (to manage depfiles) and calls `fatal("unsupported preprocessor
arg")` for everything else.

## Fix sketch

Pass unrecognized `-Wp,` arguments through to clang unchanged (re-join as
`-Wp,<args>` into `cc_argv`), keeping the special handling for depfile flags.
Small.

## Verification

`zig cc -c m.c -Wp,-DSOME_FLAG=1` compiles and `SOME_FLAG` is defined
(`#if SOME_FLAG != 1 #error #endif`).

## Notes

Related known entry `zig-cc-unknown-linker-args` covers `-Wl,` linker flags,
not `-Wp,`.
