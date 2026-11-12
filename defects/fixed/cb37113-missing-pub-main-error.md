---
title: A missing or private `main` on Darwin reports an ELF auxv error from start.zig instead of saying `main` must be `pub`
priority: 2
area: lib/std
targets: [x86_64-macos, aarch64-macos, aarch64-maccatalyst, aarch64-ios, aarch64-tvos, aarch64-visionos, aarch64-watchos]
upstream: [codeberg#37113]
affects-line: yes
---

## Symptom

On a Darwin target, an executable whose root file has no `main`, or has a
`main` that is not `pub`, fails with an error from deep inside the standard
library that does not mention `main`:

```
$ cat a.zig
fn main() void {}
$ zig build-exe a.zig -target aarch64-macos        # same with -lc, x86_64-macos, aarch64-ios
lib/std/start.zig:624:23: error: struct 'elf.AT__struct_853' has no member named 'HWCAP'
                elf.AT.HWCAP => at_hwcap = auxv[i].a_un.a_val,
```

An empty root file fails the same way. Rejecting these programs is correct.
`main` must be `pub`, and every release rejects both shapes. The defect is
the message. 0.16.0 and 0.15.2 report `'main' is not marked 'pub'` and
`root source file struct 'a' has no member named 'main'` on every target, and
0.17.1 still does on `x86_64-linux-gnu` and `-musl` without libc.

The supported ways to write `main` are unaffected on 0.17.1: `pub fn main()
void` and `pub export fn main() c_int` compile for macOS, and for Linux with
libc.

## Evidence

Reproduced with the 0.17.1 release on macOS (Apple silicon) for
`aarch64-macos`, `x86_64-macos` and `aarch64-ios`, with and without `-lc`. The
same sources give the clear errors with 0.16.0 and 0.15.2 on all of those
targets. Upstream: codeberg#37113, closed by bd51e91a9a on master.

## Root cause

In `lib/std/start.zig:32`, a libc `main` wrapper is exported only when
`@hasDecl(root, "main")`. That is false for a missing `main`, and for one
that isn't `pub`. Darwin then falls through to the final `else` (`:88`),
which exports the ELF entry point `_start`. Its `posixCallMainAndExit` reads
the auxiliary vector through `elf.AT` (`:624`), which since 0.17.0 has no
members on non-ELF targets, so compilation fails there before it reaches
`callMain` (`:787`) and its "not marked 'pub'" check. In 0.16.0 the same
`_start` was instantiated, but `elf.AT_HWCAP` was a plain constant, so
compilation got as far as `callMain`.

## Fix sketch

Upstream's bd51e91a9a: take the libc `main` path whenever libc is linked and
the target requires it (`std.os.requiresLibC()`), not only when a `pub main`
exists. `callMain` then reports the real problem.

## Verification

`zig build-exe a.zig -target aarch64-macos` with a non-`pub` `main` reports
`'main' is not marked 'pub'`. An empty root file reports `no member named
'main'`.

## Fix

Cherry-picked upstream's bd51e91a9a ("start code: flatten and improve missing
pub fn main message") with `-x`. It applied cleanly, and the diff is identical
to upstream's. Its functional change is the condition at
`lib/std/start.zig:32`. The rest moves the Windows, UEFI, WASI and
freestanding-wasm branches into one `switch` without changing them.

Added `test/cases/compile_errors/private_main_fn_darwin.zig` and
`missing_main_fn_in_executable_darwin.zig`, for `x86_64-macos` and
`aarch64-ios`, beside upstream's `x86_64-linux` versions. Upstream's commit
added no test.

Verified with the 0.17.1 release binary and `--zig-lib-dir` pointed at this
checkout's `lib/`, before and after the change. The sources were a non-`pub`
`main`, a non-`pub` `export fn main() c_int`, an empty file, `pub export fn
main() c_int`, and `pub fn main() void`. Each was built for `aarch64-macos`,
`x86_64-macos`, `aarch64-ios`, `x86_64-linux-gnu` and `x86_64-linux-musl`,
with and without `-lc`:

- The three invalid sources on the three Darwin targets: before, the `HWCAP`
  error. After, `'main' is not marked 'pub'` or `no member named 'main'`, as
  on 0.16.0.
- The two valid sources: same result before and after on every target. They
  compile for macOS and for Linux with libc. `aarch64-ios` still stops on
  `apple-device-sdk-libsystem`, and `pub export fn main() c_int` without libc
  on Linux is still rejected for its return type.
- Valid programs are byte-for-byte unchanged on every branch of the
  restructured block. Built `-OReleaseSmall -fstrip` from the same lib
  directory, with only `start.zig` swapped, these outputs had identical
  SHA-256 hashes: `pub fn main` for `x86_64-windows-gnu` (with and without
  libc), `wasm32-wasi`, `wasm32-freestanding`, `x86_64-uefi`,
  `aarch64-linux-musl`, `aarch64-linux-gnu` with libc, `x86_64-macos` and
  `aarch64-ios-simulator`; a `-fno-entry` wasm module; and dynamic libraries
  for Windows, Linux and macOS.
- Linux results are unchanged, including the extra error on Linux with libc
  described in `linux-libc-missing-main-tls-assert`.
- `mise run zig-build -- test-cases -Dtest-filter=main_fn`: the two new
  cases and upstream's two pass. With the release `start.zig` restored, the
  new cases fail.

## Notes

- Related: `linux-libc-missing-main-tls-assert`, the same fall-through on
  Linux with libc, which this fix does not change.
