---
title: Multithreaded wasm32-emscripten programs do not compile (no page_allocator), and every spawned thread panics in sigaltstack
priority: 1
area: lib/std
targets: [wasm32-emscripten]
upstream: [github#22807]
affects-line: yes
---

## Symptom

Two independent defects, 2a and 2b, hit in sequence. A third, 2c, hits
single-threaded programs too.

`t.zig` spawns and joins one `std.Thread` that prints:

```zig
const std = @import("std");

fn worker() void {
    std.debug.print("in thread\n", .{});
}

pub fn main() !void {
    const t = try std.Thread.spawn(.{}, worker, .{});
    t.join();
    std.debug.print("done\n", .{});
}
```

**2a, compile error.** Every multithreaded Emscripten build fails in every
optimize mode (Debug, ReleaseSafe, ReleaseFast, ReleaseSmall), because the
default panic handler reaches `std.heap.page_allocator`:

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
thread 345376 panic: attempt to unwrap error: Unexpected
Cannot print stack trace: debug info unavailable for target
worker: onmessage() captured an uncaught exception: RuntimeError: unreachable
```

Adding `pub const std_options: std.Options = .{ .signal_stack_size = null };`
fixes it: the program prints `in thread` then `done`.

**2c, `page_allocator` is unusable beside Emscripten's libc, even
single-threaded.** Any use of `std.heap.page_allocator` that needs fresh
memory breaks the program:

- Linked without `-sALLOW_MEMORY_GROWTH` (Emscripten's default), it fails
  every time, even with most of the heap free.
- Linked with `-sALLOW_MEMORY_GROWTH`, it succeeds, but the next write to
  stdout throws `TypeError: Cannot perform Construct on a detached
  ArrayBuffer` (an `Aborted(Assertion failed)` with Emscripten's assertions
  on), and the exit-time stack cookie check aborts.
- The memory it returns overlaps memory that C `malloc` returns later: the
  overlap probe under Verification reports 32 overlapping pairs out of 64
  `malloc` and 64 `page_allocator` blocks of 512 KiB, and corrupted contents.

## Evidence

- 2a reproduced on Zig 0.17.1 in all four optimize modes (macOS host; no
  emsdk needed for the compile error).
- 2b and 2c reproduced on Zig 0.17.1:
  - 2b: built with `zig build-obj ... -OReleaseSafe` as above.
  - 2b: linked with emsdk 6.0.13 as
    `emcc -pthread -sPTHREAD_POOL_SIZE=2 -sALLOW_MEMORY_GROWTH t.o -o t.js`.
  - Run with Node 26.13.
  - 2c: probes below, built single-threaded (the wasm default).
  - Without `-sALLOW_MEMORY_GROWTH`, Zig's 16 MiB default thread stack
    does not fit Emscripten's default 16 MiB initial memory, so the thread
    aborts with OOM before reaching 2b. That is a link setting, not a defect.
- Both were first seen on Zig 0.17.0 (emsdk 4.0.10).
- Upstream: https://github.com/ziglang/zig/issues/22807 tracks the
  multithreaded wasm allocator. No upstream issue tracks `sigaltstack` or
  2c.

## Root cause

Verified by reading code at 0.17.1.

**2a (std).**
- `lib/std/heap.zig:339-349` makes `page_allocator` the `WasmAllocator` for
  every `isWasm()` target, treating Emscripten like freestanding wasm.
- `WasmAllocator` (`heap.zig:18`) is either `BrkAllocator` (single-threaded
  only) or `@compileError("unimplemented")`.
- `std.debug.defaultPanic` (`lib/std/debug.zig:601`) calls
  `writeCurrentStackTrace`. That creates an arena from
  `getDebugInfoAllocator()` (`debug.zig:731`, which falls back to
  `page_allocator` at `:1505-1509`) before it checks `allow_stack_tracing` or
  debug-info support. Emscripten has no self debug-info support, so on it the
  arena is never needed.
- ReleaseFast also reaches it, through explicit `@panic` calls such as
  `lib/std/Io/Threaded.zig:13922`.

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

**2c (std).**
- On wasm, `BrkAllocator.allocBigPages` (`lib/std/heap/BrkAllocator.zig:174-180`)
  grows linear memory with a raw `@wasmMemoryGrow`.
- Emscripten owns linear memory. Its `sbrk` (`system/lib/libc/sbrk.c`)
  grows memory only when the new break passes the current memory size, and
  otherwise just advances its own break pointer. Once Zig has grown memory
  itself, `malloc`'s break walks into the pages Zig handed out.
- Emscripten's JS side caches typed-array views of the memory buffer and
  refreshes them only when memory grows through its own
  `emscripten_resize_heap`. A raw `memory.grow` detaches the old buffer, so
  every later JS access to the heap (stdout, the stack cookie check) fails.
- Without `-sALLOW_MEMORY_GROWTH` the memory's maximum equals its initial
  size, so every `memory.grow` fails.

The original entry called 2c latent and unreproduced; it is real, and the
stale JS views make it fail sooner than the overlap does.

## Fix sketch

The original sketch proposed a dedicated allocator over `posix_memalign` at
page alignment. That is not needed: `page_allocator` on wasm never
guaranteed page-aligned blocks (`BrkAllocator` hands out small size classes),
and `c_allocator` already handles any alignment on Emscripten (with `malloc`
plus manual alignment, since `std.c` declares no `posix_memalign` there).
`start.zig` already uses `c_allocator` as the general-purpose allocator for
every libc-linked wasm program, and Emscripten always links libc
(`requiresLibC`, `lib/std/Target.zig:2317`).

## Verification

Tools: Zig 0.17.1 (`mise install`), emsdk 6.0.13, Node 26. Add
`--zig-lib-dir <checkout>/lib` to `zig build-obj` to test this line's
library.

2a and 2b, with `t.zig` above, for each of `Debug`, `ReleaseSafe`,
`ReleaseFast` and `ReleaseSmall`:

```sh
zig build-obj t.zig -target wasm32-emscripten -mcpu=generic+atomics+bulk_memory -fno-single-threaded -O$mode
emcc -pthread -sPTHREAD_POOL_SIZE=2 -sALLOW_MEMORY_GROWTH t.o -o t.js
node t.js    # prints "in thread" then "done"
```

2c, single-threaded: `overlap.zig` interleaves 64 `malloc` and 64
`page_allocator` blocks of 512 KiB, fills each with its own byte, then counts
overlapping pairs and blocks that lost their fill. Since printing fails
while 2c is present, it also reports through the exit code: the low bits
count overlapping pairs, and bit 7 is set if any block is corrupted.

```zig
const std = @import("std");

const Range = struct { start: usize, end: usize, tag: u8 };

/// Printing fails while page_allocator grows memory behind Emscripten.
const can_print = std.heap.page_allocator.vtable != &std.heap.BrkAllocator.vtable;

pub fn main() u8 {
    const n = 64;
    const size = 512 * 1024;
    var ranges: [2 * n]Range = undefined;
    var count: usize = 0;
    for (0..n) |i| {
        const m: [*]u8 = @ptrCast(std.c.malloc(size) orelse @panic("malloc failed"));
        const z = std.heap.page_allocator.alloc(u8, size) catch @panic("page_allocator failed");
        const mt: u8 = @intCast(2 * i % 251 + 1);
        const zt: u8 = @intCast((2 * i + 1) % 251 + 1);
        @memset(m[0..size], mt);
        @memset(z, zt);
        ranges[count] = .{ .start = @intFromPtr(m), .end = @intFromPtr(m) + size, .tag = mt };
        ranges[count + 1] = .{ .start = @intFromPtr(z.ptr), .end = @intFromPtr(z.ptr) + size, .tag = zt };
        count += 2;
    }
    var overlaps: usize = 0;
    for (ranges[0..count], 0..) |a, i| {
        for (ranges[i + 1 .. count]) |b| {
            if (a.start < b.end and b.start < a.end) overlaps += 1;
        }
    }
    var corrupted: usize = 0;
    for (ranges[0..count]) |r| {
        const p: [*]const u8 = @ptrFromInt(r.start);
        for (p[0 .. r.end - r.start]) |byte| {
            if (byte != r.tag) {
                corrupted += 1;
                break;
            }
        }
    }
    if (can_print) std.debug.print("ranges={d} overlapping_pairs={d} corrupted_ranges={d}\n", .{ count, overlaps, corrupted });
    return @as(u8, @intCast(@min(overlaps, 127))) | @as(u8, @intFromBool(corrupted != 0)) << 7;
}
```

```sh
zig build-obj overlap.zig -target wasm32-emscripten -OReleaseSafe
emcc -sALLOW_MEMORY_GROWTH -sASSERTIONS=0 -sSTACK_OVERFLOW_CHECK=0 overlap.o -o overlap.js
node overlap.js; echo "exit=$?"
```

The suite can only compile for Emscripten: linking needs emcc and running
needs Node, so 2b and 2c have no test in upstream's suite. 2a has one:
`test/standalone/emscripten_threads` compiles `t.zig` as a multithreaded
Emscripten object in all four optimize modes. Run it alone with
`cd test/standalone/emscripten_threads && ZIG_LIB_DIR=<checkout>/lib zig build test`.

## Fix

- `lib/std/heap.zig`: on Emscripten, `page_allocator` is `c_allocator`,
  ahead of the generic wasm case. This fixes 2a and 2c together. A root
  `os.heap.page_allocator` override still wins.
- `lib/std/Thread.zig`: `maybeAttachSignalStack` returns early on
  Emscripten, as it already does on WASI. Signals on Emscripten are never
  delivered asynchronously, so an alternate signal stack has no use there.
  This fixes 2b.
- `test/standalone/emscripten_threads`: the compile test for 2a.

Verified with Zig 0.17.1 plus this line's `lib/`, emsdk 6.0.13 and Node
26.13, on macOS:

| Check | 0.17.1 `lib/` | This line |
|---|---|---|
| `t.zig`, multithreaded, all four modes | 2a compile error | prints `in thread`, `done`; exit 0 |
| `t.zig` with the 2a override, ReleaseSafe | 2b panic in the thread | (override not needed) |
| `overlap.zig`, single-threaded | exit 160: 32 overlapping pairs, corrupted | `overlapping_pairs=0 corrupted_ranges=0`; exit 0 |
| one 512 KiB `page_allocator` block, no memory growth | `panic: oom` | succeeds |
| same, with `-sALLOW_MEMORY_GROWTH` | next print aborts | succeeds |
| 4 threads, 200 rounds of `page_allocator` and `malloc` each, Debug and ReleaseFast | does not compile | 0 corrupted blocks |
| panic in a spawned thread, Debug | does not compile | prints `thread N panic: boom in thread` |
| single-threaded program using `init.gpa` and `init.arena`, all four modes | prints `st sum=4999950000` | same |
| `wasm32-wasi` and `wasm32-freestanding` programs using `page_allocator`, all four modes | same output | same output; binaries byte-identical with `-fstrip` |
| `test/standalone/emscripten_threads` | fails (2a) | passes |

## Notes

- Before this fix a program could work around 2a and 2b from its root
  module: set `os.heap.page_allocator` (or `debug.getDebugInfoAllocator`)
  and `std_options.signal_stack_size = null`. Those overrides still work.
- `std.heap.wasm_allocator` and `std.heap.brk_allocator` still grow memory
  with a raw `memory.grow`, so on Emscripten they have the same problem as
  2c when a program picks them by name. They are explicit requests for that
  allocator, std does not reach them on its own on Emscripten, and changing
  what they return is beyond this fix.
- Multithreaded `wasm32-wasi` still does not compile, for the reason
  github#22807 tracks; this fix changes nothing there.
