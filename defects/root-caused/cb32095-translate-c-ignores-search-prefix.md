---
title: zig build --search-prefix does not add include paths to TranslateC steps
priority: 1
area: build-system
targets: [all]
upstream: [codeberg#32095]
affects-line: yes
---

## Symptom

`zig build --search-prefix $HOME` adds `-I $HOME/include` and `-L $HOME/lib` to
compile steps but not to `b.addTranslateC` steps, so translating a header that
includes a prefix-installed header fails:

```
src/pEp.c:1:10: error: 'pEp/keymanagement.h' not found
failed command: zig translate-c --cache-dir .zig-cache ... src/pEp.c --listen=-
```

## Evidence

- codeberg#32095 (0.16.0, macOS).
- Read at 0.17.1: see Root cause. Not reproduced.

## Root cause

`lib/compiler/Maker/Step/Compile.zig:778-804` loops over
`graph.search_prefixes` and appends `-L <prefix>/lib` and
`-I <prefix>/include` when those directories exist.
`lib/compiler/Maker/Step/TranslateC.zig` (`make`, from line 13) builds its
argv without that loop; it has no reference to `search_prefixes`.

## Fix sketch

Factor the search-prefix loop out of `Compile.zig` and call it from
`TranslateC.make` (only the `-I` half is needed). About 20 lines. While there,
check whether `graph.sysroot` (`Compile.zig:772`) and `graph.libc_file`
(`Compile.zig:658-663`) should also reach `zig translate-c`; TranslateC
forwards neither (not verified whether that matters).

## Verification

Install a header under `<prefix>/include/x/y.h`, translate a C file that
includes `<x/y.h>` with `zig build --search-prefix <prefix>`: the translate-c
command line contains `-I <prefix>/include` and succeeds.

## Notes

Not fixed on origin/master.
