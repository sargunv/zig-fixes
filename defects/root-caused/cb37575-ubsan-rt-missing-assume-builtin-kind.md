---
title: ubsan_rt does not know clang's AssumePassedFalse builtin check, giving a wrong or invalid-enum panic
priority: 1
area: zig-cc
targets: [all]
upstream: [codeberg#37575]
affects-line: yes
---

## Symptom

C code with a false `__builtin_assume(...)`, compiled by `zig cc` in Debug
(where UBSan is on), reports `passing zero to clz(), which is not a valid
argument` in a C-only build. In a build that also contains Zig code, the
handler panics with `invalid enum value` inside ubsan_rt instead of reporting
the real check. The reporter hit it in libdispatch code pulled in by an SDL iOS
build.

## Evidence

- codeberg#37575 (0.18.0-dev.935). Minimal trigger:
  `int main(int argc, char **argv) { __builtin_assume(argc == 7); return 0; }`.
- A maintainer (ubsan_rt author) confirmed the variant was missed. Not
  reproduced (the C-only symptom needs a runtime check); faulty code read at
  0.17.1.

## Root cause

`lib/ubsan_rt.zig:542` `InvalidBuiltinData.kind` is `enum(u8) { ctz, clz }`.
LLVM's `BuiltinCheckKind` also has `BCK_AssumePassedFalse = 2`, which clang
emits through `__ubsan_handle_invalid_builtin`. `invalidBuiltin` (line 552)
calls `@tagName(data.kind)` on value 2.

## Fix sketch

Add a third tag `assume` and make `invalidBuiltin` print an
"assumption is violated" message for it, matching compiler-rt. The commenter
also notes `TypeDescriptor` lacks `TK_BitInt`; consider adding it too. Small
change.

## Verification

Build the C snippet above with `zig cc -O0` (or `addExecutable` with C
sources in Debug), run it with no extra args, and expect an
assumption-violated panic message.

## Notes

As of this sweep, origin/master `lib/ubsan_rt.zig` has no `assume` variant,
so it is not fixed upstream.
