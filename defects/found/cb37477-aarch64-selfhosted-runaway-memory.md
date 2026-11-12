---
title: The self-hosted aarch64 backend allocates without bound compiling a plain `main`
priority: 2
area: codegen
targets: [aarch64-linux-musl]
upstream: [codeberg#37477]
affects-line: yes
---

## Symptom

Compiling an empty program for aarch64 with the self-hosted backend never
finishes, and its memory grows until the machine runs out of memory and swap:

```
$ /usr/bin/time -l perl -e 'alarm shift; exec @ARGV' 20 \
    zig build-exe e.zig -target aarch64-linux-musl -fno-llvm
       20.22 real        46.62 user         2.85 sys
         19397476352  maximum resident set size
```

`e.zig` is `pub fn main() void {}`. Left alone, one such run reached 56 GB
in about four minutes before it was killed. `zig build-obj` on the same file
grows the same way (6.7 GB in 10 s), so the linker is not involved.
`export fn f() void {}` compiles in 0.13 s at 170 MB.

Do not reproduce this without a time limit.

## Evidence

- Reproduced on 0.17.1 (macOS aarch64 host) with the release binary, with
  the commands above.
- codeberg#37477 reports the same on an aarch64 Mac with `.use_llvm = false`
  in a `zig init` project, on 0.18.0-dev.738: the machine freezes.

## Root cause

Not investigated. Something reached from `std`'s start code or from
`main` sends the aarch64 backend into unbounded allocation.

## Fix sketch

Not investigated.

## Verification

The command in Symptom finishes, or fails with an error, within the time
limit and a bounded peak memory.

## Notes

- Found while checking which targets reach the self-hosted ELF linkers for
  elf-linker-bsd-archive-long-names. Without `-fno-llvm`, aarch64 uses LLVM
  and LLD; with it, this defect stops the build before linking.
