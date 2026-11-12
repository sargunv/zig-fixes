---
title: std.os.linux.cap_user_header_t declares pid as usize, so capget/capset read padding as the pid on 64-bit Linux
priority: 1
area: lib/std
targets: [x86_64-linux-gnu, x86_64-linux-musl, aarch64-linux-gnu, aarch64-linux-musl, riscv64-linux-gnu, riscv64-linux-musl, loongarch64-linux-gnu, loongarch64-linux-musl]
upstream: [codeberg#32181]
affects-line: yes
---

## Symptom

`linux.capget(&hdr, &data)` fails with `.SRCH` ("no such thread") depending
on optimize mode and on the surrounding stack layout, even with
`hdr.pid = 0` (calling thread). Wrapping the header and data in a struct that
zero-initializes the header makes it work.

## Evidence

- codeberg#32181 (0.16.0); full program in
  `codeberg.org/ahwayakchih/zig-optimization-bug`. A commenter identified the
  struct mismatch.
- Read at 0.17.1: the field is `usize`. Not run (needs a Linux host).

## Root cause

`lib/std/os/linux.zig:7267-7270`:

```zig
pub const cap_user_header_t = extern struct { version: u32, pid: usize };
```

The kernel's `struct __user_cap_header_struct` is `{ __u32 version; int pid; }`
(8 bytes). On 64-bit targets the Zig struct puts `pid` at offset 8 after 4
bytes of padding. The kernel reads `pid` from offset 4, which is that
uninitialized padding, so any nonzero garbage there names a nonexistent
thread.

## Fix sketch

Change `pid` to `i32` (`c_int`). One line. The only users in std are
`capget`/`capset` (`lib/std/os/linux.zig:3177`, `:3181`), which pass the
pointer through.

## Verification

On a 64-bit Linux host, call `capget` with `version =
_LINUX_CAPABILITY_VERSION_3`, `pid = 0` after scribbling the stack, in every
optimize mode; it should return 0. Add a comptime test that
`@sizeOf(cap_user_header_t) == 8`.

## Notes

origin/master (`lib/std/os/linux.zig:7461`) still declares `pid: usize`. On
32-bit targets the layout is correct by accident.
