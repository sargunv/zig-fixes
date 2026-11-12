---
title: SmpAllocator never reuses blocks freed on another thread's slot, so RSS grows without bound (also zig libc malloc)
priority: 1
area: lib/std
targets: [all]
upstream: [codeberg#36969, codeberg#36533]
affects-line: yes
---

## Symptom

A program where one thread allocates small blocks and another frees them (or
where threads are created and destroyed often) keeps mapping new 64 KiB slabs
while freed blocks pile up on other slots' free lists. RSS grows linearly even
though live bytes stay flat. Because `lib/c/malloc.zig` wraps `SmpAllocator`,
C/C++/Rust code linked with `zig cc` against the bundled musl (static) gets the
same leak-like growth from plain `malloc`/`free`.

## Evidence

- codeberg#36969 (Zig 0.17.0-dev.2294 and 0.17.0; 0.16.0 reported via
  cargo-zigbuild on x86_64-linux-musl). A commenter measured a two-thread
  producer/consumer ring: 1 MB to 609 MB in 30 s with `smp_allocator`, and
  0.6 MB to 866 MB for the equivalent C program built with
  `zig cc -target aarch64-linux-musl -static`; glibc malloc stays flat.
- Reproduced on 0.17.1 (aarch64-macos, ReleaseFast): the reporter's ring repro
  bounded to 20M alloc/free pairs, with at most 1024 x 400 B live, reached
  193 MB maximum RSS (`/usr/bin/time -l`).

## Root cause

`lib/std/heap/SmpAllocator.zig:200-216`: `free` pushes the block onto the free
list of whichever slot the freeing thread currently holds, not the slot that
allocated it. `alloc` (`lib/std/heap/SmpAllocator.zig:132-174`) looks at its
own free list, its bump region, then tries only `max_alloc_search` neighbour
slots before mapping a fresh slab. Small-class slabs are never unmapped and
nothing rebalances between slots, so a steady cross-thread pattern grows the
consumer slot's free list forever. `lib/c/malloc.zig:44-47` selects
`SmpAllocator` as libc `malloc` for multi-threaded non-wasm targets.

## Fix sketch

Route frees back to the owning slot (upstream PR codeberg#36294 does this; the
issue thread reports it makes both the Zig and the `zig cc` musl repros flat).
Size: moderate, confined to `SmpAllocator.zig`.

## Verification

Run the ring repro above (Zig and C versions, the latter with
`zig cc -target x86_64-linux-musl -static`) on a multi-core host; RSS should
stay flat at a few MB.

## Notes

- Not fixed on `origin/master` as of this sweep; PR #36294 is unmerged.
- Related: codeberg#36269 (SmpAllocator spins without bound on its slot locks
  and holds a slot lock across `PageAllocator.map`), same file.
- Reported workaround: pin Zig 0.15.2, or link another malloc.
