---
title: Numeric IPv6 zone index (fe80::1%3) is resolved as an interface name, so resolv.conf parsing and zig fetch fail
priority: 1
area: lib/std
targets: [x86_64-linux-gnu, x86_64-linux-musl, aarch64-linux-gnu, aarch64-linux-musl, riscv64-linux-musl, loongarch64-linux-musl]
upstream: [codeberg#36186, codeberg#36878]
affects-line: yes
---

## Symptom

`std.Io.net.Ip6Address.resolve(io, "fe80::1%3", 53)` fails with
`error.InterfaceNotFound`. When `/etc/resolv.conf` contains such a nameserver
(systemd-resolved and podman containers write them), every std DNS lookup on
Linux fails with `error.ResolvConfParseFailed`, including package fetching.
Zig 0.15.2 handled it.

## Evidence

- codeberg#36186 (0.17.0-dev.1398, also 0.16.0), codeberg#36878 (same bug from
  a musl binary in a podman container, 0.17.0-dev.2163; closed upstream as a
  duplicate).
- Reproduced on 0.17.1 (aarch64-macos): `Ip6Address.resolve(io, "fe80::1%3",
  53)` returns `error.InterfaceNotFound`.

## Root cause

`lib/std/Io/net.zig:723-736`: `Ip6Address.resolve` always passes the text after
`%` to `Interface.Name.resolve` (`lib/std/Io/net.zig:1046-1048`), which asks the
OS for an interface with that name (`netInterfaceNameResolve`,
`lib/std/Io/Threaded.zig:13740`). A numeric zone ID such as `3` is not a name,
so the ioctl returns NODEV. `ResolvConf.addNumeric`
(`lib/std/Io/net/HostName.zig:501-506`) propagates the error and
`lookupDnsSearch` (`lib/std/Io/Threaded.zig:14768`) turns it into
`ResolvConfParseFailed`.

## Fix sketch

In `Ip6Address.resolve`, if the zone text is all decimal digits, use it as the
interface index directly (`std.fmt.parseInt(u32, ...)`) instead of resolving a
name. Optionally make resolv.conf parsing skip a nameserver it cannot resolve
rather than failing the whole lookup. Small.

## Verification

`Ip6Address.resolve(io, "fe80::1%3", 53)` returns interface index 3; a
resolv.conf test with `nameserver fe80::1%3` parses.

## Notes

Same code path as cb36278-resolv-conf-no-trailing-newline.md. No fix on
`origin/master`.
