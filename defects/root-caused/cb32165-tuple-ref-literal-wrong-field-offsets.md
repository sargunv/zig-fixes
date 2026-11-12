---
title: "&.{...}" coerced to a pointer-to-tuple stores runtime fields at array-element offsets, corrupting the tuple
priority: 1
area: compiler
targets: [all]
upstream: [codeberg#32165]
affects-line: yes
---

## Symptom

Valid code miscompiles when an address-of tuple literal with at least one
runtime-known element gets a pointer-to-tuple result type:

```zig
pub fn main() u8 {
    var a: *const [5:0]u8 = "hello";
    _ = &a;
    const b: *const struct { *const [5:0]u8, *const [5:0]u8 } = &.{ a, a };
    return if (b[0] == a and b[1] == a) 0 else 1;
}
```

This exits 1. Printing `b[0]` segfaults in Debug and prints garbage in
ReleaseFast. Binding the literal to a `T` value first and taking `&v` works.

## Evidence

- codeberg#32165 (0.17.0-dev.215). The reporter took it for an unsafe
  coercion (`*const @Tuple(&.{[]const u8})` from `&.{"hello"}`). The element
  coercions are in fact valid; the crashes come from this miscompile.
- Reproduced on 0.17.1, aarch64-macos: the program above exits 1 in Debug and
  ReleaseFast. The issue's `@Tuple(&.{ []const u8, []const u8 })` variant
  panics in Debug with `programmer bug caused syscall error: FAULT`.
- The emitted LLVM IR stores element 0 at `getelementptr [1 x i8], ptr, 0`
  and element 1 at `getelementptr [1 x i8], ptr, 1`, that is at byte offsets
  0 and 1 rather than 0 and 8.

## Root cause

`src/Sema.zig:19409-19420` (`zirArrayInit`, `is_ref` with a tuple result
type) addresses each field with `block.addPtrElemPtr(base_ptr, index, ...)`
(`:19417`). `ptr_elem_ptr` indexes an array-like pointee by element size; it
is not valid on a pointer to a struct. The LLVM backend lowers it in
`airPtrElemPtr` (`src/codegen/llvm/FuncGen.zig:2309`) with the stride of
`indexableElem`, which for a tuple pointer is not the field layout.

## Fix sketch

In the tuple branch, compute the field pointer with a struct field pointer
(`struct_field_ptr` through the existing tuple field-pointer helper) instead of
`addPtrElemPtr`. Small change in one function.

## Verification

Add the program above as a behavior test (runtime-known elements, `&.{...}`
with a pointer-to-tuple result type, fields of different sizes) and check all
optimize modes and backends.

## Notes

origin/master still uses `addPtrElemPtr` in this branch. Passing `&.{ x, y }`
with runtime `x: u32, y: u64` to a parameter typed `*const struct { u32, u64 }`
also reads back wrong values on 0.17.1 (checked).
