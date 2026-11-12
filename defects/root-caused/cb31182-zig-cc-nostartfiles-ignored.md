---
title: zig cc ignores -nostartfiles and still links its own crt1.o, so callers that supply startup files get duplicate _start
priority: 1
area: zig-cc
targets: [all]
upstream: [codeberg#31182, github#5320]
affects-line: yes
---

## Symptom

When `zig cc` is the linker driver and the caller passes its own startup
objects with `-nostartfiles`, Zig links its own `crt1.o` as well. The link
fails:

```
zig: warning: argument unused during compilation: '-nostartfiles'
ld.lld: error: duplicate symbol: _start
>>> defined at crt1.c   .../zig/o/<hash>/crt1.o
>>> defined at mycrt.c:3  mycrt.o
```

The reported case is Rust with `zig cc -target x86_64-linux-musl` as its C
toolchain for a static musl build. rustc passes its self-contained
`rcrt1.o`/`crti.o` with `-nostartfiles -static-pie`, which collides on
`_start` and `_start_c`.

## Evidence

- codeberg#31182 (0.15.2; a comment confirms 0.16.0), follow-up to
  github#5320.
- Reproduced on 0.17.1 from aarch64-macos, cross to x86_64-linux-musl:
  `zig cc -target x86_64-linux-musl -c mycrt.c` (defines `_start`), then
  `zig cc -target x86_64-linux-musl -static -nostartfiles mycrt.o m.c` fails
  with the duplicate-symbol error above. `-nostartfiles` with only `m.c` links
  and the output still contains Zig's `_start`/`_start_c`.

## Root cause

`src/clang_options.zon:3176` lists `.{ .name = "nostartfiles" }` with no `.ze`
mapping, so `src/main.zig`'s `zig cc` argument loop forwards it to clang (which
warns that it is unused) and never records it. Nothing tells the linker to
drop the libc startup files (`musl crt1.o`/`rcrt1.o`, glibc `Scrt1.o`, …;
see the `CrtFile` list in `src/Compilation.zig:1227`).

## Fix sketch

Add a `.ze = .nostartfiles` mapping, handle it in `src/main.zig` by setting a
"no startup files" option, and have the ELF (and other) linkers skip the crt
objects when it is set, while still linking libc itself. Moderate: a new
option threaded from `main.zig` through `Compilation` to the link step.

## Verification

The two-object command above should link with only one `_start`. Add a
standalone test that links a custom `_start` with `-nostartfiles`, and build a
Rust `x86_64-unknown-linux-musl` crate statically with `zig cc` as linker.

## Notes

origin/master still has no mapping for `nostartfiles`. Workaround:
`-C target-feature=-crt-static`, which gives up static linking. A second
comment on the issue reports a different collision (`__umodti3` from Rust
`compiler_builtins` vs Zig `compiler_rt` with lld-link); that is not covered
here.
