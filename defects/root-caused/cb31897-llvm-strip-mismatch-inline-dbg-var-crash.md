---
title: LLVM backend segfaults when an unstripped module's inline function is inlined into a stripped module
priority: 1
area: codegen
targets: [all]
upstream: [codeberg#31897]
affects-line: yes
---

## Symptom

The compiler crashes (segfault in release builds of Zig; "index out of bounds"
in `std/zig/llvm/Builder.zig` in debug builds of Zig) while generating a
function in a stripped module that inlines a function from a module with debug
info. Smallest trigger, from a comment on the issue:

```zig
// dep.zig
pub inline fn f(_: u8) void {}
// main.zig
export fn g() void { @import("dep").f(0); }
```

`zig build-obj -fllvm --dep dep -fstrip -Mroot=main.zig -fno-strip -Mdep=dep.zig`
prints `Segmentation fault`. In `zig build`, this happens when modules of one
compilation set `.strip` differently, which is common when only some modules
are built `strip = optimize != .Debug`.

## Evidence

- codeberg#31897, reported on 0.16.0 and 0.17.0-dev.9; minimal reproduction
  posted on 0.17.0-dev.2384.
- Reproduced on 0.17.1, aarch64-macos: the command above exits 139 (SIGSEGV)
  both in Debug and with `-OReleaseFast`.
- Debug builds on x86_64-linux hide it only because they default to the
  self-hosted backend; `-fllvm` crashes too.

## Root cause

`src/codegen/llvm/FuncGen.zig:651` (`genBodyDebugScope`) returns early when
`self.wip.strip` is set, so no debug file or scope is set up for the inlined
body. The inlined callee comes from an unstripped module, so its AIR still
contains `dbg_var_val` / `dbg_arg_inline` / `dbg_var_ptr`. These are lowered
by `airDbgVarPtr` (`:2458`) and `airDbgVarVal` (`:2491`) with no strip check.
They build debug-variable metadata and `dbg.declare` calls against the missing
scope, which ends in an out-of-bounds global index (trace in the issue:
`Builder.zig:2349` from `airDbgVarVal`).

## Fix sketch

Per the commenter: at the top of `airDbgVarPtr` and `airDbgVarVal`, add
`if (self.wip.strip) return .none;`. Two lines. An alternative is to stop Sema
from emitting debug-variable AIR for inlined bodies when the destination
function is stripped.

## Verification

Run the two-file `build-obj` command above; it should succeed. Add it as a
standalone test with mixed `strip` modules under `-OReleaseSmall` and `-fllvm`.

## Notes

origin/master still has no strip check in `airDbgVarPtr`/`airDbgVarVal`.
Workaround: give every module in the compilation the same `strip` value.
