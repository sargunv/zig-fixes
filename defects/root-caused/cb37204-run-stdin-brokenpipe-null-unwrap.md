---
title: Run step panics with "attempt to use null value" when the child stops reading a stdin file
priority: 1
area: build-system
targets: [x86_64-linux-gnu, aarch64-linux-gnu]
upstream: [codeberg#37204]
affects-line: yes
---

## Symptom

A `Run` step with `setStdIn(.{ .lazy_path = ... })` whose child exits before
reading all of stdin crashes the build runner on Linux:

```
thread 145625 panic: attempt to use null value
lib/compiler/Maker/Step/Run.zig:1811:37: in evalGeneric
    stdin_writer.err.?,
```

Trigger: a 1 MiB `WriteFiles` file piped into `zig zen`.

## Evidence

- codeberg#37204 (0.18.0-dev.146, x86_64-linux, full trace in the issue).
- Ran the issue's `build.zig` on 0.17.1, aarch64-macos: no panic; the step
  fails with `error: failed to write to stdin: BrokenPipe`. macOS takes a
  different write path. The Linux panic is confirmed by reading the code
  below.

## Root cause

`lib/compiler/Maker/Step/Run.zig:1811-1822` (the unwraps are at 1816 and
1821): on `error.WriteFailed` from
`sendFileAll`/`flush`, it unwraps `stdin_writer.err.?`. When the failure comes
from the sendfile path, `std.Io.File.Writer` stores the error in
`write_file_err` (`lib/std/Io/File/Writer.zig:170,191`) and leaves `err` null,
so the unwrap panics. `write_file_err` is never read anywhere.

## Fix sketch

Use `stdin_writer.err orelse stdin_writer.write_file_err` (or a helper on
`File.Writer` returning whichever is set). Arguably `BrokenPipe` on stdin
should not fail the step at all, since a child may legitimately stop reading
(like `head`); decide separately. Small.

## Verification

On Linux, the issue's `build.zig` reports an error (or succeeds) instead of
panicking.

## Notes

Not fixed on origin/master. Other `?`-unwraps of `File.Writer.err` after a
`sendFile*` call may have the same problem; grep for `.err.?`.
