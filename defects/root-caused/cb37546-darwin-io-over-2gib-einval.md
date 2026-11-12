---
title: File reads and writes of 2 GiB or more fail with EINVAL on Darwin
priority: 1
area: lib/std
targets: [aarch64-macos, x86_64-macos, aarch64-ios]
upstream: [codeberg#37546, github#7805]
affects-line: yes
---

## Symptom

`std.Io.Dir.readFileAlloc` on a file of 2 GiB or more panics in Debug with
`programmer bug caused syscall error: INVAL` from `fileReadPositionalPosix`,
and returns `error.Unexpected` in release modes. Any single read or write
whose iovec total exceeds `INT_MAX` hits it.

## Evidence

- codeberg#37546, reported on 0.18.0-dev.860 (aarch64-macos).
- Reproduced on 0.17.1, aarch64-macos: a sparse 2 GiB file (`mkfile -n 2g`)
  read with `readFileAlloc(io, "big.bin", gpa, .unlimited)`. Debug build:
  panic `programmer bug caused syscall error: INVAL`. `-OReleaseSafe`:
  `error: Unexpected`.
- Darwin `read`/`pread`/`readv`/`preadv` (and the write counterparts) return
  EINVAL when the byte count or iovec sum exceeds `INT_MAX` (man pread).

## Root cause

`lib/std/Io/Threaded.zig:10009` (`fileReadStreamingPosix`) and
`lib/std/Io/Threaded.zig:10187` (`fileReadPositionalPosix`) build iovecs
from the caller's slices without capping the total. The cap exists only in the
legacy `lib/std/posix.zig:412` (`max_count = maxInt(i32)` on Darwin) and in
the sendfile paths (`lib/std/Io/Threaded.zig:11393`). The large request comes
from `Writer.Allocating.sendFile` (`lib/std/Io/Writer.zig:2877`), which asks
for the whole remaining file size in one read. The write paths
(`fileWritePositional`, `fileWriteStreaming`) look the same but were not
checked line by line.

## Fix sketch

On Darwin, clamp the iovec total to `maxInt(i32)` in every Threaded
read/write path (truncate the last iovec), as Go and Rust do. A short read or
write is already allowed by the callers. Small: a shared helper used by about
six functions.

## Verification

Rerun the reproduction above on macOS (2 GiB sparse file) in Debug and
ReleaseSafe; also write a buffer of 2 GiB + 1 with `writeAll`.

## Notes

Not fixed on `origin/master`. The reporter offered a patch upstream. iOS,
tvOS and visionOS share the Darwin syscall limit.
