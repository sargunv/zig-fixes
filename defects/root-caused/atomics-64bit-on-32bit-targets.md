---
title: 64-bit atomics are rejected at compile time on 32-bit ARM and x86, though the CPUs (and Clang) support them lock-free
priority: 1
area: compiler
targets: [arm-linux-androideabi, arm-linux-gnueabihf, arm-linux-musleabihf, x86-linux-gnu, x86-linux-android]
upstream: []
affects-line: yes
---

## Symptom

Any 64-bit atomic operation on a 32-bit ARM or 32-bit x86 target fails at
compile time, including `std.atomic.Value(u64)`:

```
lib/std/atomic.zig:53:31: error: expected 32-bit integer type or smaller; found 64-bit integer type
            return @atomicRmw(T, &self.raw, .Add, operand, order);
                              ^
```

Minimal reproduction (`at.zig`):

```zig
const std = @import("std");
var v: std.atomic.Value(u64) = .init(0);
export fn bump() u64 { return v.fetchAdd(1, .seq_cst); }
```

```
zig build-obj at.zig -target arm-linux-gnueabihf -O ReleaseFast              # error
zig build-obj at.zig -target arm-linux-gnueabihf -mcpu cortex_a9 -O ReleaseFast  # error
zig build-obj at.zig -target x86-linux-gnu -O ReleaseFast                    # error
zig build-obj at.zig -target aarch64-linux-gnu -O ReleaseFast                # ok
```

The same error comes from `@atomicLoad`/`@atomicStore` (`lib/std/atomic.zig:21`
and `:25`).

## Evidence

- Verified (reproduced with 0.17.1 and 0.16.0): the commands above. Both
  versions fail identically for `arm-linux-gnueabihf`; 0.17.1 also fails for
  `x86-linux-gnu`.
- Verified (reproduced with 0.16.0): a library that keeps a `u64` timestamp
  in an atomic cannot be built for `arm-linux-android.26` (Android
  armeabi-v7a):

  ```
  lib/std/atomic.zig:21:32: error: expected 32-bit integer type or smaller; found 64-bit integer type
              return @atomicLoad(T, &self.raw, order);
  ```
- Verified: Clang (through `zig cc` 0.17.1) does these lock-free on the same
  targets. Test file:

  ```c
  #include <stdint.h>
  uint64_t ld(uint64_t *p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
  void st(uint64_t *p, uint64_t v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }
  uint64_t add(uint64_t *p, uint64_t v) { return __atomic_fetch_add(p, v, __ATOMIC_SEQ_CST); }
  int lf(void) { return __atomic_always_lock_free(8, 0); }
  ```

  - **ARMv7-A** (`zig cc -target arm-linux-gnueabihf -O2 -S`): load, store and
    fetch-add are inline `ldrexd`/`strexd` loops with no libcalls, and
    `__atomic_always_lock_free(8, 0)` folds to `mov r0, #1`. Also verified:
    `-target arm-linux-androideabi` gives the same `ldrexd`/`strexd` code.
  - **i686** (`-target x86-linux-gnu`, Zig's default x86 CPU is `pentium4`):
    - With plain `uint64_t *` Clang emits `__atomic_load`/`__atomic_store`/
      `__atomic_compare_exchange` libcalls, with `-Watomic-alignment` "expected
      alignment (8 bytes) exceeds the actual alignment (4 bytes)". This is
      because `uint64_t` is only 4-byte aligned in the i386 SysV ABI.
    - With `typedef uint64_t u64a __attribute__((aligned(8)))` it emits inline
      `lock cmpxchg8b` (and an SSE `movq` for the load).
    - With `-mcpu=i386` (no `cx8`) it emits `__atomic_*_8` libcalls and warns
      "max lock-free size (4 bytes)".

    So Clang's rule on x86 is: lock-free 64-bit when `cx8` is present and the
    object is 8-byte aligned.
  - `__atomic_always_lock_free(8, 0)` also folds to 1 on x86.
- Aside, not this defect (verified): `zig cc -target arm-linux-android` (abi
  `android` rather than `androideabi`) fails with `unsupported option
  '-mfloat-abi=hard' for target 'armv7-unknown-linux5.10.0-android29'`.
  `-target arm-linux-androideabi` works. This may deserve its own entry.

## Root cause

- Verified by reading the code: `src/Zcu.zig:4123-4176`
  (`Zcu.atomicPtrAlignment`).
  - The switch at `:4129-4144` gives explicit maxima only for ez80/spork8 (8),
    aarch64 (128), mips64 (64) and x86_64 (64, or 128 with `cx16`).
  - Every other architecture falls to `else => target.ptrBitWidth()`, i.e. 32 on
    arm/armeb/thumb/thumbeb and x86, regardless of CPU features.
  - Sema reports the result at `src/Sema.zig:22916` ("expected {d}-bit integer
    type or smaller").
- The function always returns `.none` (natural ABI alignment) for ints
  (`:4158-4172`). Zig's `@alignOf(u64)` is 4 on `x86-linux-gnu` and 8 on
  `arm-linux-gnueabihf` (verified with `@compileLog`). Simply raising the x86
  limit would therefore allow 64-bit atomics on 4-aligned objects. Clang treats
  those as not lock-free; a misaligned `lock cmpxchg8b` is a split lock.
- Related, verified by reading: compiler-rt's fallback atomics use the same
  pointer-width threshold. `lib/compiler_rt/atomics.zig:29-38`
  (`largest_atomic_size = @sizeOf(usize)`, with the comment "XXX: On
  x86/x86_64 we could check the presence of cmpxchg8b/cmpxchg16b"). Its
  `__atomic_*_8` (from `:189`) therefore take a spinlock on these targets.
- History: `git blame` shows the switch was last reshaped by `cd56b06352`
  ("Zcu: simplify atomicPtrAlignment()", 2025-10-19), plus the ez80 addition
  `17e0afd0e5`.
- master: unchanged. Verified: `origin/master` `src/Zcu.zig:4243-4263` has the
  same `else => target.ptrBitWidth()`, only with more mips64 tags.

## Fix sketch

1. In `atomicPtrAlignment`, add arms (about 10 lines):
   - `.arm, .armeb, .thumb, .thumbeb`: 64 when the CPU has `ldrexd`/`strexd`.
     That is v6K or later and not M-profile (`has_v6k` or `has_v7`, and not
     `mclass`); otherwise 32. Check the exact feature names in
     `lib/std/Target/arm.zig`.
   - `.x86`: 64 when `cpu.has(.x86, .cx8)`, else 32.
2. For x86, when the 64-bit path is taken, return an explicit 8-byte alignment
   requirement instead of `.none`, so `*u64` (4-aligned) is rejected or needs
   `*align(8) u64`.
   - `std.atomic.Value(u64)` would then need `align(8)` on its field for x86.
     Check `lib/std/atomic.zig`; it may already over-align for cache lines.
   - This matches Clang's rule above.
3. Make compiler-rt agree: `lib/compiler_rt/atomics.zig` `largest_atomic_size`
   should be 8 on those same CPUs. Otherwise a 64-bit object accessed inline by
   Zig code and through `__atomic_*_8` by C code built against Zig's
   compiler-rt would use two different synchronization schemes. (Inferred risk;
   Clang inlines on ARMv7 so it would rarely call `__atomic_*_8` there.)
4. Optional, larger: instead of a compile error, lower atomics wider than the
   limit to `__atomic_*` libcalls, as Clang does.

Rough size: a few dozen lines including tests. Codegen needs no change for
ARMv7 or i686 with `cx8`, since LLVM already lowers 64-bit atomics there (Clang
proves it). The self-hosted x86 backend is unchecked, so inferred only.

## Verification

- `zig build-obj at.zig -target arm-linux-gnueabihf -O ReleaseFast` compiles,
  and `-femit-asm` shows `ldrexd`/`strexd` with no `__atomic_` calls.
- `-target x86-linux-gnu`: compiles when the value is 8-aligned and emits
  `lock cmpxchg8b`. A 4-aligned `*u64` is a compile error.
- `-target x86-linux-gnu -mcpu i386` and `-target thumb-freestanding-none -mcpu
  cortex_m3`: still the 32-bit error.
- Add behavior tests for `std.atomic.Value(u64)` on `arm-linux-gnueabihf` and
  `x86-linux-gnu` (run under QEMU).

## Notes

- Upstream issue: not searched.
