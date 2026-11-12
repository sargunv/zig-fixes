---
title: Unlabeled break inside inline for within a runtime loop crashes liveness analysis
priority: 1
area: compiler
targets: [all]
upstream: [codeberg#35351]
affects-line: yes
---

## Symptom

The compiler segfaults on this ordinary-looking code:

```zig
fn foo() void {
    for (0..10) |i| {
        inline for (.{ 1, 2, 3 }) |_| {
            mock_continue: {
                if (i < 5) break :mock_continue;
                break;
            }
        }
    }
}
pub fn main() !void { foo(); }
```

All three of the runtime condition, the labeled break, and the unlabeled
`break` (which targets the `inline for`) are needed.

## Evidence

- Reported on 0.17.0-dev.305. alexrp's trace: `attempt to use null value` in
  `Air.Liveness.resolveLoopLiveSet`.
- Reproduced on 0.17.1: `zig build-exe repro.zig` exits 139 on aarch64-macos,
  and `-fllvm -target x86_64-linux` also exits 139.

## Root cause

The crash is at `src/Air/Liveness.zig:1110`:
`a.special.fetchRemove(inst).?` finds no recorded break set for the loop.
That suggests Sema emits malformed AIR for a runtime-conditional unlabeled
`break` out of an unrolled `inline for` body nested in a runtime loop. This is
a guess; the Sema side was not investigated.

## Fix sketch

Not investigated.

## Verification

The repro compiles and runs. Add it as a behavior test, also with the
`break` replaced by `continue`.

## Notes

Workaround from the reporter: break to an explicit label outside the
`inline for` instead of using an unlabeled `break`. Related:
github#23522.
