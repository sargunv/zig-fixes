---
title: zig cc rejects linker flags it does not list, such as -Wl,--fix-cortex-a53-843419, instead of forwarding or ignoring them
priority: 1
area: zig-cc
targets: [aarch64-linux-gnu, aarch64-linux-musl, all]
upstream: []
affects-line: yes
---

## Symptom

```
$ zig cc --target=aarch64-linux-gnu -shared -o t.so x.c -Wl,--fix-cortex-a53-843419
error: unsupported linker arg: --fix-cortex-a53-843419
```

Since Rust 1.99, rustc passes `-Wl,--fix-cortex-a53-843419` when linking
aarch64 Linux build scripts. With `zig cc` as the linker (through cc-rs and
Cargo's linker setting), every Linux ARM64 build fails.

## Evidence

- Reproduced on Zig 0.17.1 (`zig cc` from a macOS host targeting
  `aarch64-linux-gnu`).
- No upstream issue found.

## Root cause

Verified by reading code at 0.17.1.
- `src/main.zig` translates `zig cc`'s `-Wl,`/`-Xlinker` arguments through a
  long explicit `if/else if` chain over known linker flags (about
  `src/main.zig:2600-3060`). Anything unlisted hits
  `fatal("unsupported linker arg: {s}", .{arg})` at `src/main.zig:3060`.
- `--fix-cortex-a53-843419` is not listed. Only the compiler-side
  `-mfix-cortex-a53-843419` exists, in `src/clang_options.zon:2552`.
- LLD supports the flag, and Zig drives LLD for ELF by default, so it could be
  forwarded.

origin/master: unchanged. Its `src/main.zig` still has no `fix-cortex` and
still ends in `unsupported linker arg` (line 3033), verified.

## Fix sketch

Two options:

1. **Add this flag (a few lines).** Map `--fix-cortex-a53-843419` to a new
   `link.Elf` option passed to LLD as `--fix-cortex-a53-843419` for aarch64.
   For the self-hosted ELF linker, ignore it with a warning.
2. **Change the policy (a few dozen lines).** Warn and ignore unknown linker
   flags instead of failing. That is more permissive, and it risks silently
   dropping flags that matter. A middle ground is an explicit allowlist of
   flags that are safe to ignore (erratum workarounds, `--sort-common`, which is
   already ignored at `src/main.zig:2664-2666`, and similar).

## Verification

- `zig cc --target=aarch64-linux-gnu -shared -o t.so x.c -Wl,--fix-cortex-a53-843419`
  succeeds.
- With option 1, `--verbose-link` shows the flag passed to `ld.lld`.
- Building a Rust crate with a build script for `aarch64-unknown-linux-gnu`,
  with `CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER` set to a `zig cc`
  wrapper, succeeds without filtering.

## Notes

- **Workaround today:** call `zig cc` through a wrapper that drops
  `-Wl,--fix-cortex-a53-843419` and `-Xlinker --fix-cortex-a53-843419`. That
  gives up the erratum fix, so it is acceptable only when the output never
  runs on affected Cortex-A53 cores.
- Related: `zig-cc-llvm-triples.md` is the other argument-filtering
  workaround in the same kind of wrapper.
