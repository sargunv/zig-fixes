---
title: zig cc rejects LLVM/GCC-style target triples with a vendor field, such as --target=x86_64-unknown-linux-gnu
priority: 1
area: zig-cc
targets: [all]
upstream: []
affects-line: yes
---

## Symptom

```
$ zig cc --target=x86_64-unknown-linux-gnu -c x.c -o t.o
error: unable to parse target query 'x86_64-unknown-linux-gnu': UnknownOperatingSystem
```

Build tools that pass clang-style triples, notably cc-rs (used by the `ring`
crate's build script, among many others), fail when `zig cc` is the C
compiler, even though clang accepts these triples.

## Evidence

- Reproduced on Zig 0.17.1.
- cc-rs passes the four-component LLVM triple `x86_64-unknown-linux-gnu`,
  which Zig reads as os="unknown".
- No upstream issue found.

## Root cause

Verified by reading code at 0.17.1.
- In `zig cc` mode, `src/main.zig:1998` stores clang's `--target`/`-target`
  value directly (`.target => target_arch_os_abi = it.only_arg`). The plain
  `-target` path is at `src/main.zig:1415-1416`.
- The value then goes to Zig's own triple parser,
  `std.Target.Query.parse` (`lib/std/Target/Query.zig:226-260`). That parser
  expects `arch-os[.ver]-abi[.ver]` with no vendor field, so the vendor
  `unknown` is read as the OS, and `parseOs`
  (`lib/std/Target/Query.zig:567-573`) returns `error.UnknownOperatingSystem`.
- There is no LLVM-triple normalization step. Other LLVM spellings also fail
  or mismatch, for example `aarch64-apple-darwin`, `armv7-linux-androideabi`
  (arch `armv7`), `i686-…`, and `riscv64gc-…` (inferred from the parser; not
  each tried).

origin/master: `Query.zig` was refactored (about 196 lines changed), but no
vendor handling was found (not exhaustively checked).

## Fix sketch

Two options:

1. **Normalize LLVM triples in `zig cc` mode only (a few dozen lines).**
   - When `--target`/`-target` comes through the clang argument iterator and
     has four components, or a known vendor (`unknown`, `pc`, `apple`, `none`,
     `w64`, `linux` as vendor), drop the vendor.
   - Map LLVM OS and environment names to Zig's: `darwin`→`macos`,
     `gnueabihf` etc. pass through, `androideabi`, `windows-msvc`/`windows-gnu`.
   - Map LLVM arch spellings: `i686`→`x86`, `armv7`→`arm` plus CPU features,
     `riscv64gc`→`riscv64`.
   - Then call `Query.parse`. Keep `zig build-exe -target` strict.
   - There is prior art for this mapping in the reverse direction:
     `std.Target.Query.zigTriple` and `src/codegen/llvm.zig`'s
     `targetTriple`.
2. **Teach `Query.parse` an optional vendor slot.** Broader, and it changes a
   public std API used by build scripts. Not recommended.

## Verification

- `zig cc --target=x86_64-unknown-linux-gnu -c x.c` succeeds and produces an
  ELF x86-64 object.
- Same for `aarch64-unknown-linux-gnu`, `x86_64-unknown-linux-musl`,
  `riscv64gc-unknown-linux-gnu`, `x86_64-unknown-freebsd`, and
  `aarch64-apple-darwin`.
- Building a crate that depends on `ring` with `CC_<target>` set to plain
  `zig cc` works without a wrapper.

## Notes

- **Workaround today:** call `zig cc` through a wrapper script that drops
  every incoming `--target=`, `--target`, and `-target` and always appends its
  own Zig triple. A side effect: one wrapper can't serve two targets, so each
  target needs its own. A wrapper stays useful after a fix to fold `cc`/`c++`
  into one executable path for CMake and cc-rs, and to pin the glibc floor in
  the triple (`x86_64-linux-gnu.2.17`), because an LLVM triple carries no
  glibc version.
- Related: `zig-cc-unknown-linker-args.md`, worked around in the same kind of
  wrapper.
