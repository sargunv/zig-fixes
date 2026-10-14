---
title: A missing or private `main` on Linux with libc also reports a comptime assertion in linux/tls.zig
priority: 3
area: lib/std
targets: [x86_64-linux-gnu, x86_64-linux-musl]
upstream: []
affects-line: yes
---

## Symptom

On Linux with `-lc`, an executable whose root file has no `pub main` gets the
right error, but only after an unrelated one:

```
$ cat a.zig
fn main() void {}
$ zig build-exe a.zig -target x86_64-linux-gnu -lc     # same for -musl
lib/std/debug.zig:442:14: error: reached unreachable code
lib/std/os/linux/tls.zig:706:11: note: called at comptime here
    assert(!builtin.link_libc); // otherwise libc should control TLS
lib/std/start.zig:787:43: error: 'main' is not marked 'pub'
```

0.16.0 reports only the second error. Without `-lc`, 0.17.1 does too.

## Evidence

Reproduced with the 0.17.1 release for `x86_64-linux-gnu` and
`x86_64-linux-musl`, both with a non-`pub` `main` and with an empty root file.
0.16.0 reports only the `main` error. Upstream's fix for the Darwin case,
bd51e91a9a (see `cb37113-missing-pub-main-error`), does not change this:
Linux does not require libc, so its new condition does not apply.

## Root cause

Same fall-through as `cb37113-missing-pub-main-error`. With libc linked but no
`pub main`, `lib/std/start.zig` exports the libc-less `_start`. Its
`posixCallMainAndExit` (`start.zig:657`) initializes TLS through
`os/linux/tls.zig`, which asserts at comptime that libc is not linked
(`tls.zig:706`). Not investigated further. Upstream master has since moved
that TLS code into compiler_rt (736d37ad16), which may change this.

## Fix sketch

Not investigated. Taking the libc `main` path whenever libc is linked for an
executable would route these to `callMain`'s error. Check upstream master
first.

## Verification

`zig build-exe a.zig -target x86_64-linux-gnu -lc` with a non-`pub` `main`
reports only `'main' is not marked 'pub'`.

## Notes
