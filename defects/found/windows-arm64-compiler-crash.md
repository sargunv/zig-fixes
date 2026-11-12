---
title: Native aarch64-windows Zig exits with no diagnostic (access violation) on any invocation, and x86_64 Zig under emulation hangs
priority: 1
area: upstream-llvm
targets: [aarch64-windows-msvc, aarch64-windows-gnu]
upstream: [codeberg#31865, codeberg#35796]
affects-line: unknown
---

## Symptom

On a Windows ARM64 host (GitHub `windows-11-arm` runners), the native
`zig-aarch64-windows` release exits non-zero with no output while loading
`build.zig`. Upstream reports exit code `-1073741819` (0xC0000005, access
violation) for "literally any invocation". The x86_64 Windows release run
under Windows' x64 emulation instead hangs in `zig build` until the CI job
times out.

## Evidence

- Observed on a GitHub `windows-11-arm` runner: native aarch64 Zig 0.16.0
  exits non-zero with no diagnostic while loading `build.zig`, so the
  emulated build was not the problem.
  - Before that, 12 Windows ARM64 jobs out of 120 runs hung, all in
    `zig build` under x86_64 emulation.
  - GitHub reports timed-out jobs as `cancelled`.
- No evidence shows that 0.17.0 or 0.17.1 was run on Windows ARM64.
- Upstream https://codeberg.org/ziglang/zig/issues/31865 (opened 2026-04-15
  against 0.16.0, closed 2026-10-07):
  - Same crash on any invocation.
  - A commenter worked around it by using the x86_64 Windows Zig on ARM.
  - alexrp reduced it to LLVM IR, filed https://github.com/llvm/llvm-project/issues/199581,
    and noted upstream had no aarch64-windows hardware.
  - LLVM fixed it in two commits, per the issue.
- Upstream aarch64-windows CI is still not enabled:
  https://codeberg.org/ziglang/zig/issues/35796 (open).
- Not reproduced here: no Windows ARM64 hardware was available.

## Root cause

For the native crash: upstream LLVM, per codeberg#31865. Not reproduced, but
read from the issue and the commits.
- LLVM's AArch64 COFF backend mis-encodes the TLS access sequence when a
  module mixes `private` thread_local globals with non-private ones. The
  `AArch64AsmBackend.cpp` fixup for `add_imm12`/`ldst_imm12` lacks the
  `>> 12` for the `HI12` specifier.
- Zig emits `private` linkage for internal globals whenever it strips, so the
  Zig compiler itself, which is stripped, crashes on its own thread-locals.
- Zig worked around it in b3747dd707 ("llvm: work around upstream
  aarch64-windows bug for private thread_local symbols", 2026-05-26). The
  workaround uses `.internal` instead of `.private` for thread-locals on
  aarch64 COFF. It is in both 0.17.0 and 0.17.1 (verified at
  `src/codegen/llvm.zig:994` in 0.17.1).
- master reverted the workaround in 66cd872dff after moving to an LLVM with
  the fix.
- So the 0.16.0 crash should not happen on 0.17.x (inferred: 0.17.x has not
  been run on Windows ARM64 hardware).

For the hang of x86_64 Zig under emulation: not investigated, cause unknown.

## Fix sketch

The next step is a retest, not a code change: run native aarch64 Zig 0.17.1 on
Windows ARM64 hardware, for example a GitHub `windows-11-arm` runner.

- **If it works:** close this.
- **If it still fails:** capture the crash with a debugger (WinDbg) or
  `ZIG_DEBUG_CMD`/`--verbose-*` flags, check whether it is another LLVM COFF
  TLS issue, and consider backporting the LLVM fix from
  llvm/llvm-project#199581 into the fork's LLVM build. Size unknown.
- The emulation hang matters only if native Zig keeps failing. Not
  investigated.

## Verification

- On a Windows ARM64 host, with the native 0.17.1 release:
  - `zig version` runs.
  - `zig build --help` runs in a project.
  - `zig build test` passes in a nontrivial project.
- The reduced reproduction from codeberg#31865: `zig build-lib -dynamic repro.zig -target aarch64-windows-gnu -lc`
  with `threadlocal var x: u32 = undefined; pub export fn foo() u32 { return x; }`.
  Disassemble `foo` and check that the TLS offset load is correct.

## Notes

- Cross-compiling from x86_64 to aarch64-windows works, per codeberg#31865.
