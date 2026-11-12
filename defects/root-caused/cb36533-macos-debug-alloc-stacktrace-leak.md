---
title: Debug-mode default allocator leaks memory on every allocation on macOS
priority: 1
area: lib/std
targets: [aarch64-macos, x86_64-macos]
upstream: [codeberg#36533]
affects-line: yes
---

## Symptom

In Debug builds on macOS, a loop that allocates and frees with `init.gpa`
(the safety-checking `SafeAllocator`) grows resident memory without bound.
Using `std.Io.Threaded` with `Group.async` in a loop leaks too.

## Evidence

- codeberg#36533, reported on 0.16 and 0.17.0-dev.1770 (aarch64-macos); does
  not reproduce on x86_64-linux.
- Reproduced on 0.17.1, aarch64-macos, Debug: 200 000 alloc/free pairs of
  1 MiB through `init.gpa`, printing `getrusage` maxrss every 50 000. Output
  went 3, 18, 34, 49 MiB, about 330 bytes lost per pair.

## Root cause

Diagnosed by a commenter (marximimus), not by a maintainer: the leaked memory
comes from capturing stack traces for each allocation. Two parts:

1. A missing `.deinit` on the stack-trace path (the commenter opened a PR).
2. `lib/std/debug/SelfInfo/MachO.zig:35` and the other callers use
   `std.debug.getDebugInfoAllocator()`, which by default is a global
   `ArenaAllocator` (`lib/std/debug.zig:1500`). MachO.zig frees what it
   allocates, but an arena only reclaims the most recent allocation, so the
   memory is never returned.

The exact allocation per capture was not traced here.

## Fix sketch

Make the Mach-O unwinder use a real general-purpose allocator for
short-lived allocations, or keep per-capture scratch in a stack buffer, and
add the missing `deinit`. A commenter reports that returning
`smp_allocator` from a root `debug.getDebugInfoAllocator` override removes
the leak.

## Verification

Run the loop above for 200 000 iterations; maxrss should stay flat.

## Notes

Workaround: override `root.debug.getDebugInfoAllocator`. Not checked
whether the commenter's PR landed on `origin/master`; no matching commit in
`git log` for MachO.zig.
