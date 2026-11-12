---
title: Mach-O release links drop custom __TEXT sections from static libraries (JSC __jsc_int)
priority: 1
area: linker
targets: [aarch64-macos, x86_64-macos, aarch64-ios]
upstream: [codeberg#31607]
affects-line: likely
---

## Symptom

Linking WebKit's static JavaScriptCore into a Zig executable with
`-OReleaseFast`/`-OReleaseSafe` produces a binary that crashes (SIGSEGV/SIGBUS)
in the LLInt interpreter. The `(__TEXT,__jsc_int)` section (350 KB, flags
`S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS`) from
`LowLevelInterpreter.cpp.o` is absent from the output; `__DATA,__jsc_opcodes`
survives. Apple ld keeps it. `-ODebug` works.

## Evidence

- Reported on 0.15.2, macOS 15.7 arm64, WebKit JSCOnly static build
  (codeberg#31607). No small reproduction.
- Not reproduced here.

## Root cause

Not investigated. Release-only suggests dead stripping
(`src/link/MachO/dead_strip.zig`) removes the section because nothing reaches
it through symbol references (JSC addresses it relatively); ld64 may keep such
sections differently. Guess, unverified.

## Fix sketch

Not investigated. First step: reproduce with a small asm object that defines a
custom `__TEXT` section only reached through section-relative relocations, and
compare `-dead_strip` behavior with ld64.

## Verification

JSC test program from the issue prints `Result: hello` when linked by Zig with
ReleaseFast; or the small asm reproduction keeps the section.

## Notes

Workaround: link with Apple's clang/ld, or disable gc sections (unconfirmed).
