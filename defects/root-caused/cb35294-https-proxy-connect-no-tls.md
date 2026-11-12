---
title: HTTPS through an HTTP proxy never starts TLS after CONNECT, so zig fetch fails behind https_proxy
priority: 1
area: lib/std
targets: [all]
upstream: [codeberg#35294]
affects-line: yes
---

## Symptom

With `https_proxy=http://host:port` set, every HTTPS request made through
`std.http.Client` fails. That includes `zig fetch` and `zig build` dependency
fetching, which call `initDefaultProxies`. Depending on the proxy, the user
sees `400 The plain HTTP request was sent to HTTPS port`,
`invalid HTTP response: HttpConnectionClosing`, or a hang.

## Evidence

- codeberg#35294: reported on 0.17.0-dev.269 (aarch64-macos). Comments
  confirm it on Arch Linux with 0.14/0.15 and on 0.17.0-dev.956 through a TLS
  proxy. One commenter reports that upstream PR #36484 turned the 400 into a
  200 on 0.16.0.
- Not reproduced here (needs a proxy). Read the faulty code at 0.17.1.

## Root cause

`lib/std/http/Client.zig:1533-1590` (`connectProxied`): it opens the
connection to the proxy with `.protocol = proxy.protocol` (`.plain` for an
`http://` proxy) and sends `CONNECT`. On a 200 reply it returns that plain
connection as-is (`return connection;` at line 1590). It never runs a TLS
handshake with `proxied_host` over the tunnel, even when the caller asked for
`.tls`. `connect` (`lib/std/http/Client.zig:1607-1634`) routes every `.tls`
request with an `https_proxy` through this path. `lib/compiler/Maker.zig:1281`
and `:1749` enable the proxies for package fetching.

## Fix sketch

Once `CONNECT` succeeds and the requested protocol is `.tls`, wrap the
tunnelled stream in a TLS client for `proxied_host` (the same setup
`connectTcpOptions` does for direct TLS). Key the pooled connection on
`.tls`. Watch the error path: one out-of-tree patch had a use-after-free when
`Connection.Tls.create` fails after the tunnel is up. Medium size, about
50-100 lines. Upstream PR #36484 is a candidate fix.

## Verification

Run a local HTTP CONNECT proxy (for example `mitmproxy --mode regular` or
`tinyproxy`), set `https_proxy=http://127.0.0.1:<port>`, and run
`zig fetch https://github.com/<any>/archive/<rev>.tar.gz`. It should succeed.
Add a std.http test with an in-process CONNECT proxy and a TLS server if
feasible.

## Notes

Not fixed on origin/master (no related commits after 0.17.1). Related
unfiled defects: codeberg#31454 (no timeout on the CONNECT response) and
codeberg#31410 / codeberg#31305 (`ConnectTcpOptions.timeout` ignored).
Workaround: download tarballs with curl and `zig fetch file://...`.
