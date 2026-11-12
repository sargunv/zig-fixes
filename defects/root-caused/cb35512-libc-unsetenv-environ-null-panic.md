---
title: With libc linked, a C call to unsetenv() makes the next std.debug.print / std.log panic on a null environ entry
priority: 1
area: lib/std
targets: [all]
upstream: [codeberg#35512, codeberg#30879]
affects-line: yes
---

## Symptom

A program that links libc and calls into a C library which runs `unsetenv`
(SDL3 `SDL_CreateWindow`/`SDL_Init` on Wayland/X11, GLFW `glfwInit`, which drop
`XDG_ACTIVATION_TOKEN`, `DESKTOP_STARTUP_ID` and similar) panics with
`attempt to use null value` the first time it prints, logs or reads the
environment. ReleaseFast builds segfault instead. With the panic handler
itself printing, the process can then hang on the stderr mutex. Smallest
trigger (from #35512): a `main` that declares `extern fn unsetenv`, calls
`_ = unsetenv("TEST");` and then `std.debug.print("ok\n", .{});`.
`TEST=123 zig run -lc main.zig` panics; without `TEST` set it prints `ok`.

## Evidence

- codeberg#35512 (0.17.0-dev.389, 0.16.0 with SDL3 on KDE/Wayland) and
  codeberg#30879 (0.16.0-dev, GLFW and SDL3 on Linux) report the same panic.
  A maintainer (castholm) confirmed the mechanism in #35512 on glibc and musl.
- Reproduced on 0.17.1, aarch64-macos, `zig run -lc` with the program above:
  `panic: attempt to use null value` at `lib/std/Io/Threaded.zig:317:40`
  (`const entry = opt_entry.?;`) via `scanEnviron` <- `initLockedStderr` <-
  `std.debug.print`. So Darwin's libc behaves the same way.

## Root cause

`lib/std/start.zig:732-754`: the exported C `main` counts `envp` once and
stores it as a fixed-length slice; `callMainWithArgs`
(`lib/std/start.zig:720-726`) hands that slice to the debug `Io.Threaded` and
to `std.process.Init`. libc's `environ` initially aliases `envp`, and
`unsetenv` removes entries in place by shifting the array and writing a
terminating NULL, without copying first (POSIX allows this; only `setenv`
copies). The stored length is now too long, so the slice ends in NULL
entries. `Environ.scan` (`lib/std/Io/Threaded.zig:316-317`) then unwraps
them with `.?`. The same pre-computed slice also feeds `Init.environ_map` and
`environ.block` users.

## Fix sketch

When linking libc, do not cache a length for `envp`: treat the block as
sentinel-terminated and stop at the first NULL (`for` over a `[*:null]`),
or read libc's `environ` at use time. As a minimum, make `Environ.scan` and
the other iterators stop on a NULL entry instead of unwrapping it. Small
change, mostly in `start.zig`, `Io/Threaded.zig` and `process/Environ.zig`.

## Verification

Run the snippet above with `TEST=123 zig run -lc`; it should print `ok`. Add a
std test that links libc, calls `unsetenv` on a variable present at startup,
then calls `std.debug.print` and iterates `init.minimal.environ`.

## Notes

Not fixed on origin/master (`opt_entry.?` still at
`lib/std/Io/Threaded.zig:325`). Workaround reported in #35512: copy
`std.c.environ` into owned memory at the top of `main`.
