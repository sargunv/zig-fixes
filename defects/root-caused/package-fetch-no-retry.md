---
title: The package fetcher makes one HTTP attempt per dependency with no retry, so one transient network error fails the whole build
priority: 1
area: build-system
targets: [all]
upstream: []
affects-line: yes
---

## Symptom

`zig build` (or `zig build --fetch`) aborts on the first transient failure
while downloading a `build.zig.zon` dependency. These were seen in CI on two
different gitlab.freedesktop.org URLs in the same run:

```
zig-pkg/sdl-1.0.1+3.4.4-.../build.zig.zon:36:20: error: unable to connect to server: TlsInitializationFailed
zig-pkg/sdl-1.0.1+3.4.4-.../build.zig.zon:48:20: error: invalid HTTP response: HttpConnectionClosing
```

Packages with many transitive dependencies on throttling hosts fail often. For
example, `allyourcodebase/SDL3` declares 28 dependencies, marks only 2 as lazy,
and fetches 14 of them from gitlab.freedesktop.org.

## Evidence

- Seen in CI: over Jul 21–24, 21 flaky CI jobs came from Zig/SDL source
  fetches.
- Code verified at 0.17.1 (below). Not reproduced here.

## Root cause

Verified by reading code at 0.17.1.
- `lib/compiler/Maker/Fetch.zig:1203-1240` (`initResource`) makes exactly one
  `http_client.request(.GET, uri, .{})`, one `sendBodiless`, and one
  `receiveHead`. Any error becomes a fatal
  `f.fail(...)`: "server connection failed", "HTTP request failed", or
  "invalid HTTP response".
- There is no retry or backoff anywhere in `Fetch.zig`. The only match for
  "attempt" is unrelated.
- The git transport path (`Fetch.zig:1263ff`) has no retry either.

origin/master: `lib/compiler/Maker/Fetch.zig` still contains no
"retry", "retries", or "backoff" (verified with grep; the request flow was not
re-read).

## Fix sketch

A few dozen lines:
- Wrap the HTTP connect, send, and receive-head phases (and the git session
  setup) in a bounded retry with exponential backoff, for example 3–5
  attempts.
- Retry only on transient errors: connection reset, TLS init failure,
  `HttpConnectionClosing`, timeouts, 5xx, and 429 (honoring `Retry-After`).
- Don't retry on 4xx or hash mismatches.
- Optionally expose the attempt count through a `--fetch-retries` option or
  an environment variable.
- A separate, larger improvement: let a package mark dependencies as
  platform-specific so they are not fetched at all (the `lazy` mechanism
  exists, but packages rarely use it).

## Verification

Point a dependency at a local HTTP server that fails the first N connections
(drops the TCP connection, then succeeds). `zig build --fetch` succeeds when
N is below the retry limit, and reports the last error otherwise.

## Notes

- **Workarounds today (worth keeping regardless):**
  - Cache Zig's global package cache in CI, and save it only after the job's
    checks pass, so a partial fetch is never published.
  - Prefer packages with fewer fetch hosts: `castholm/SDL` fetches everything
    from github.com, unlike `allyourcodebase/SDL3`.
