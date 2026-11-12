---
title: C++ exceptions bypass catch(...) with full LTO on x86_64-windows-gnu
priority: 1
area: zig-cc
targets: [x86_64-windows-gnu]
upstream: [codeberg#36412]
affects-line: likely
---

## Symptom

With `-flto=full`, an `int` thrown in one TU and caught with `catch (...)` in
another terminates the program:
`libc++abi: terminating due to uncaught exception of type ...`.
Without LTO it prints "still alive!" as expected.

```sh
zig c++ -target x86_64-windows-gnu -flto=full -O1 -c -o core.o core.cpp
zig c++ -target x86_64-windows-gnu -flto=full -O1 -c -o main.o main.cpp
zig c++ -target x86_64-windows-gnu -flto=full -O1 -o repro.exe core.o main.o
```

## Evidence

- Reported on 0.17.0-dev.1454 (codeberg#36412). Reporter says upstream clang
  22.1.7 works, but tested only `x86_64-pc-windows-msvc` (no MinGW sysroot), so
  Zig's bundled MinGW/libc++/libunwind setup is not ruled out.
- Not reproduced here (needs a Windows host to run).

## Root cause

Not investigated. Possibly related: LTO + MinGW already misbehaves in
codeberg#31958 (weak libzigc symbols), see `cb31958-mingw-lto-zigc-undefined.md`.

## Fix sketch

Not investigated.

## Verification

Run the three commands above and execute `repro.exe` on Windows (or Wine);
expect "still alive!".

## Notes

Maintainers asked for an upstream-clang comparison; none with a MinGW target
yet.
