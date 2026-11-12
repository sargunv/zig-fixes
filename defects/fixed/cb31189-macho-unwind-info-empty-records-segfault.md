---
title: zig cc segfaults linking a macOS dylib with no unwind records (-shared -fvisibility=hidden -O3)
priority: 1
area: linker
targets: [x86_64-macos, aarch64-macos, aarch64-ios]
upstream: [codeberg#31189, github#25400]
affects-line: yes
---

## Symptom

```sh
echo 'const char* a() { return ""; }' > mre.c
zig cc -target x86_64-macos-none -fvisibility=hidden -shared -O3 mre.c -o mre.dylib
```

segfaults with the release binary (exit 139). A ReleaseSafe compiler panics
with `reached unreachable code` in `link.MachO.UnwindInfo.generate`.
`zig build-lib -dynamic -OReleaseFast` of the same source fails the same way.

## Evidence

- Reported on 0.15.2 and 0.16.0-dev.2535 (codeberg#31189); maintainer trace:
  `assert(new_len <= self.items.len)` in `shrinkAndFree` from
  `src/link/MachO/UnwindInfo.zig:130 in generate`.
- Reproduced on 0.17.1 on aarch64-macos: exit 139 for both
  `-target x86_64-macos-none` and `-target aarch64-macos-none`. Without
  `-fvisibility=hidden` or without `-O3` it links.
- Reproduced with a ReleaseSafe compiler built from this line
  (`0.17.1+fixes.4cbe9c313`): exit 134, panic in `UnwindInfo.generate`.

## Root cause

`src/link/MachO.zig:1587-1592` (`initSyntheticSections`) creates
`__unwind_info` when any input object has unwind records, whether or not they
survive dead stripping. In the reproduction the only function is hidden and
unreferenced, so `-dead_strip` (on by default for optimized builds) removes
it, and `UnwindInfo.generate` collects no live records. Two places there
assume at least one:

- `src/link/MachO/UnwindInfo.zig:116-131`: the folding loop starts with
  `i = 0` and ends with `info.records.shrinkAndFree(gpa, i + 1)`, which asks
  to "shrink" an empty list to length 1. That trips the
  `new_len <= self.items.len` assertion; with safety off it corrupts memory
  and segfaults.
- `src/link/MachO/UnwindInfo.zig:348-349`: `write` computes the sentinel
  index entry from `info.records.items[info.records.items.len - 1]`, which
  underflows on an empty list.

Apple's ld omits `__unwind_info` when there are no live records.

## Fix sketch

Decide `__unwind_info` from live records, as Apple's ld does. Dead stripping
(`dead_strip.gcAtoms`) has already run when `initSyntheticSections` creates
the synthetic sections, and `addAtomsToSections` later adds exactly the live
atoms of each object, so "a live atom has a live unwind record" is true
exactly when `generate` will collect a record. `__eh_frame` is only useful
with `__unwind_info` (its creation asserts that), so it is decided under the
same condition. About fifteen lines in `MachO.zig` and `Object.zig`.

## Verification

The reproduction above produces `mre.dylib` with no `__unwind_info`, like
Apple's ld. `zig build` in `test/standalone/macho_empty_unwind_info` passes
with a compiler built from the line.

## Fix

`src/link/MachO.zig`: `initSyntheticSections` creates `__unwind_info` only
when some object has a live atom with a live unwind record (new
`Object.hasLiveUnwindRecords`), and creates `__eh_frame` only when
`__unwind_info` is created. When every unwind record is dead stripped, both
sections are now omitted, as Apple's ld does, and `UnwindInfo` never sees an
empty record list. Links with any live record produce the same output as
before.

Checked with a compiler built with the fix, against Apple's ld on the same
inputs (aarch64-macos host, macOS 26.6):

- The reproduction links for `x86_64-macos` and `aarch64-macos`. Neither has
  `__unwind_info`, matching Apple's output. Both `dlopen` (x86_64 under
  Rosetta).
- The reproduction plus an exported assembly `call_cb` with a frame record
  and no CFI (still no live unwind records): `dlopen`, then calling
  `call_cb` with a callback that runs `backtrace()`, finds the `call_cb`
  frame in the dylib. A C++ exception thrown through that frame terminates,
  as it does with Apple's ld, because the frame has no unwind info.
- Same with CFI on `call_cb` (one live record, one dead): `__unwind_info` is
  kept, `objdump --unwind-info` shows the same layout as Apple's (one page,
  one record, encoding `0x04000000`), and the exception is caught.
- `dyld_info -validate_only` reports nothing and `dyld_info -fixups` lists
  only the usual `dyld_stub_binder` bind for every output. `codesign -v`
  passes after ad-hoc signing.

New test `test/standalone/macho_empty_unwind_info` cross-links the
reproduction as a ReleaseFast dylib for `aarch64-macos` and `x86_64-macos`.
With release 0.17.1 both links fail with SEGV; with the fix both succeed.
`test-standalone` passes with the built compiler.

## Notes

Same code on origin/master.
