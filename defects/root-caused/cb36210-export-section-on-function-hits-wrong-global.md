---
title: "@export of a function with .section reads the wrong union field and puts an unrelated variable in that section"
priority: 1
area: codegen
targets: [all]
upstream: [codeberg#36210]
affects-line: yes
---

## Symptom

```zig
pub noinline fn get_myva() linksection(".map.getva") callconv(.c) u64 { ... }
comptime { @export(&get_myva, .{ .name = "get_myva", .section = ".map.getva" }); }
export var exp1: ?*const fn () callconv(.c) void = null;
// ... exp2..exp7
```

In the reporter's project the LLVM IR shows an unrelated variable placed in
the function's section:
`@code.exp3 = private unnamed_addr global ptr null, section ".map.getva"`.
Which variable is hit depends on internal indices, so it looks random.

## Evidence

- codeberg#36210, reported on 0.17.0-dev.1282; full reproduction lives in an
  external repository (not fetched).
- Faulty code read at 0.17.1 (below). My small single-file reductions on
  0.17.1 (`-femit-llvm-ir`, 7 to 300 exported variables, extra functions
  before the exported one) did not show a variable with the section, so the
  symptom was not reproduced here; it depends on index collisions.

## Root cause

`src/codegen/llvm.zig:1209-1216` (`addGlobalExport`):

```zig
if (exp.opts.section.toSlice(ip)) |section_slice| {
    const variable = &llvm_global.ptrConst(&o.builder).kind.variable;
    variable.setSection(...);
}
```

`kind` is a tagged union (`lib/std/zig/llvm/Builder.zig:3392`) and is
`.function` for a function export. In the release-built compiler this reads
the `Function.Index` as a `Variable.Index`, so `setSection` writes to whatever
variable has that index (or out of bounds). A safety-checked compiler build
would panic here instead.

## Fix sketch

Switch on `kind`: `.variable` -> `Variable.setSection`, `.function` ->
`Function.setSection` (exists at `Builder.zig:3708`/`:5374`), `.alias` ->
resolve the aliasee. A few lines.

## Verification

Build a Debug (safety-checked) compiler and compile the snippet: it must not
panic, and `-femit-llvm-ir` must show the section only on `get_myva`.

## Notes

Same code on origin/master (`llvm.zig:1046`).
