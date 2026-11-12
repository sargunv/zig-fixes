---
title: "macOS: copying a file to a pipe spins forever (or panics in Debug) because a failed fcopyfile is retried"
priority: 1
area: lib/std
targets: [aarch64-macos, x86_64-macos]
upstream: [codeberg#32163, codeberg#35843]
affects-line: yes
---

## Symptom

On macOS, sending a file's contents to a pipe or a socket through std's
file-to-file fast path never finishes. Release builds spin at 100% CPU inside
repeated `fcopyfile` calls; Debug builds print `unexpected errno: 9` and then
panic with `programmer bug caused syscall error: INVAL`.

Smallest known trigger: `zig translate-c test.h | wc -l`. Redirecting to a
file (`> out.zig`) works; piping hangs. In a program, any
`File.Writer.interface.sendFileAll(&file_reader, .unlimited)` with a
positional reader on a regular file and a pipe as the writer's file.

## Evidence

- First seen as a `zig translate-c` from 0.17.1 that hung at 100% CPU with
  the process sample inside `fcopyfile`.
- codeberg#32163 reports the same hang for piped `zig translate-c` output.
  Reproduced on 0.17.1 (macOS 26, Apple silicon).
- codeberg#35843 reports `streamRemaining` on an `Io.File.Reader` failing when
  stdout is a pipe on Darwin. Reproduced on 0.17.1: panic in Debug,
  infinite loop in ReleaseSafe.

## Root cause

Read on `fork/0.17.x` at 0.17.1.

`fileWriteFilePositional` in `lib/std/Io/Threaded.zig` tries `fcopyfile` on
macOS (`:11814-11860`) whenever the reader is at position 0, the write is at
offset 0, the limit is unlimited and the reader knows the input's size. It
never looks at what the output is.

`fcopyfile` cannot write to pipes or sockets. Measured with a small C program
on macOS 26:

- To a pipe or a socket it fails with `EBADF`, but only after reading up to
  1 MiB of the input, so the input descriptor's seek position has moved.
- Called again on the same input, now at its end, to a pipe, it fails with
  `EINVAL`.
- A regular file, `/dev/null` and a tty work.

The error handling (`:11831-11856`):

- `.OPNOTSUPP`: disables the fast path and returns 0; the next call skips it
  and returns `error.Unimplemented`, so the caller falls back.
- `.INTR`: retries.
- Any other errno: returns 0 **without** disabling the fast path. In Debug,
  `EBADF` goes through `posix.unexpectedErrno` (a stack trace, then
  `error.Unexpected`, which the `assert` accepts), and `EINVAL` hits
  `errnoBug` and panics.

`Io.Writer.sendFileAll` treats 0 bytes as no progress and calls again, so the
same failing `fcopyfile` runs forever: `EBADF` once, then `EINVAL` each time
after. For translate-c the caller is
`stdout_writer.interface.sendFileAll(&file_reader, .unlimited)` at
`src/main.zig:4966`.

Only the positional path is affected. `fileWriteFileStreaming` uses
`sendfile` on macOS, which disables itself on any error. A streaming reader
never reaches `fcopyfile`, because `File.Reader.initStreaming` presets
`size_err`.

## Fix sketch

Do not call `fcopyfile` when the output is a pipe or a socket, so the input
is not read and its position not moved, and make the remaining unexpected
errnos return `error.Unimplemented` instead of 0, so no caller can loop on
them. Retrying after `EBADF` is not enough on its own: the input is then at its
end and the next call fails with `EINVAL`. Disabling the fast path globally,
as `OPNOTSUPP` does, would slow every later file-to-file copy.

## Verification

- `printf 'int x;\n' > t.h && zig translate-c t.h | wc -l` finishes and prints
  a line count, in Debug and release builds of the compiler.
- `zig test lib/std/std.zig --zig-lib-dir lib --test-filter "sendFileAll to a
  pipe"`, in Debug and ReleaseSafe.

## Fix

In `fileWriteFilePositional` (`lib/std/Io/Threaded.zig`), the macOS
`fcopyfile` path now stats the output and skips `fcopyfile` for pipes and
sockets, so the call falls through to `error.Unimplemented` and
`sendFileAll` falls back to reading and writing. Unexpected errnos from
`fcopyfile` now return `error.Unimplemented` instead of 0. The fast path is
unchanged for regular files, character devices and ttys.

Test: `File.Writer sendFileAll to a pipe` in `lib/std/fs/test.zig`. Without
the fix it fails in Debug (`unexpected errno: 9`) and hangs in ReleaseSafe;
with it, it passes in both.

Verified on macOS 26 (Apple silicon):

- A program that calls `sendFileAll` from a file to stdout, built with the
  release `zig` and `--zig-lib-dir lib` in Debug and ReleaseSafe, copied a
  12-byte file and a 3 MB file correctly to a pipe, a Unix socket, a regular
  file and `/dev/null`. Before the fix the pipe case panicked in Debug and
  spun in ReleaseSafe.
- A temporary print showed `fcopyfile` still runs and succeeds for
  file-to-file, and is not called for a pipe.
- `zig translate-c t.h | wc -l` with a compiler built from this change
  printed 430; the 0.17.1 release spins until killed.
- The `fs.test`, `Io.Threaded`, `Io.File`, `Io.Writer` and `Io.Dir` std tests
  pass.

## Notes

- Not fixed on `upstream/master` as of 2026-11-11.
