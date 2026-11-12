---
title: zig cc rejects the linker flag -Wl,--fix-cortex-a53-843419 instead of passing it to LLD
priority: 1
area: zig-cc
targets: [aarch64-linux-gnu, aarch64-linux-musl]
upstream: []
affects-line: yes
---

## Symptom

```
$ zig cc --target=aarch64-linux-gnu -shared -o t.so x.c -Wl,--fix-cortex-a53-843419
error: unsupported linker arg: --fix-cortex-a53-843419
```

`-Xlinker --fix-cortex-a53-843419` fails the same way. Toolchains that link
for AArch64 Linux commonly pass this flag, so with `zig cc` as the linker
driver every such link fails.

## Evidence

- Reproduced on Zig 0.17.1 (release binary) and on a compiler built from
  `fork/0.17.x` at `4cbe9c313b` (`0.17.1+fixes.4cbe9c313`), from a macOS host
  targeting `aarch64-linux-gnu`.
- No upstream issue found.

## Root cause

Verified by reading code at 0.17.1 and reproducing.
- `src/main.zig` translates `zig cc`'s `-Wl,`/`-Xlinker` arguments through a
  long explicit `if/else if` chain over known linker flags (about
  `src/main.zig:2600-3060`). Anything unlisted hits
  `fatal("unsupported linker arg: {s}", .{arg})` at `src/main.zig:3060`.
- `--fix-cortex-a53-843419` is not listed. Only the compiler-side
  `-mfix-cortex-a53-843419` exists, in `src/clang_options.zon:2552`.
- LLD supports the flag (`zig ld.lld --help` lists it). It has no negated
  form. LLD applies the workaround on AArch64 and rejects the flag for other
  machines with `--fix-cortex-a53-843419 is only supported on AArch64`. Zig
  drives LLD for ELF when linking C on most targets, so the flag can be
  forwarded there (`src/Compilation/Config.zig:386-427`). The exceptions use
  Zig's own ELF linkers, which do not implement the workaround: sparc64, which
  prefers the new linker, and Zig code built with a self-hosted backend.

origin/master: unchanged. Its `src/main.zig` still has no `fix-cortex` and
still ends in `unsupported linker arg` (line 3033), verified.

## Fix sketch

Map `--fix-cortex-a53-843419` to a new LLD ELF option and pass it to LLD as
`--fix-cortex-a53-843419`, in the same way `--emit-relocs` is plumbed. Where
the flag cannot reach LLD's ELF linker, fail instead of dropping it. Unknown
linker flags in general keep failing; changing that would be a policy change.

## Verification

- `zig cc --target=aarch64-linux-gnu -shared -o t.so x.c -Wl,--fix-cortex-a53-843419`
  succeeds, and `-v` shows the flag passed to `ld.lld`.
- Every other linker path either gives LLD's own error or gives Zig's error
  `--fix-cortex-a53-843419 is only supported when linking ELF with LLD`. See
  the table under Fix.
- `zig build test-cli`, run with the built compiler, includes two steps. One
  links an erratum 843419 sequence and checks that LLD emitted a
  `__CortexA53843419_` patch. The other checks the error for a Mach-O target.

## Fix

`--fix-cortex-a53-843419` is now accepted in `zig cc`'s linker argument
chain in `src/main.zig`, carried through `Compilation.CreateOptions`
(`linker_fix_cortex_a53_843419`, also added to the link cache hash) and
`link.File.OpenOptions` to `link.File.Lld.Elf`, and passed to LLD as
`--fix-cortex-a53-843419` in `src/link/Lld.zig`.

A user who asks for the workaround must not silently go without it. Once
the linker is known, `src/main.zig` fails with
`--fix-cortex-a53-843419 is only supported when linking ELF with LLD`
unless the output is ELF linked by LLD. Zig has no established convention
for options only LLD implements: they are silently ignored elsewhere (for
example `--hash-style`). The check follows the nearby pattern for options
tied to one object format (`manifest file is not allowed unless the target
object format is coff`).

Paths the flag can take. The reference linkers were LLD 15.0.4 (standalone,
for the MinGW driver and `ld64.lld`), driven by Homebrew clang 23.1.0 where
a driver applies, the system `ld` (ld-1266.8), and Zig's bundled LLD
(`zig ld.lld`, `zig wasm-ld`). "Before" is 0.17.1; "first fix" is
`3148aecf84` (forwarding only).

| Path | Reference | Before | First fix | Now |
|---|---|---|---|---|
| ELF, LLD, aarch64 | applies the workaround | unsupported linker arg | patched | patched (`__CortexA53843419_12000`) |
| ELF, LLD, x86_64 | error: only supported on AArch64 | unsupported linker arg | LLD's error | LLD's error |
| ELF, Zig's linker (`.zig` input for x86_64) | not applicable; LLD would reject | unsupported linker arg | silently dropped | error |
| ELF, Zig's new linker (sparc64, Elf2 by default) | LLD rejects (only AArch64) | unsupported linker arg | silently dropped | error |
| Mach-O | ld64 and ld64.lld: unknown option | unsupported linker arg | silently dropped | error |
| COFF, `*-windows-gnu` | MinGW LLD driver: unknown argument | unsupported linker arg | silently dropped | error |
| Wasm | wasm-ld: unknown argument | unsupported linker arg | silently dropped | error |

LLD does not treat the flag as a no-op on other ELF machines. It rejects it,
and forwarding keeps that behavior. `lld-link`, used directly, only warns
and ignores the flag. Zig fails for every COFF target anyway, because the
workaround cannot be applied there. `zig cc -c` on an ELF target still
accepts the flag without linking, just as clang ignores `-Wl,` when only
compiling.

A test in `test/tests.zig` (`addCliTests`) links an adrp at page offset 0xff8
followed by two loads with `zig cc -Wl,--fix-cortex-a53-843419` and checks
the output for LLD's `__CortexA53843419_` patch symbol. A second step checks
the error for `aarch64-macos`.

Verified with compilers built from `4cbe9c313b` (base), `3148aecf84` (first
fix) and this change:

- Each row of the table was run as `zig cc --target=<triple> -shared ...
  -Wl,--fix-cortex-a53-843419` with each compiler. The symptom command fails
  on the base with `unsupported linker arg` and links now, with
  `-Xlinker --fix-cortex-a53-843419 -v` showing the flag on the `ld.lld`
  command line. The erratum sequence gets the patch only with the flag.
- `zig build test-cli` (fresh cache): on the base, the forwarding step fails
  with `unsupported linker arg`. On the first fix, the Mach-O step fails
  because the build succeeds. Now 31/31 steps pass.
- `zig build test-link test-standalone` passes with the first fix, apart from
  two `run_cwd` checks that fail on this host because the cache directory sits
  behind the `/var` → `/private/var` symlink. They are unrelated to the
  linker. This change only adds a check in `src/main.zig` before the link.

## Notes

- **Workaround before this fix:** call `zig cc` through a wrapper that drops
  `-Wl,--fix-cortex-a53-843419` and `-Xlinker --fix-cortex-a53-843419`. That
  gives up the erratum fix, so it is acceptable only when the output never
  runs on affected Cortex-A53 cores.
- Related: `zig-cc-llvm-triples` is the other argument-filtering workaround
  in the same kind of wrapper.
