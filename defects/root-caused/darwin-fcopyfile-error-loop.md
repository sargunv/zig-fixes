---
title: "macOS: copying a file to a pipe spins forever (or panics in Debug) because a failed fcopyfile is retried"
priority: 1
area: lib/std
targets: [aarch64-macos, x86_64-macos]
upstream: [codeberg#32163, codeberg#35843]
affects-line: yes
---

## Symptom

On macOS, sending a file's contents to a pipe through std's file-to-file fast
path never finishes. Release builds spin at 100% CPU inside repeated
`fcopyfile` calls; Debug builds panic on the unexpected errno.

Smallest known trigger: `zig translate-c test.h | wc -l`. Redirecting to a
file (`> out.zig`) works; piping hangs.

## Evidence

- First seen as a `zig translate-c` from 0.17.1 that hung at 100% CPU with
  the process sample inside `fcopyfile`.
- codeberg#32163 reports the same hang for piped `zig translate-c` output. Reproduced
  on 0.17.1 (macOS, Apple silicon).
- codeberg#35843 reports `streamRemaining` on an `Io.File.Reader` failing when
  stdout is a pipe on Darwin. Reproduced on 0.17.1: panic in Debug,
  infinite loop in ReleaseSafe.

## Root cause

Read at tag 0.17.1.

`fcopyfile` fails when the destination is a pipe (EBADF was observed; the
upstream report also mentions EINVAL). The macOS fast path in
`lib/std/Io/Threaded.zig` handles failures three ways:

- `.OPNOTSUPP` (`:11840-11846`): disables the fast path
  (`@atomicStore(UseFcopyfile, &t.use_fcopyfile, .disabled, ...)`) and returns
  0, so the caller falls back to another method.
- `.INTR`: retries.
- Any other errno (`:11847-11855`): returns 0 **without** disabling the fast
  path. In Debug the `unexpectedErrno` call inside the `assert` panics first.

The caller treats 0 bytes as "no progress yet" and asks again, so the same
failing `fcopyfile` runs forever. For translate-c the caller is
`stdout_writer.interface.sendFileAll(&file_reader, .unlimited)` at
`src/main.zig:4966`.

Not checked: which other errnos can reach this branch, and whether the
positional and streaming callers (`fileWriteFilePositional`,
`fileWriteFileStreaming`) behave the same way.

## Fix sketch

A few lines in `lib/std/Io/Threaded.zig`: treat EBADF and EINVAL from
`fcopyfile` like `OPNOTSUPP` (disable or bypass the fast path for this call and
fall back to read/write), and make every other errno return an error instead
of 0 so no caller can loop on it. Disabling the fast path globally after one
pipe write would slow later file-to-file copies, so a per-call fallback is the
better shape.

## Verification

- `printf 'int x;\n' > t.h && zig translate-c t.h | wc -l` finishes and prints
  a line count, in Debug and release builds of the compiler.
- A std test that copies a file into a pipe with `sendFileAll` on macOS.

## Notes

- Not fixed on `origin/master` as of the sweep.
