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

segfaults. Hit in practice by Rust crates using aws-lc-rs via cargo-zigbuild
for `x86_64-apple-darwin`.

## Evidence

- Reported on 0.15.2 and 0.16.0-dev.2535 (codeberg#31189); maintainer trace:
  `assert(new_len <= self.items.len)` in `shrinkAndFree` from
  `src/link/MachO/UnwindInfo.zig:130 in generate`.
- Reproduced on 0.17.1 on aarch64-macos: exit 139 for both
  `-target x86_64-macos-none` and `-target aarch64-macos-none`. Without
  `-fvisibility=hidden` or without `-O3` it links.

## Root cause

`src/link/MachO/UnwindInfo.zig:116-131`: the record folding loop starts with
`i = 0` and ends with `info.records.shrinkAndFree(gpa, i + 1)`. When there are
no unwind records (the only function is hidden and dead-stripped), this
"shrinks" an empty list to length 1, which is illegal behavior; in release
builds of Zig it corrupts memory and segfaults.

## Fix sketch

Skip folding when `info.records.items.len == 0` (or guard the shrink). One line.

## Verification

The reproduction above produces `mre.dylib`; add a `test/link/macho.zig` case
for a dylib with no live functions.

## Notes

Same code on origin/master.
