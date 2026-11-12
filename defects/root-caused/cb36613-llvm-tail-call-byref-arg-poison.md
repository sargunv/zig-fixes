---
title: "@call(.always_tail) passes by-ref aggregate arguments as a pointer to the caller's stack, which LLVM folds to poison"
priority: 1
area: codegen
targets: [all]
upstream: [codeberg#36613]
affects-line: yes
---

## Symptom

Tail-calling a function that takes an aggregate by value gives the callee
garbage in release builds.

```zig
const Value = struct { y: u8 };
noinline fn def(value: Value) void { std.debug.print("{any}\n", .{value}); }
noinline fn abc(value: Value) void { @call(.always_tail, def, .{value}); }
pub fn main() void { abc(.{ .y = 8 }); }
```

Prints `.{ .y = 0 }` (reporter saw 255) instead of `.{ .y = 8 }` with
`-O ReleaseFast` or `ReleaseSafe`. This pattern is common in dispatch tables
and interpreters that use tail calls.

## Evidence

- codeberg#36613, reported on 0.17.0-dev.1767 and 0.16.0.
- Reproduced on 0.17.1, both `aarch64-macos` (native) and `x86_64-macos`
  (Rosetta), ReleaseFast and ReleaseSafe: prints `.{ .y = 0 }`.

## Root cause

For `.byref` / `.byref_mut` parameters, the call lowering copies the argument
into a fresh caller alloca and passes its address
(`src/codegen/llvm/FuncGen.zig:833-846`); the call is then marked `musttail`
(`FuncGen.zig:989`). LLVM's LangRef says a `tail`/`musttail` callee does not
access the caller's allocas unless they are passed as `byval`, so the
optimizer replaces the pointer with poison (the reporter's IR shows
`call @abc(ptr poison)`).

## Fix sketch

For `always_tail` calls, do not pass pointers to caller allocas: forward the
caller's own incoming by-ref parameter pointer when the argument is that
parameter, or pass the aggregate with a `byval` attribute, or give a compile
error. Needs care in the call lowering only. Not investigated further.

## Verification

Run the snippet above with `-O ReleaseFast`; it should print `.{ .y = 8 }`.
Add it as a behavior test under `test/behavior/call.zig`.

## Notes

Not fixed on origin/master as of this sweep.
