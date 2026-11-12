---
title: Dir.cwd().stat() panics with EBADF on macOS and other non-Linux POSIX
priority: 1
area: lib/std
targets: [aarch64-macos, x86_64-macos, x86_64-freebsd]
upstream: [codeberg#36103, github#22763]
affects-line: yes
---

## Symptom

```zig
std.debug.print("{}\n", .{try std.Io.Dir.cwd().stat(io)});
```

panics in Debug with `programmer bug caused syscall error: BADF` from
`fileStatPosix`. `cwd().openDir(".").stat(io)` works.

## Evidence

- codeberg#36103, reported on 0.16.0 and 0.17.0-dev.1282 (aarch64-macos).
- Reproduced on 0.17.1, aarch64-macos, with the snippet above via
  `zig run`: the same panic at `Threaded.zig:4044` (`fileStatPosix`).
- Works on x86_64-linux because the Linux path uses `statx(fd, "",
  AT_EMPTY_PATH)`, which accepts `AT_FDCWD`.

## Root cause

`lib/std/Io/Dir.zig:92`: `cwd()` returns `AT_FDCWD` as the handle on POSIX.
`lib/std/Io/Threaded.zig:3744` (`dirStat`) forwards that handle to
`fileStat`, and `lib/std/Io/Threaded.zig:4031` calls `fstat(AT_FDCWD)`,
which is EBADF on Darwin and mapped to `errnoBug`. FreeBSD takes the same
`fstat` path; that it also fails there is a guess, not checked.

## Fix sketch

In `dirStat` on non-Linux POSIX, when the handle is `AT_FDCWD`, use
`fstatat(AT_FDCWD, ".", ...)` instead of `fstat`. A few lines.

## Verification

The snippet above prints a stat on macOS in Debug. Add a std test that stats
`Dir.cwd()`.

## Notes

Not fixed on `origin/master` (`dirStat` is unchanged). Other APIs that pass
the `cwd()` handle to fd-only syscalls may share the problem (github#9688).
