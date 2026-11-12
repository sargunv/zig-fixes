---
title: Windows file I/O reaches unreachable on STATUS_PENDING when stdio is an overlapped pipe
priority: 1
area: lib/std
targets: [x86_64-windows-msvc, x86_64-windows-gnu, aarch64-windows-msvc, aarch64-windows-gnu]
upstream: [codeberg#35603]
affects-line: yes
---

## Symptom

`thread N panic: reached unreachable code` at
`.PENDING => unreachable, // unrecoverable: wrong File nonblocking flag` in
`fileWriteStreamingWindows`/`writeFilePositionalWindows`. It shows up in the
build runner (`printErrorMessages` writing a failed step's stderr) when the
parent process gave `zig build` an overlapped stderr pipe that fills up.
Parents that create overlapped pipes include IDE task runners and Node.js
`child_process`.

## Evidence

- codeberg#35603, reported on 0.16.0 with a deterministic reproduction: an
  undrained overlapped named pipe wrapped as
  `File{ .flags = .{ .nonblocking = false } }`, then `writeAll` 1 MiB.
- Read at 0.17.1: the `unreachable` arms are still present (Threaded.zig
  lines 3195, 3251, 3307, 10135, 10370, 11062, 11241), and `File.stdout()` /
  `File.stderr()` hardcode `nonblocking = false` (`lib/std/Io/File.zig:91`,
  `lib/std/Io/File.zig:104`). Not reproduced (no Windows host).

## Root cause

`lib/std/Io/File.zig:95` and `:108` assume standard handles are synchronous.
`lib/std/Io/Threaded.zig:11062` (positional write) and `:11241` (streaming
write) treat `STATUS_PENDING` on the synchronous path as impossible. Zig's own
spawn gives children synchronous client handles (Threaded.zig:16126-16136), so
the trigger needs a non-Zig parent.

## Fix sketch

Either query the handle mode (`NtQueryInformationFile`,
`FileModeInformation`) when constructing the stdio `File`s and set
`nonblocking` from it, or on `STATUS_PENDING` in the sync path wait on the
handle/IOSB like the nonblocking branch does. Medium-small.

## Verification

The issue's named-pipe reproduction no longer panics and the write completes
once a reader drains the pipe. Also run `zig build` with a failing step under
a Node.js `spawn` that does not read stderr until exit.

## Notes

Not fixed on `origin/master`. Reads hit the same pattern (codeberg#36464,
`ALERTED` on Ctrl+C in stdin reads, is a nearby but separate issue).
