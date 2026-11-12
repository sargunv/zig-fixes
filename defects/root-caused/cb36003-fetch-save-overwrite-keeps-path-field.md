---
title: zig fetch --save writes a URL into .path and omits .hash when overwriting a dependency
priority: 1
area: build-system
targets: [all]
upstream: [codeberg#36003, codeberg#35444, codeberg#35257, github#21690, github#21931]
affects-line: yes
---

## Symptom

`zig fetch --save[=name] <url>` for a name that already exists in
`build.zig.zon` only replaces the location string:

- Existing `.pkg = .{ .path = "../pkg" }` becomes
  `.pkg = .{ .path = "file:///.../pkg.tar.gz", }`: a URL in the `.path` field
  and no `.hash` (codeberg#36003, codeberg#35444).
- An existing URL dependency whose `.hash` line was removed gets its URL
  replaced but no `.hash` added (codeberg#35257).

Either way the manifest is broken and the user has to delete the entry and
fetch again.

## Evidence

- codeberg#36003 (0.16.0, still present in 0.17.0), codeberg#35444 (0.16.0),
  codeberg#35257 (0.16.0, reproduced on 0.17.0-dev.1676). Original report
  github#21690 with an unmerged fix, github#21931.
- Reproduced on 0.17.1, aarch64-macos: app with `.dependencies = .{ .pkg = .{
  .path = "../pkg" } }`, `zig fetch --save=pkg file://.../pkg.tar.gz` ->
  `warning: overwriting existing dependency named "pkg"` and the result
  above.

## Root cause

`lib/compiler/Maker.zig:1931-1953` (`cmdFetch`): when the dependency exists, it
replaces `dep.location_node` (the string value only, so the `.path` field name
stays) and replaces the hash node only if one exists; the else branch is an
empty block with a comment pointing at github#21690.

## Fix sketch

When the dependency exists, replace the whole dependency struct node with
`new_node_init` (the `.url`/`.hash` initializer already built at line 1909)
instead of patching individual fields, at least when the location kind or
the presence of `.hash` differs. github#21931 is a starting point. Small.

## Verification

The reproduction above yields `.pkg = .{ .url = "file://...", .hash = "..." }`;
removing `.hash` and re-running `zig fetch --save=pkg <url>` restores it.

## Notes

Not fixed on origin/master.
