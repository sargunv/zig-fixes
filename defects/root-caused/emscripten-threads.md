---
title: Multithreaded wasm32-emscripten programs do not compile (no page_allocator), and every spawned thread panics in sigaltstack
priority: 1
area: lib/std
targets: [wasm32-emscripten]
upstream: [github#22807]
affects-line: yes
---

## Symptom

Two independent defects, 2a and 2b, hit in sequence.

**2a, compile error.** Any multithreaded Emscripten build fails in every
optimize mode (Debug, ReleaseSafe, ReleaseFast, ReleaseSmall), because the
default panic handler reaches `std.heap.page_allocator`. `t.zig` spawns and
joins one `std.Thread` that calls `std.debug.print`:

```
$ zig build-obj t.zig -target wasm32-emscripten -mcpu=generic+atomics+bulk_memory -fno-single-threaded -OReleaseSafe
lib/std/heap.zig:18:74: error: unimplemented
pub const WasmAllocator = if (builtin.single_threaded) BrkAllocator else @compileError("unimplemented");
                                                                         ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
referenced by:
    page_allocator: lib/std/heap.zig:345:16
    arena: lib/std/debug.zig:1507:60
    getDebugInfoAllocator: lib/std/debug.zig:1509:13
    writeCurrentStackTrace: lib/std/debug.zig:731:74
    defaultPanic: lib/std/debug.zig:601:39
```

**2b, run-time panic.** With 2a worked around (root `os.heap.page_allocator = std.heap.c_allocator`),
the program links, but each spawned thread panics as it starts:

```
thread 345408 panic: attempt to unwrap error: Unexpected
Cannot print stack trace: debug info unavailable for target
worker: onmessage() captured an uncaught exception: RuntimeError: unreachable
```

Adding `pub const std_options: std.Options = .{ .signal_stack_size = null };`
fixes it: the program prints `in thread` then `done`.

## Evidence

- 2a reproduced on Zig 0.17.1 (macOS host; no emsdk needed for the compile
  error).
- 2b reproduced on Zig 0.17.1:
  - Built with `zig build-obj ... -OReleaseSafe` as above.
  - Linked with emsdk 6.0.13:
    `emcc -pthread -sPTHREAD_POOL_SIZE=2 -sALLOW_MEMORY_GROWTH t.o -o t.js`.
  - Run with Node 26.
  - Without `-sALLOW_MEMORY_GROWTH`, Zig's 16 MiB default thread stack aborts
    with OOM first.
- Of two probe programs (not kept), the plain one fails and the one with both
  overrides works.
- Both were first seen on Zig 0.17.0 (emsdk 4.0.10).
- Upstream: https://github.com/ziglang/zig/issues/22807 tracks the
  multithreaded wasm allocator. No upstream issue tracks `sigaltstack`.

## Root cause

Verified by reading code at 0.17.1.

**2a (std).**
- `lib/std/heap.zig:339-349` makes `page_allocator` the `WasmAllocator` for
  every `isWasm()` target, treating Emscripten like freestanding wasm.
- `WasmAllocator` (`heap.zig:18`) is either `BrkAllocator` (raw
  `@wasmMemoryGrow`, single-threaded only) or `@compileError("unimplemented")`.
- `std.debug.defaultPanic` (`lib/std/debug.zig:601`) calls
  `writeCurrentStackTrace`. That creates an arena from
  `getDebugInfoAllocator()` (`debug.zig:731`, which falls back to
  `page_allocator` at `:1505-1509`) before it checks `allow_stack_tracing` or
  debug-info support. Wasm has neither, so the arena is never needed.
- ReleaseFast also reaches it, through explicit `@panic` calls such as
  `lib/std/Io/Threaded.zig:13922`.
- Overriding `root.debug.getDebugInfoAllocator` alone makes the program
  compile in all three modes tested.

**2b (std).**
- `std.Thread`'s spawned-thread entry calls `maybeAttachSignalStack()`
  (`lib/std/Thread.zig:407`).
- That function skips only `.windows` and `.wasi` (`Thread.zig:1744-1764`), so
  it calls `posix.sigaltstack`.
- Emscripten's libc stub (`system/lib/libc/emscripten_libc_stubs.c:221-224`)
  sets `errno = ENOSYS` and returns -1.
- `posix.sigaltstack` (`lib/std/posix.zig:881-890`) maps that to
  `error.Unexpected`, which `Thread.zig:1763` treats as `unreachable`.
- The main thread is unaffected: Emscripten enters through `mainWithoutEnv`
  (`lib/std/start.zig:34`, `:757-775`), which never calls it.

**Latent defect (inferred from code, not reproduced).** Even single-threaded
Emscripten is unsafe:
- `BrkAllocator` grows linear memory with raw `memory.grow`.
- Emscripten's `sbrk` (`system/lib/libc/sbrk.c`) grows memory only when the
  new break passes the current heap size, and otherwise just advances its own
  break pointer.
- Once Zig has grown memory itself, Emscripten's break can walk into pages
  Zig handed out, so malloc and Zig's allocator would return overlapping
  memory.

origin/master: unchanged (verified). `heap.zig:18` and `:339-349`,
`debug.zig` (now around `:728` and `:1525-1535`), and `Thread.zig:1765-1773`
still exclude only Windows and WASI.

## Fix sketch

**2a:**
- Emscripten always links libc (`requiresLibC`, `lib/std/Target.zig:2317`).
  Add an `os.tag == .emscripten` case ahead of the `isWasm()` case in
  `page_allocator` and `wasm_allocator`.
- Back it with Emscripten's `posix_memalign`/`memalign` and `free` at
  `page_size` alignment. These are thread-safe under `-pthread`. Resize
  succeeds only when shrinking, and remap returns `null`. About 40–60 lines,
  or fewer by reusing `c_allocator`'s `posix_memalign` path.
- `PageAllocator` cannot be reused: it unmaps partial ranges, and Emscripten's
  `munmap` refuses partial unmapping (`emscripten_mmap.c:61-64`).
- This also removes the latent `sbrk` collision for Emscripten.
- Optional, a few lines: in `writeCurrentStackTrace`, create the arena only
  after the "can we trace at all" checks.
- The spinlock-around-`BrkAllocator` idea in github#22807 fixes WASI threads,
  but not the Emscripten `sbrk` conflict.

**2b:** about 1 line. Add `.emscripten` next to `.wasi` in
`maybeAttachSignalStack`. A sturdier fix, a few lines: have `posix.sigaltstack`
callers treat `ENOSYS` as "skip" instead of `unreachable`, which covers other
libcs that stub it.

Both are `lib/` changes, so a fork can ship them as a patched `--zig-lib-dir`.

## Verification

- `zig build-obj t.zig -target wasm32-emscripten -mcpu=generic+atomics+bulk_memory -fno-single-threaded -O{Debug,ReleaseSafe,ReleaseFast,ReleaseSmall}`
  compiles with no root overrides.
- `emcc -pthread -sPTHREAD_POOL_SIZE=2 -sALLOW_MEMORY_GROWTH t.o -o t.js && node t.js`
  prints `in thread` and `done`.
- For the latent defect: a single-threaded program that mixes heavy Zig
  `page_allocator` use with C `malloc` and checks for overlapping ranges.

## Notes

- A program can apply both overrides today from its root module: set
  `os.heap.page_allocator` (or `debug.getDebugInfoAllocator`) and
  `std_options.signal_stack_size = null`. A library cannot apply them for its
  users: every program's root module has to do it.
