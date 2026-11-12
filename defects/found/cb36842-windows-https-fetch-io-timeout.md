---
title: zig fetch / std.http HTTPS fails on some Windows machines (IO_TIMEOUT, TlsInitializationFailed)
priority: 1
area: lib/std
targets: [x86_64-windows-msvc, x86_64-windows-gnu, aarch64-windows-msvc]
upstream: [codeberg#36842, codeberg#35655, codeberg#31956]
affects-line: likely
---

## Symptom

`zig fetch --save git+https://github.com/Snektron/vulkan-zig` hangs for about
a minute and then fails with `TlsInitializationFailed` on Windows 10. It worked
with 0.15.2 and fails with 0.16.0 and 0.17.0. With `ZIG_DEBUG_CMD=1`, a second
user's trace shows
`error.Unexpected NTSTATUS=0xc00000b5 (IO_TIMEOUT)` in
`netConnectIpWindows`. A plain `std.http.Client.fetch("https://google.com")`
fails the same way (codeberg#35655), with IO_TIMEOUT from `netReadWindows`
inside `std.crypto.tls.Client.init`. curl on the same machine works.

## Evidence

- codeberg#36842 (0.17.0-dev.2131, then 0.17.0 in the comments);
  codeberg#35655 (0.17.0-dev.704). squeek502 could not reproduce on Windows 10.
- Read at 0.17.1: `netReadWindows`/`netWriteWindows` now map IO_TIMEOUT to
  `error.ConnectionTimedOut` (`lib/std/Io/Threaded.zig:13118`, `:13632`), but
  `netConnectIpWindows` (`lib/std/Io/Threaded.zig:12528`) maps only SUCCESS,
  INSUFFICIENT_RESOURCES and CONNECTION_REFUSED. Not reproduced (no Windows
  host).
- `std.http.Client.connectTcpOptions` (`lib/std/http/Client.zig:1473`) turns
  every TLS setup error except OOM/Unexpected/Canceled into
  `TlsInitializationFailed`, which hides the underlying cause.

## Root cause

Not investigated. Guess: the regression window (0.15.2 good, 0.16.0 bad)
seems to line up with the move of Windows networking to direct AFD ioctls in
`std.Io.Threaded` (not bisected), and an AFD receive or connect times out under conditions that Winsock
handles (for example IPv6 attempts, or proxy/AV filter drivers).

## Fix sketch

Not investigated. First steps: map the remaining connect statuses
(IO_TIMEOUT, HOST_UNREACHABLE, NETWORK_UNREACHABLE) in `netConnectIpWindows`,
and keep the inner error in `connectTcpOptions` so failures can be diagnosed.

## Verification

On an affected Windows machine, `zig fetch` of a GitHub URL succeeds, and the
codeberg#35655 test fetches `https://google.com`.

## Notes

codeberg#31956 tracks unmapped NTSTATUS values in the Windows socket paths.
LOCAL_DISCONNECT mapping landed on master as 9276a56e3c (already mapped in
0.17.1's read/write paths). Related known entry: `package-fetch-no-retry`.
