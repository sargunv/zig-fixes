---
title: resolv.conf without a trailing newline fails to parse, breaking zig fetch and all std DNS on Linux
priority: 1
area: lib/std
targets: [x86_64-linux-gnu, x86_64-linux-musl, aarch64-linux-gnu, aarch64-linux-musl, riscv64-linux-musl, loongarch64-linux-musl]
upstream: [codeberg#36278]
affects-line: yes
---

## Symptom

If `/etc/resolv.conf` does not end in a newline, every hostname lookup through
`std.Io.Threaded` on Linux (without glibc) fails. `zig fetch` / `zig build`
package fetching reports:

    error: server connection failed: ResolvConfParseFailed

curl, glibc and musl resolvers accept the same file.

## Evidence

- codeberg#36278 (0.17.0-dev.1422 and 0.16.0).
- Reproduced on 0.17.1 (aarch64-macos, calling the parser directly):
  `ResolvConf.parse` on `"nameserver 1.1.1.1\n"` succeeds; on
  `"nameserver 1.1.1.1"` it returns `error.EndOfStream`.

## Root cause

`lib/std/Io/net/HostName.zig:457-494`: `parse` loops on
`reader.takeSentinel('\n')`, and on `error.EndOfStream` returns the error if
any bytes remain buffered (`HostName.zig:493`), so a final unterminated line is
treated as an error instead of being parsed. `lookupDnsSearch`
(`lib/std/Io/Threaded.zig:14768`) maps any error to `ResolvConfParseFailed`.
That path is taken on Linux whenever glibc is not linked
(`lib/std/Io/Threaded.zig:13962-14028`), which includes the static musl Zig
compiler binary.

## Fix sketch

On `EndOfStream` with buffered bytes, take the remaining bytes
(`reader.buffered()` then `toss`) and parse them as the last line, sharing the
per-line body with the loop. Small.

## Verification

Add a `ResolvConf.parse` test with no trailing newline expecting one
nameserver; on Linux, `zig fetch` against a URL with a resolv.conf lacking the
final newline succeeds.

## Notes

Same code path as cb36186-resolv-conf-ipv6-zone-index.md (another way a valid
resolv.conf makes all lookups fail). No fix on `origin/master`.
