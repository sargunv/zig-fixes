---
title: -rdynamic does not keep executable symbols under dead stripping on macOS (or export them on Windows)
priority: 1
area: linker
targets: [aarch64-macos, x86_64-macos, x86_64-windows-gnu]
upstream: [codeberg#36088]
affects-line: yes
---

## Symptom

An executable built with `rdynamic = true` in a release mode (dead stripping on
by default) loses global C functions it does not reference itself, so plugins
loaded with `dlopen` fail: Neovim's macOS build reports
`symbol not found in flat namespace '_lua_tothread'`. The same build for
x86_64-windows-gnu does not export the symbol either; x86_64-linux-musl works.

## Evidence

- Reported on 0.17.0-dev.1267 with a build.zig + test script, real-world
  impact neovim/neovim#40622 (codeberg#36088).
- Reproduced on 0.17.1 natively (aarch64-macos): `zig build-exe main.c
  libapi.a -lc -O ReleaseFast -rdynamic` has no `_plugin_api_symbol`
  (`nm -gU`), also when `api.c` is passed directly; with `--no-gc-sections`
  the symbol is present. Windows case not run.

## Root cause

- Mach-O: `src/link/MachO/dead_strip.zig:24` only treats global symbols as
  roots for dylibs (`macho_file.base.isDynLib() and sym.visibility == .global`);
  `comp.config.rdynamic` is not consulted, so release builds strip them.
- COFF: `src/link/Lld.zig` passes `--export-dynamic` for ELF (line 969) and
  wasm (line 1528) but has no rdynamic handling for lld-link.

## Fix sketch

Mach-O: also root global, non-hidden symbols when `comp.config.rdynamic` and
output is an executable (one-line condition). COFF: decide whether rdynamic
should export all external symbols (e.g. generate `-export:` per symbol or an
`/EXPORT` list); larger and needs a design call.

## Verification

Reproduction above: `nm -gU exe | grep _plugin_api_symbol` finds it with
ReleaseFast. Add a `test/link/macho.zig` case for rdynamic + dead_strip.

## Notes

Workaround: `link_gc_sections = false` on macOS.
