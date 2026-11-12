---
title: The new ELF linker rejects an input whose `.eh_frame` is writable
priority: 3
area: linker
targets: [x86_64-linux-musl, x86_64-linux-gnu, x86_64-linux-ohos]
upstream: []
affects-line: yes
---

## Symptom

Linking an object with a writable (`SHF_WRITE | SHF_ALLOC`) `.eh_frame`
section with `-fnew-linker` fails:

```
$ zig build-exe e.zig crtbegin.o -target x86_64-linux-musl -fnew-linker
error: flags of section '.eh_frame' conflict with other inputs
    note: while parsing crtbegin.o
```

`e.zig` is `pub fn main() void {}`. The old linker links the same command.

The OpenHarmony SDK's `clang_rt.crtbegin.o` (SDK 7.0,
`native/llvm/lib/clang/15.0.4/lib/<triple>/`) has an empty `.eh_frame` with
flags `WA`, so `zig build-exe hello.zig -target x86_64-linux-ohos -lc
--libc <libc file> -fnew-linker` fails this way, dynamic or `-static`.

## Evidence

- Reproduced on 0.17.1 (macOS host) with the release binary, using a copy of
  the SDK's x86_64 `clang_rt.crtbegin.o` as `crtbegin.o` above.

## Root cause

The new linker creates its output `.eh_frame` read-only, under `.rodata`
(`src/link/Elf2.zig:6106`). Each input section is merged into the output
section of the same name, and `src/link/Elf2.zig:7014-7020` returns
`error.SectionFlagsConflict` when the input's `SHF_WRITE` differs from the
output section's. `src/link/Elf2.zig:7546-7553` skips such a section only if
it is not `SHF_ALLOC`; `.eh_frame` is, so the link fails.

## Fix sketch

Not investigated. Probably: accept a writable input `.eh_frame` into the
read-only output section, as `.eh_frame` is handled specially elsewhere.

## Verification

The command in Symptom links with `-fnew-linker`, and the result runs.

## Notes

- Found while verifying elf-linker-bsd-archive-long-names.
- Related: ohos-libc-support.
