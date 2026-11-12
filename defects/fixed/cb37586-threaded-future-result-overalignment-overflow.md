---
title: Io.Threaded Future allocation is too small when the result is over-aligned, corrupting the heap
priority: 1
area: lib/std
targets: [all]
upstream: [codeberg#37586]
affects-line: yes
---

## Symptom

`io.concurrent` (or `io.async` on a threaded `Io`) with a result type whose
alignment exceeds `@alignOf(Future)` (for example `align(16)`) writes the result
past the end of the Future's allocation. Awaiting it panics in `SafeAllocator`:
`free of invalid memory [... len: 1696 (0x6a0) align: 8] or corrupted metadata`.
Without a checking allocator, the heap is silently corrupted.

## Evidence

- codeberg#37586 (reported on 0.17.0, 0.17.1 and 0.18.0-dev.935, on Linux
  x86_64 and macOS arm64). The reporter says the code worked on 0.16.
- Reproduced on 0.17.1, aarch64-macos: the issue's `future-alignment.zig` (a
  14×u64 extern context, a `[1520]u8 align(16)` result, two concurrent
  futures awaited in turn) run with `zig run` panics with the message above
  at `Io/Threaded.zig:706` in `Future.destroy`.

## Root cause

`lib/std/Io/Threaded.zig:666` `Future.create` sizes the allocation with
`worst_case_result_offset = result_alignment.forward(worst_case_context_offset + context.len)`
(line 676). That aligns an offset counted from zero, as if the base address
were aligned to `result_alignment`. The allocation is only aligned to
`@alignOf(Future)`, and the real result address is aligned from the absolute
address (line 683). The result can therefore start up to
`result_alignment - @alignOf(Future)` bytes later than the size assumes. The
context offset adds `max_context_misalignment` to cover this case; the result
offset has no matching slack.

## Fix sketch

Add `result_alignment.toByteUnits() -| @alignOf(Future)` (the worst-case
result misalignment) to the result offset before computing `alloc_len`, as is
already done for the context. Alternatively, allocate with
`max(@alignOf(Future), context_alignment, result_alignment)`. A few lines.
`Task.create` (line 502) handles only a context, which already has its slack.

## Verification

Run the issue's reproduction with `zig run` (Debug, SafeAllocator); it should
exit cleanly. Add a std test that awaits several futures with `align(16)` and
`align(64)` results.

## Fix

`Future.create` in `lib/std/Io/Threaded.zig` now adds
`max_result_misalignment = result_alignment.toByteUnits() -| @alignOf(Future)`
before aligning the worst-case result offset, mirroring the slack it already
adds for the context. The allocation's base is aligned to `@alignOf(Future)`,
so its address modulo the result alignment is at most that slack, and the real
result offset can no longer exceed the computed one.

The test `concurrent with overaligned result` in `lib/std/Io/test.zig` spawns
two concurrent futures with a 112-byte context and a 1520-byte result aligned
to 16 and then 64, and checks the results. Without the fix it panics in
`SafeAllocator` with `free of invalid memory [... len: 1696 (0x6a0) align: 8]
or corrupted metadata` on aarch64-macos; with it, it passes. A standalone copy
of the issue's reproduction also passes with
`zig test repro.zig --zig-lib-dir lib`.

`Group.Task.create` carries only a context, which already has its slack. The
`Uring`, `Dispatch` and `Kqueue` backends lay futures out differently (on a
fiber, with an assert on `Fiber.max_result_align`) and do not share this
arithmetic.

## Notes

As of this sweep, origin/master has the same code at
`lib/std/Io/Threaded.zig:684`, so it is not fixed upstream.
