---
title: zig cc as a CMake toolchain lacks standalone binutils (no nm at all) and reports no implicit multiarch link directories
priority: 2
area: zig-cc
targets: [x86_64-linux-gnu, aarch64-linux-gnu, riscv64-linux-gnu, loongarch64-linux-gnu, x86_64-linux-musl, aarch64-linux-musl, x86_64-freebsd]
upstream: []
affects-line: yes
---

## Symptom

Using `zig cc`/`zig c++` as `CMAKE_C_COMPILER`/`CMAKE_CXX_COMPILER` for Linux and
FreeBSD cross builds needs extra toolchain-file work that a GCC or Clang
toolchain does not:

1. **No standalone binutils.**
   - `zig ar`, `zig ranlib` and `zig objcopy` exist only as subcommands of the
     `zig` binary. CMake wants one executable path per tool (`CMAKE_AR`,
     `CMAKE_RANLIB`, `CMAKE_OBJCOPY`), and its Clang heuristics look for
     `llvm-ar` etc. next to the compiler.
   - There is no `nm` (and no `strip`) at all.
   - Host binutils only know the host architecture, so cross builds need another
     LLVM toolchain just for these tools.
2. **No implicit link directories.** CMake derives
   `CMAKE_C_IMPLICIT_LINK_DIRECTORIES` and `CMAKE_LIBRARY_ARCHITECTURE` from the
   compiler's verbose link line. `zig cc` with an explicit `-target` passes no
   system `-L` directories, so `CMAKE_LIBRARY_ARCHITECTURE` stays empty. Then
   `find_library` never searches the Debian multiarch directory
   (`/usr/lib/x86_64-linux-gnu`), where system libraries such as the Vulkan and
   EGL loaders live.

## Evidence

- Verified (0.17.1, `zig --help`): subcommands `ar`, `dlltool`, `lib`,
  `objcopy`, `objdump`, `ranlib`, `rc`. There is no `nm` or `strip`.
- Verified (0.17.1):

  ```
  zig cc -target x86_64-linux-gnu.2.17 -v m.c -o m
  ```

  The final `ld.lld` line contains only `-L/` and Zig-cache paths for libc
  stubs. There is no `/usr/lib/<multiarch>` or `/lib/<multiarch>` directory.
  (Where the lone `-L/` comes from was not investigated.)
- What a working CMake toolchain file for `zig cc` has to do today:
  - Take `llvm-ar`, `llvm-nm`, `llvm-objcopy`, `llvm-objdump` and
    `llvm-strip` from another LLVM toolchain (for example the Rust toolchain's
    `llvm-tools` component), take `ld.lld` from elsewhere (for example Rust's
    `gcc-ld`), and write a `ranlib` shim running `llvm-ar s`.
  - Set `CMAKE_LIBRARY_ARCHITECTURE` to `<arch>-linux-gnu` by hand.
  - Wrap the driver in a script, because CMake wants one executable path and
    `zig` takes its mode in `argv[1]`.

## Root cause

- Binutils, verified: `zig` dispatches tools by subcommand (`src/main.zig`), and
  there is no `nm` implementation in the tree (only `objcopy`/`objdump` under
  `lib/compiler/`). This is a design gap more than a bug: Zig ships one binary.
- Link directories, verified by reading `src/main.zig:4225-4245`. Native system
  library paths (`std.zig.system.NativePaths.detect`, which knows the multiarch
  directories) are added only when all of these hold:
  - `create_module.sysroot == null`
  - `resolved_target.is_native_os` and `is_native_abi`
  - `want_native_include_dirs`

  A CMake toolchain passes an explicit `-target ...-linux-gnu.2.17`. That is
  never "native" in this sense, even on a same-architecture host. So no system
  `-L` appears for CMake to parse. This is deliberate hermeticity. The gap is
  that there is no opt-in way to say "same OS, use the host's library
  directories". Inferred: `-L/` on the link line does not help CMake's parser.

## Fix sketch

- **Binutils** (zig-cc glue, small to medium):
  - Make `zig` dispatch on `argv[0]` basename (`ar`, `ranlib`, `objcopy`,
    `llvm-ar`, `cc`, `c++`, ...), busybox style, so a symlink farm works without
    shell shims. About 30 lines in `src/main.zig`.
  - Add a minimal `zig nm`: LLVM's `llvm-nm` is already linked into the
    compiler for `ar`/`ranlib` (inferred; check `src/main.zig` how `ar` is
    dispatched), so exposing it is likely tens of lines.
  - Possibly `zig strip` as a thin `objcopy --strip-all`.
- **Link directories** (zig-cc glue, small):
  - Add an opt-in flag or env var (e.g. `-fnative-lib-dirs`) that runs
    `NativePaths.detect` for a non-native target whose OS and arch match the
    host, and prints the resulting `-L` dirs on the `-v` link line.
  - Or simply emit the matching `/usr/lib/<arch>-linux-gnu` when `--sysroot` is
    given.
  - About 20-40 lines.

## Verification

- With a CMake project using a toolchain file that sets only
  `CMAKE_C_COMPILER=zig-cc` (symlink), `CMAKE_AR=zig-ar` and
  `CMAKE_RANLIB=zig-ranlib` (symlinks to `zig`): configure succeeds,
  `CMAKE_NM`/`CMAKE_OBJCOPY` resolve, and with the opt-in link-dir flag
  `CMAKE_LIBRARY_ARCHITECTURE` comes out as `x86_64-linux-gnu`.
- The toolchain file then needs no LLVM tools from another toolchain and no
  hand-set `CMAKE_LIBRARY_ARCHITECTURE`.

## Notes

These are defaults rather than defects, recorded here because a CMake
toolchain file for `zig cc` has to override them:

- **16 MiB default stack size.**
  - Verified: `src/link/Lld.zig:221-224` (16 MiB unless wasm freestanding) and
    `src/link/Elf.zig:265` (`options.stack_size orelse 16777216`) pass
    `-z stack-size=16777216`. Seen on the 0.17.1 `-v` link line.
  - musl sizes default thread stacks from the executable's `PT_GNU_STACK`
    (capped at 8 MiB, according to musl's sources; not checked first-hand), so
    every thread of a Zig-linked musl executable gets a far larger stack than
    musl's 128 KiB default.
  - Workaround: link musl executables with `-Wl,-z,stack-size=131072`.
  - A fork could choose a smaller default for musl, or skip `-z stack-size` when
    the user did not ask. That is a one-line policy change.
- **FreeBSD 14.0 floor.**
  - Verified: `lib/std/Target.zig:526-540` defaults the FreeBSD minimum to 14.0,
    and `src/libs/freebsd.zig:438-440` maps release N to symbol version
    `FBSD_1.(N-7)`.
  - The floor is hard for executables (verified, 0.17.1):

    ```
    zig cc -target x86_64-freebsd.13.0-none m.c -o m
    ld.lld: error: undefined symbol: __libc_start1
    >>> referenced by crt1_s.S:80 (lib/libc/freebsd/lib/csu/amd64/crt1_s.S:80)
    ```

    The same happens with `freebsd.12.0`. The bundled csu `crt1` comes from
    FreeBSD 14 and calls `__libc_start1`, which the older symbol-version stubs
    do not export.
  - A shared library does link for 13.0 (`zig cc -target
    x86_64-freebsd.13.0-none -shared s.c` succeeds, verified).
  - Supporting older executables would need per-version csu (or a `crt1` that
    falls back to `__libc_start`). That is medium-sized.
- Other `zig cc` friction for a CMake toolchain, not filed separately:
  - Vendored libc++ headers raise `-Wnullability-completeness`, which the
    toolchain file has to silence.
  - libc++ is always linked statically, so a static archive built this way
    bundles it.
- The related `zig cc` defects (four-part LLVM triples rejected, unknown
  linker flags fatal) are filed separately, not in this file.
