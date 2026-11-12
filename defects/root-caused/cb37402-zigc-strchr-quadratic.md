---
title: zigc strchr/strchrnul scan the whole string before searching (quadratic loops)
priority: 1
area: bundled-libc
targets: [x86_64-linux-musl, aarch64-linux-musl, riscv64-linux-musl, loongarch64-linux-musl, wasm32-wasi]
upstream: [codeberg#37402]
affects-line: yes
---

## Symptom

C code built with `zig cc` against the bundled musl or wasi-libc (the string
functions come from Zig's libzigc, `lib/c/string.zig:9`) gets `strchr` that costs O(strlen)
per call instead of O(distance to match). A loop such as
`for (p = s; (p = strchr(p, '\n')); p++) lines++;` over a 4 MiB string takes
46 s instead of a few ms with musl-gcc.

## Evidence

- Reported on 0.17.0 with `zig cc -O2 -target x86_64-linux-musl` (codeberg#37402),
  timings 2.8 s / 11 s / 46 s at 1, 2, 4 MiB versus <5 ms with musl-gcc.
- Not run here (Linux binary, macOS host). Faulty code read at 0.17.1.
- Labelled regression: musl's C `strchr` was replaced by the Zig version.

## Root cause

`lib/c/string.zig:135-141` (`strchr`) calls `std.mem.len` on the string, then
`std.mem.findScalar` on the full slice. `strchrnul` at `lib/c/string.zig:298-300`
does the same. musl's `src/string/strchr.c` is no longer in `lib/libc/musl`.

## Fix sketch

Scan byte by byte (or word-at-a-time) and stop at the first match or NUL; the
issue has a ready diff for `strchr`. Apply the same to `strchrnul` and audit
other functions in `lib/c/string.zig` that call `std.mem.len` first
(`strrchr` legitimately needs the length). Small.

## Verification

Run the reproduction from the issue under qemu or on a Linux host for
`x86_64-linux-musl`; 4 MiB should finish in milliseconds. Add a test that
`strchr` does not read past the first match (e.g. a match followed by an
unmapped page).

## Notes

origin/master still has the same `strchr`. Upstream fixed the analogous
`memchr`/`strnlen` issues (750006a823, 8f61a7d34a), which are in 0.17.1.
