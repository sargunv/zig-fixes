---
title: readFileAlloc returns empty or truncated data for files whose stat size is wrong (/proc, sysfs)
priority: 1
area: lib/std
targets: [all]
upstream: [codeberg#31946]
affects-line: yes
---

## Symptom

```zig
const meminfo = try std.Io.Dir.cwd().readFileAlloc(io, "/proc/meminfo", arena, .unlimited);
// meminfo.len == 0
```

Virtual files report `st_size == 0`, so nothing is read. Files that report
a size smaller than their contents (sysfs reports 4096, and files growing
while being read) are truncated at the stat size. Reading the same file with
a plain `File.Reader` works.

## Evidence

- codeberg#31946, reported on 0.17.0-dev.9 (Linux).
- Read at 0.17.1 and on `origin/master`: the size check below is unchanged.
  Not reproduced (no Linux host here).

## Root cause

`lib/std/Io/Writer.zig:2865` (`Allocating.sendFile`): when
`file_reader.getSize()` succeeds it treats the size as exact, returns
`error.EndOfStream` when `size - pos == 0` (line 2874), and otherwise reads
only `size - pos` bytes (line 2877). `Dir.readFileAllocOptions`
(`lib/std/Io/Dir.zig:1353`) reaches it through
`allocRemainingAlignedSentinel` and `File.Reader.stream`.

## Fix sketch

Use the stat size only as a capacity hint: after reading it, keep reading
until a real zero-length read, and when the size is 0 fall back to the
growing path (`exact = false`). Small. The same unbounded read is the source
of the Darwin >2 GiB failure (cb37546).

## Verification

On Linux, `readFileAlloc("/proc/meminfo")` returns non-empty data and
`readFileAlloc("/proc/self/maps")` matches `cat`. Add a std test reading
`/proc/self/status` on Linux.

## Notes

Common in Zig programs that read `/proc` or `/sys`. Related: codeberg#37098
(EBUSY from sysfs reads is unmapped).
