---
title: Switch on enum field of a packed struct inside inline-else prong crashes the compiler
priority: 1
area: compiler
targets: [all]
upstream: [codeberg#35448]
affects-line: yes
---

## Symptom

`inline else` over a packed struct enumerates every backing-integer value,
including bit patterns that are not valid tags of a non-exhaustive-looking
enum field. Switching on that field in the prong segfaults the compiler:

```zig
const S = packed struct {
    v: enum(u1) { a },
    pub fn init() S { return .{ .v = .a }; }
};
pub fn main() !void {
    switch (S.init()) {
        inline else => |s| switch (s.v) { .a => {} },
    }
}
```

## Evidence

- Reported on 0.16.0 and 0.17.0-dev.340. Debug compiler trace: assertion
  `switch exhaustion check wrong` in `resolveSwitchBlock`.
- Reproduced on 0.17.1: `zig build-exe repro.zig` exits 139, both with the
  default backend and with `-fllvm`.

## Root cause

`src/Sema.zig:11769` asserts that a comptime-known switch operand matched some
prong or there is an else/`_` prong. A comptime-known enum value extracted
from a packed struct can hold an invalid tag (here `@enumFromInt(1)`), so no
prong matches and the assertion fails.

## Fix sketch

Per mlugg in the issue: when comptime field access of a bitpack yields a value
that is not a valid enum tag, return `undefined` instead (then the switch
reports branch-on-undefined). Alternative from justusk: a comptime
"switch on corrupt value" error. Small to medium.

## Verification

The repro must compile (or give a clean compile error). Add a compile-error
or behavior test for `inline else` over a packed struct with an enum(u1) {a}
field.

## Notes

Related: codeberg#35486 (`@bitCast` can create the same invalid comptime enum
values).
