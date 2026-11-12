---
title: "@cVaArg with a struct type segfaults the compiler (LLVM backend), e.g. on wasm32"
priority: 1
area: codegen
targets: [wasm32-emscripten, wasm32-freestanding, x86_64-linux-gnu]
upstream: [codeberg#36522]
affects-line: yes
---

## Symptom

`@cVaArg(&ap, SomeExternStruct)` makes the compiler die with SIGSEGV (`error:
process terminated with signal SEGV` under `zig build`). This happens on
wasm32 for any struct. The reporter reached it through translate-c'd headers
that pass `va_list*` to a Zig callback reading a struct argument.

## Evidence

- codeberg#36522 (0.17.0-dev.1543, wasm32-freestanding ReleaseSmall).
- Reproduced on 0.17.1 with `zig build-obj` of a variadic export doing
  `_ = @cVaArg(&ap, Info)`:
  - `Info = extern struct { x: c_int }` or `{ p: ?*anyopaque }`,
    `-target wasm32-emscripten`: exit 139 (SIGSEGV).
  - The issue-style form, `export fn guess(va: *std.lang.VaList)` with
    `@cVaArg(va, extern struct { callback: ?*const fn () callconv(.c) void })`:
    SIGSEGV on wasm32-freestanding (Debug and ReleaseSmall),
    wasm32-emscripten, and x86_64-linux with `-fllvm`.
  - Scalar types (`c_int`, function pointers) compile fine. aarch64-macos
    compiles fine. aarch64-linux gives a compile error ("disabled due to
    miscompilations").

## Root cause

`src/codegen/llvm/FuncGen.zig:1152` `airCVaArg` emits LLVM's `va_arg`
instruction directly with the lowered Zig type. LLVM's `va_arg` does not
support aggregates on most targets; clang lowers aggregate `va_arg` itself in
its frontend, following each target's ABI. On wasm32, for example, the
variadic area holds a pointer to the struct. The segfault is most likely
inside LLVM (a guess; not confirmed with a debugger).

## Fix sketch

In `airCVaArg`, lower aggregate (and other non-scalar) types the way clang
does for each target: read a pointer-sized slot and load through it when the
ABI passes the value indirectly, or advance the `va_list` by hand. Until then,
report a compile error instead of crashing. Medium size: per-ABI logic.

## Verification

`zig build-obj -target wasm32-emscripten` of the snippet above should
compile, and a C caller passing a struct through `...` should read correct
values at runtime.

## Notes

Related: `std.lang.VaList` disables varargs on aarch64-linux with LLVM
("disabled due to miscompilations").
