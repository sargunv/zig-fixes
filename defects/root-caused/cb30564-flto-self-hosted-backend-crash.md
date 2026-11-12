---
title: -flto with a self-hosted default backend crashes the compiler in link.File.open
priority: 1
area: compiler
targets: [x86_64-linux-gnu, x86_64-linux-musl]
upstream: [codeberg#30564]
affects-line: yes
---

## Symptom

Requesting LTO for a Zig compilation that would otherwise use a self-hosted
backend (Debug on x86_64-linux) crashes the compiler with no message:

```sh
zig build-exe -flto main.zig -target x86_64-linux   # SIGSEGV
```

In `build.zig` this is `want_lto = true` (or `lto = .full`) on a Debug
executable. The issue originally reported `-flld` without `-fllvm`. That case
now gives a proper error ("self-hosted backends do not support linking with
LLD"), but the `-flto` variant from the comments still crashes, even with
explicit `-fno-llvm`.

## Evidence

- Reported on 0.16.0-dev.1484 (`-flld`) and 0.17.0-dev.864 (`-flto`); the
  trace is the assertion `comp.zcu == null or comp.config.use_llvm` in
  `link.File.open`.
- Reproduced on 0.17.1 from aarch64-macos: `zig build-exe -flto minimal.zig
  -target x86_64-linux` exits 139. `zig build-exe -flld ... -target
  x86_64-linux` now correctly errors.

## Root cause

In `src/Compilation/Config.zig:398-401`, a requested LTO mode forces
`use_lld = true` before the check at lines 405-408 that rejects LLD with a
ZCU on a self-hosted backend. The `use_llvm` decision (lines 320-370) never
looks at `options.lto`. `src/link.zig:541` and `:565` then assert.

## Fix sketch

In the `use_llvm` block, treat LTO like `any_sanitize_thread`: if LTO is
requested and a ZCU exists, force LLVM (or error if `-fno-llvm`). Also
apply mlugg's suggestion of a final check after both decisions: `have_zcu and
!use_llvm and use_lld` should be an error. Small.

## Verification

`zig build-exe -flto x.zig -target x86_64-linux` either builds with LLVM or
gives a clean error. `-fno-llvm -flto` gives a clean error.

## Notes

Unchanged on `origin/master`.
