---
title: switch (ptr.*) with pointer captures loads the whole tagged union, racing with other threads
priority: 1
area: compiler
targets: [all]
upstream: [codeberg#36982, github#23509]
affects-line: likely
---

## Symptom

`switch (self.*) { .active => |*payload| { payload.mutex.lock(); ... } }`
emits a `memcpy` of the whole union just to read its tag. Under
`-fsanitize-thread`, TSAN reports data races between that copy and another
thread writing the payload under its mutex. The copy reads memory the
program never reads semantically, which is UB in the LLVM IR; ReleaseFast
happened to remove it. Large unions also pay for the copy on every switch.

## Evidence

- codeberg#36982 (0.16), labeled regression, milestone Urgent. A commenter's
  godbolt link shows 0.15.2 did not emit the copy.
- Not reproduced (needs TSAN on Linux); the 0.16 report and a comment
  describing current AIR suggest 0.17.1 is affected.

## Root cause

According to commenters, Sema lowers the switch operand as `load` of the
whole union followed by `get_union_tag`, because `get_union_tag` accepts
values only. The same pattern, with a TODO, appears in union field-access
safety checks at `src/Sema.zig:27308`. The switch-specific site in
`analyzeSwitchBlock` (`src/Sema.zig:10097`) was not pinpointed.

## Fix sketch

A commenter is adding a `get_union_tag_ptr` AIR instruction (pointer to union
in, pointer to tag out) and having Sema emit `get_union_tag_ptr` + `load` for
`switch_block_ref`. Every backend needs to lower it. Medium size.

## Verification

Build the issue's program with `zig run -fsanitize-thread -fllvm -lc` on
Linux; there should be no TSAN reports. Check that the LLVM IR for
`Device.read` loads only the tag.

## Notes

Upstream treats this as Urgent.
