---
title: Io.Threaded caches a /dev/null fd without O_CLOEXEC, leaking it into every spawned child
priority: 1
area: lib/std
targets: [all]
upstream: [codeberg#37620]
affects-line: yes
---

## Symptom

After the first `std.process.spawn` that redirects a stdio stream to
`/dev/null`, the parent keeps a cached `/dev/null` fd open with flags
`O_RDWR|O_LARGEFILE` and no close-on-exec. Every later child inherits it
across `execve`. A display manager written in Zig (Ly) leaked the descriptor
into the whole desktop session. That broke a coreutils test that assumes
fds 3–5 are free ("Too many open files" under `RLIMIT_NOFILE=6`).

## Evidence

- codeberg#37620, reported on 0.17.1 (Linux).
- Not reproduced; faulty code read at 0.17.1.

## Root cause

`lib/std/Io/Threaded.zig:15587` `getDevNullFd` opens
`open_sym("/dev/null", .{ .ACCMODE = .RDWR }, mode)` (line 15596) without
`.CLOEXEC = true`, then caches the fd in `t.null_file.fd`.

## Fix sketch

Pass `.CLOEXEC = true` in the open flags. The child still gets `/dev/null` on
its stdio slot, because `dup2` clears `FD_CLOEXEC` on the target. One line.
Check other long-lived fds that Threaded caches for the same problem.

## Verification

Spawn a child that redirects stdin to `/dev/null`, then spawn `ls -l
/proc/self/fd` (Linux) or `lsof -p` (macOS). After the fix, no extra
`/dev/null` descriptor should appear in the second child.

## Notes

As of this sweep, origin/master has the same open call at
`lib/std/Io/Threaded.zig:15656`.
