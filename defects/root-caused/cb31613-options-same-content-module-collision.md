---
title: Two addOptions steps with identical content collide as one file in two modules
priority: 1
area: build-system
targets: [all]
upstream: [codeberg#31613]
affects-line: yes
---

## Symptom

When two packages each create `b.addOptions()` with the same generated
content (for example `addOption(bool, "some_option", false)`) and register
them under different import names in modules that end up in one compilation,
the compile fails:

```
.zig-cache/o/<digest>/options.zig:1:1: error: file exists in modules 'dep_a_opts' and 'dep_b_opts'
note: files must belong to only one module
```

This hits the same library used at two versions in one tree, or two unrelated
libraries whose options happen to match. Workaround: add a dummy option with
a unique value.

## Evidence

- codeberg#31613 (0.16.0-dev.2565), with a second real-world report in the
  comments.
- Reproduced on 0.17.1, aarch64-macos: `app` -> path dep `dep_a` -> path dep
  `dep_b`, both deps adding a one-bool options module; `zig build` in `app`
  prints the error above.

## Root cause

`lib/compiler/Maker/Step/Options.zig:75-82`: the output path is
`o/<digest>/options.zig` where the digest covers only the file contents and
args, so identical contents from different steps share one file. The
compiler then refuses one file as the root of two modules.

## Fix sketch

Not settled. Options: mix a per-step identity (owning package plus step
index) into the digest, which costs some cache sharing; or let the compiler
accept a file that is the root of several modules when it is a generated
leaf. The first is small.

## Verification

The three-package reproduction builds. Add a standalone test.

## Notes

Not fixed on origin/master. Same error shape as cb32034, different cause.
