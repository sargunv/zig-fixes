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

**2c, std's wasm allocators are unusable beside Emscripten's libc, even
single-threaded.** Any use of `std.heap.page_allocator`,
`std.heap.wasm_allocator`, `std.heap.brk_allocator`, or the types
`std.heap.WasmAllocator` and `std.heap.BrkAllocator`, that needs fresh memory
breaks the program. Portable code often picks `wasm_allocator` whenever
`builtin.cpu.arch.isWasm()`:

- Linked without `-sALLOW_MEMORY_GROWTH` (Emscripten's default), it fails
  every time, even with most of the heap free.
- Linked with `-sALLOW_MEMORY_GROWTH`, it succeeds, but the next write to
  stdout throws `TypeError: Cannot perform Construct on a detached
  ArrayBuffer` (an `Aborted(Assertion failed)` with Emscripten's assertions
  on), and the exit-time stack cookie check aborts.
- The memory it returns overlaps memory that C `malloc` returns later: the
  overlap probe under Verification reports 32 overlapping pairs out of 64
  `malloc` and 64 allocator blocks of 512 KiB, and 16 corrupted blocks, for
  each of these names.
- Multithreaded, `wasm_allocator` and `WasmAllocator` are the 2a compile
  error.

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
- On wasm, `BrkAllocator.allocBigPages` (`lib/std/heap/BrkAllocator.zig:168-174`)
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

**Every path to a raw `memory.grow` or `WasmAllocator` in std**, found by
searching `lib/` for `wasmMemoryGrow`, `WasmAllocator`, `BrkAllocator`,
`wasm_allocator`, `brk_allocator` and the `isWasm()` branches in `heap.zig`,
`heap/`, `Thread.zig`, `start.zig` and `debug.zig`. Line numbers are at
0.17.1.

| Place | Reachable on Emscripten? |
|---|---|
| `heap/BrkAllocator.zig:172`, `allocBigPages`: the only call to `@wasmMemoryGrow` in `lib/` | Yes, single-threaded, through every name below. |
| `heap.zig:18`, `pub const WasmAllocator` (`BrkAllocator` or `@compileError`) | Yes, by name. |
| `heap.zig:19`, `pub const BrkAllocator` | Yes, by name, single-threaded. Multithreaded it refuses to compile (`BrkAllocator.zig:14-16`), by design: it is documented as single-threaded only. |
| `heap.zig:339-349`, `page_allocator` | Yes, and std reaches it itself (the panic handler, see 2a). |
| `heap.zig:357-360`, `wasm_allocator` | Yes, by name. |
| `heap.zig:363-366`, `brk_allocator` | Yes, by name, single-threaded. |
| `start.zig:799`, `wasm_allocator` as `main`'s general-purpose allocator | No: only when not linking libc. Emscripten always links libc, so `start.zig:797` picks `c_allocator`. |
| `start.zig:809`, the arena backed by `gpa` on wasm | Uses that same `gpa`, `c_allocator` on Emscripten. |
| `lib/c/malloc.zig:45`, Zig's own libc `malloc` over `WasmAllocator` | No: Zig builds its libc only for static musl, wasi-libc and MinGW (`src/target.zig:480-482`), never for Emscripten. |
| `heap.zig:903`, `brk_allocator` in std's test block | Tests only. |
| `heap/debug_allocator.zig:97`, a 64 KiB page size on wasm | A constant; it grows nothing. |
| `heap.zig:128`, `:400`, `debug_allocator.zig:1199`, `:1372`: test skips on wasm | Tests only. |
| `Thread.zig`, `debug.zig` | No wasm allocator use. `debug.zig` reaches `page_allocator` only, covered above. |

## Fix sketch

The original sketch proposed a dedicated allocator over `posix_memalign` at
page alignment, with Emscripten cases ahead of the wasm cases in
`page_allocator` and `wasm_allocator`. Neither is needed:

- Both names, and Zig's own libc, reach memory only through `WasmAllocator`,
  so fixing `WasmAllocator` fixes all of them at once.
- `c_allocator` already handles any alignment on Emscripten (with `malloc`
  plus manual alignment, since `std.c` declares no `posix_memalign` there).
- `start.zig` already uses `c_allocator` as the general-purpose allocator for
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

2c, single-threaded: `overlap.zig` interleaves 64 `malloc` blocks and 64
blocks from the allocator under test, 512 KiB each, fills each with its own
byte, then counts overlapping pairs and blocks that lost their fill. Before
printing, it asks Emscripten to refresh its JS heap views, which otherwise
stay detached after a raw `memory.grow`, so it can print either way. Change
`probe` to `std.heap.wasm_allocator`, `std.heap.brk_allocator`, or
`.{ .ptr = undefined, .vtable = &std.heap.WasmAllocator.vtable }` to test the
other names.

```zig
const std = @import("std");

/// The allocator under test.
const probe: std.mem.Allocator = std.heap.page_allocator;

const Range = struct { start: usize, end: usize, tag: u8 };

/// Refreshes Emscripten's JS heap views, which a raw `memory.grow` leaves
/// detached, so the result can be printed either way.
extern fn emscripten_notify_memory_growth(memory_index: usize) void;

pub fn main() u8 {
    const n = 64;
    const size = 512 * 1024;
    var ranges: [2 * n]Range = undefined;
    var count: usize = 0;
    for (0..n) |i| {
        const m: [*]u8 = @ptrCast(std.c.malloc(size) orelse @panic("malloc failed"));
        const z = probe.alloc(u8, size) catch @panic("probe allocator failed");
        const mt: u8 = @intCast(2 * i % 251 + 1);
        const zt: u8 = @intCast((2 * i + 1) % 251 + 1);
        @memset(m[0..size], mt);
        @memset(z, zt);
        ranges[count] = .{ .start = @intFromPtr(m), .end = @intFromPtr(m) + size, .tag = mt };
        ranges[count + 1] = .{ .start = @intFromPtr(z.ptr), .end = @intFromPtr(z.ptr) + size, .tag = zt };
        count += 2;
    }
    emscripten_notify_memory_growth(0);
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
    std.debug.print("overlapping_pairs={d} corrupted_ranges={d}\n", .{ overlaps, corrupted });
    return @intFromBool(overlaps != 0 or corrupted != 0);
}
```

```sh
zig build-obj overlap.zig -target wasm32-emscripten -OReleaseSafe
emcc -sALLOW_MEMORY_GROWTH overlap.o -o overlap.js
node overlap.js    # fixed: overlapping_pairs=0 corrupted_ranges=0
```

The same file built with
`-mcpu=generic+atomics+bulk_memory -fno-single-threaded` and linked with
`emcc -pthread` checks the multithreaded case.

The suite can only compile for Emscripten: linking needs emcc and running
needs Node, so 2b and 2c have no test in upstream's suite. 2a has one:
`test/standalone/emscripten_threads` compiles a multithreaded Emscripten
object in all four optimize modes. Its thread allocates from
`page_allocator` and `wasm_allocator` by name, then prints. Run it alone with
`cd test/standalone/emscripten_threads && ZIG_LIB_DIR=<checkout>/lib zig build test`.

## Fix

Both changes in `lib/std/heap` route `WasmAllocator` through Emscripten's
libc allocator. `page_allocator` and `wasm_allocator` reach memory only
through `WasmAllocator` on wasm, so they need no change of their own.

- `lib/std/heap.zig`: in a multithreaded Emscripten build, `WasmAllocator` is
  a type with the same public declarations as `BrkAllocator` (`vtable` and
  `Error`), whose `vtable` is `c_allocator`'s. It was a compile error there.
  This fixes 2a for `page_allocator`, `wasm_allocator` and the type itself.
  Single-threaded builds and every other target keep `BrkAllocator` or the
  compile error, as before.
- `lib/std/Thread.zig`: `maybeAttachSignalStack` returns early on
  Emscripten, as it already does on WASI. Signals on Emscripten are never
  delivered asynchronously, so an alternate signal stack has no use there.
  This fixes 2b.
- `lib/std/heap/BrkAllocator.zig`: on Emscripten, `allocBigPages` takes its
  64 KiB-aligned big pages from `c_allocator` instead of `@wasmMemoryGrow`.
  This fixes 2c for every name: single-threaded, `page_allocator`,
  `wasm_allocator`, `brk_allocator`, and the two types are all
  `BrkAllocator`. `BrkAllocator` keeps big pages on its own free lists and
  never returns them, as before.
- `test/standalone/emscripten_threads`: the compile test for 2a, using
  `page_allocator` and `wasm_allocator` by name.

Verified with Zig 0.17.1 plus this line's `lib/`, emsdk 6.0.13 and Node
26.13, on macOS:

| Check | 0.17.1 `lib/` | This line |
|---|---|---|
| `t.zig`, multithreaded, all four modes | 2a compile error | prints `in thread`, `done`; exit 0 |
| `t.zig` with the 2a override, ReleaseSafe | 2b panic in the thread | (override not needed) |
| `overlap.zig`, single-threaded, for each of `page_allocator`, `wasm_allocator`, `brk_allocator` and `WasmAllocator.vtable` | `overlapping_pairs=32 corrupted_ranges=16`, each | `overlapping_pairs=0 corrupted_ranges=0`, each |
| `overlap.zig`, multithreaded, `page_allocator`, `wasm_allocator`, `WasmAllocator.vtable` | 2a compile error, each | 0 overlaps, 0 corrupted, each |
| `overlap.zig`, multithreaded, `brk_allocator` | compile error | unchanged, by design (single-threaded only) |
| `ArrayList` of 100000 items on `wasm_allocator`, then on `brk_allocator`, all four modes | `error: OutOfMemory` without memory growth; an abort with it | both sums correct, with and without memory growth |
| one 512 KiB `page_allocator` block, no memory growth | `panic: oom` | succeeds |
| same, with `-sALLOW_MEMORY_GROWTH` | next print aborts | succeeds |
| 4 threads, 200 rounds of `page_allocator` and `malloc` each, Debug and ReleaseFast | does not compile | 0 corrupted blocks |
| panic in a spawned thread, Debug | does not compile | prints `thread N panic: boom in thread` |
| single-threaded program using `init.gpa` and `init.arena`, all four modes | prints `st sum=4999950000` | same |
| `wasm32-wasi` and `wasm32-freestanding` programs using `page_allocator`, `wasm_allocator` and `brk_allocator`, all four modes | same output | same output; binaries byte-identical with `-fstrip` |
| `x86_64-linux-none` single-threaded program using `brk_allocator`, ReleaseSafe | – | binary byte-identical with `-fstrip` |
| `test/standalone/emscripten_threads` | fails (2a) | passes |
| `zig test lib/std/std.zig --test-filter heap`, macOS host | – | 147 passed |

## Notes

- Before this fix a program could work around 2a and 2b from its root
  module: set `os.heap.page_allocator` (or `debug.getDebugInfoAllocator`)
  and `std_options.signal_stack_size = null`. Those overrides still work.
- A first version of this fix made `page_allocator` itself `c_allocator`
  on Emscripten and left `wasm_allocator`, `brk_allocator` and the two
  types on raw `memory.grow`. Fixing `WasmAllocator` and `BrkAllocator`
  instead covers every name with less code.
- Multithreaded `wasm32-wasi` still does not compile, for the reason
  github#22807 tracks; this fix changes nothing there.
