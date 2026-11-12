---
title: Initializing a void field of an extern union crashes the compiler
priority: 1
area: compiler
targets: [all]
upstream: [codeberg#37046]
affects-line: yes
---

## Symptom

Initializing a zero-bit (`void`) field of an `extern union` in a `const`
local crashes the compiler with SIGSEGV and no message:

```zig
pub const A = extern union { a: void, b: u32 };
pub fn main() !void {
    const a: A = .{ .a = {} };
    _ = a;
}
```

## Evidence

- Reported on 0.17.0-dev.2384. alexrp's debug trace: assertion failure in
  `resolveComptimeKnownAllocPtr`, called from `zirMakePtrConst`.
- Reproduced on 0.17.1: `zig build-exe repro.zig` exits 139 on aarch64-macos
  (LLVM) and with `-target x86_64-linux` (self-hosted backend).

## Root cause

`src/Sema.zig:3501` asserts `stores.len > 0` for a comptime-known const
alloc. The union field-pointer path at `src/Sema.zig:27297-27305` emits
`set_union_tag` (which records a store) only for `.auto` layout, and the
zero-bit field store itself is elided, so an `extern` union initialised
through an OPV field records no stores. A commenter (Iris95) diagnosed the
same thing; `packed` unions escape only because the union itself becomes OPV.

## Fix sketch

Record a store entry for the OPV-field/extern-union case (or make
`resolveComptimeKnownAllocPtr` treat zero recorded stores on a non-OPV type as
"not comptime-known" instead of asserting). Small; needs care in the
store-replay logic around `src/Sema.zig:3510-3560`.

## Verification

The repro compiles and runs. Add a behavior test that initialises a `void`
field of an `extern union` in a `const` and a `var`.

## Notes

Relevant to bindings that model C unions with placeholder `void` members.
