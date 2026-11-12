---
title: std.heap.WasmAllocator is a compile error in multithreaded wasm32-emscripten builds, although Emscripten's libc provides a thread-safe allocator
priority: 2
area: lib/std
targets: [wasm32-emscripten]
upstream: [github#22807]
affects-line: yes
---

## Symptom

Code that names the type `std.heap.WasmAllocator` does not compile for
multithreaded Emscripten. One example is an `Allocator` built from
`&std.heap.WasmAllocator.vtable`:

```
$ zig build-obj p.zig -target wasm32-emscripten -mcpu=generic+atomics+bulk_memory -fno-single-threaded
lib/std/heap.zig:18:74: error: unimplemented
pub const WasmAllocator = if (builtin.single_threaded) BrkAllocator else @compileError("unimplemented");
```

Code that uses the values `std.heap.wasm_allocator` or
`std.heap.page_allocator` compiles and works on this line; see
emscripten-threads.

## Evidence

- Reproduced on this line after emscripten-threads was fixed, with Zig 0.17.1
  and this line's `lib/`. The probe builds an `Allocator` from
  `&std.heap.WasmAllocator.vtable`.
- Single-threaded, the same probe compiles, links with emsdk 6.0.13 and runs
  correctly on Node 26.13, because emscripten-threads made `BrkAllocator`
  take its big pages from Emscripten's libc.
- Upstream: github#22807 tracks the missing multithreaded `WasmAllocator` on
  every wasm target.

## Root cause

- `lib/std/heap.zig:18` defines the public type `WasmAllocator` as
  `BrkAllocator` when single-threaded and `@compileError("unimplemented")`
  otherwise, on every target.
- `BrkAllocator` (`lib/std/heap/BrkAllocator.zig:14-16`) refuses to compile
  when not single-threaded: its free lists are unsynchronized globals.

## Fix sketch

Not carried here. Making the type usable needs `WasmAllocator` to name a
different type in the multithreaded Emscripten case, with a public `vtable`
(and `Error`, to match `BrkAllocator`). The obvious candidate,
`c_allocator_impl`, is private and its `vtable` is not `pub`. Either change
adds public API surface, which this fork does not carry. Upstream's general
fix for github#22807 (a thread-safe `WasmAllocator`) would cover this.

The values most code uses, `std.heap.wasm_allocator` and
`std.heap.page_allocator`, are already `c_allocator` on Emscripten, so naming
the type is the only remaining trigger.

## Verification

The command under Symptom compiles, and the program links with
`emcc -pthread` and runs.

## Notes

- Related: emscripten-threads.
- `std.heap.BrkAllocator` and `std.heap.brk_allocator` are documented as
  single-threaded only, so their compile error in multithreaded builds is by
  design and not part of this entry.
