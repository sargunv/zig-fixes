---
title: Unrequested lazy dependencies are extracted from the global cache into zig-pkg
priority: 1
area: build-system
targets: [all]
upstream: [codeberg#35652]
affects-line: yes
---

## Symptom

When a lazy dependency is absent from the project's `zig-pkg/` but its
tarball is in the global cache (because any project on the machine once
fetched it), `zig build` unpacks it into `zig-pkg/` even though `build.zig`
never calls `lazyDependency` for it. With fresh caches nothing is fetched,
so behaviour depends on what else was built on the machine. Effects:
hundreds of MB copied per project (tempora pulls Unicode CLDR), and per
commenters, builds that fail because an unneeded lazy dependency that does not
work with the current Zig is now treated as present (ziglua#229; the
workaround there was `zig build --fetch=all`).

## Evidence

- codeberg#35652 (0.17.0-dev.812, milestone 0.18.0) with a tempora repro;
  two commenters hit it; a maintainer called the fix trivial and put it in
  PR codeberg#37435.
- Read at 0.17.1: see Root cause. Not reproduced.

## Root cause

`lib/compiler/Maker/Fetch.zig:650-671` checks the global cache and calls
`runResource` (unpack, hash, rename into `zig-pkg`) before the laziness check
at lines 673-680, which marks an unrequested lazy dependency `.unavailable`
and returns.

## Fix sketch

Move the `switch (f.lazy_status)` block above the global cache lookup, so an
unrequested lazy dependency returns before anything is unpacked. A few lines.

## Verification

With the dependency tarball in the global cache and an empty `zig-pkg/`, run a
build step that does not request the lazy dependency: `zig-pkg/` stays empty.
Then request it: it is extracted from the global cache without network.

## Notes

Not on origin/master (same ordering at master Fetch.zig:655-686); PR
codeberg#37435 was not merged when this was written. The `--system` panic in
cb37537 is in the same branch but needs its own fix: there the lazy dependency
is requested, so reordering alone does not avoid it.
