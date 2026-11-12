---
title: A panic while the Mach-O unwinder holds its mutex deadlocks the panic handler instead of printing a trace
priority: 2
area: lib/std
targets: [aarch64-macos, x86_64-macos, aarch64-ios, aarch64-ios-simulator, aarch64-maccatalyst]
upstream: []
affects-line: yes
---

## Symptom

A panic raised while `std.debug.SelfInfo` (Mach-O backend) is unwinding or
symbolizing hangs forever instead of printing a stack trace and aborting. The
panic handler tries to produce a stack trace, re-enters the same unwinder on the
same thread, and blocks on the mutex that the interrupted call still holds.

Reported symptom (Zig 0.16.0, macOS 27 arm64):
- A test using a `DebugAllocator` with allocation stack traces (the default for
  `std.testing.allocator`) hung. The DebugAllocator captures a stack trace on
  every allocation.
- A standalone test allocating 8 bytes on one pthread reproduced it.
- LLDB stopped at `lib/std/debug/SelfInfo/MachO.zig:390` with compact-unwind
  encoding `0x05000001`.

What happened there:
1. Allocation-trace capture entered the unwinder and took its mutex.
2. A safety panic fired inside the locked region, because mode 5 was not a
   valid `UNWIND_ARM64_MODE` tag in 0.16.0.
3. `std.debug.defaultPanic` called `writeCurrentStackTrace`, which re-entered
   the unwinder and blocked on the held mutex.

## Evidence

- Reported: hang on 0.16.0, macOS 27.0.1, Xcode 26.4.1, arm64. The trigger (mode 5) is fixed in 0.17.1; the deadlock
  mechanism is not.
- Not reproduced here. The investigation host is macOS 26, whose libraries do
  not use mode 5, and there is no other known way to make code inside the
  locked region panic on demand.
- Verified by reading the code at 0.17.1 (see Root cause): the lock is still
  taken without re-entrancy protection, and a panic in the locked region still
  skips the `defer` that releases it.
- Verified: the trigger fix landed on the 0.17.x branch as `f8f4abab94` (merge
  of PR #37318 "`std.debug.SelfInfo.MachO`: fix a few bugs", 2026-10-18; in tag
  0.17.1, not 0.17.0). On master it is `01417356c9` ("std.macho: add new
  UNWIND_ARM64_MODE.FRAME_PAUTH_LR tag") and `f03e7e318a`
  ("std.debug.SelfInfo.MachO: handle new UNWIND_ARM64_MODE.FRAME_PAUTH_LR").

## Root cause

Verified by reading `lib/std/debug/SelfInfo/MachO.zig` at 0.17.1:

- `findModule` (`:464`, doc comment "Acquires the mutex on success.") takes the
  non-recursive `si.mutex` (`Io.Mutex`, field at `:1`) at `:484`. Only an
  `errdefer` releases it (`:485`).
- Callers release it with `defer`: `getSymbols` (`:38`), `getModuleSlide`
  (`:122`), `unwindFrameInner` (`:170`). A panic does not run defers, so a
  safety panic or `unreachable` anywhere in these regions leaves the mutex
  locked. That includes compact-unwind decoding (`:294-440`), DWARF CFI
  (`context.computeRules`) and `module.getUnwindInfo`.
- `lib/std/debug.zig:511` `defaultPanic` at `panic_stage == 0` (`:578-606`)
  calls `writeCurrentStackTrace` with `allow_unsafe_unwind = true`. That reaches
  `unwindFrame` → `unwindFrameInner` → `findModule` → `si.mutex.lock` on the same
  thread, and blocks.
- The recursion guards (`panic_stage` threadlocal at `:494`, `panicking`
  counter at `:490`) handle a second panic, not a blocking lock, so they never
  fire.
- Still-latent triggers (verified by reading): `lib/std/macho.zig:2106-2112`
  (`UNWIND_X86_64_MODE`) and `:2135-2141` (`UNWIND_ARM64_MODE`) are exhaustive
  `enum(u4)` with no `_`. Any future Apple encoding (arm64 values 1 and 6-15,
  x86_64 values 5-15) bit-cast from `__unwind_info` is an invalid tag. The
  `switch (encoding.mode.arm64)` at `SelfInfo/MachO.zig:406` (and `.x86_64` at
  `:298`) then safety-panics in Debug/ReleaseSafe. That is the same panic-
  inside-lock path that caused the original hang.
- master: unchanged. Verified: `origin/master`'s
  `lib/std/debug/SelfInfo/MachO.zig` has the same lock/unlock sites (`:38`,
  `:122`, `:170`, `:484-485`) and no `tryLock`.
- Inferred, not checked in depth: the ELF backend has the same shape.
  `lib/std/debug/SelfInfo/Elf.zig` takes an exclusive `rwlock` at `:44` and
  `:226` and shared locks at `:106`, `:113`, `:216`, `:410`, all released by
  `defer`. A panic inside the exclusive section, followed by the panic handler
  taking the shared lock, would deadlock the same way. The Windows backend
  (`Windows.zig:38-65`) takes only shared locks.

## Fix sketch

Two independent parts, together a few dozen lines:

1. **Re-entrancy guard.** Add a `threadlocal var unwinder_depth: u8` (or an
   owner-thread id) to `SelfInfo/MachO.zig`, set while the mutex is held.
   - In `findModule`, `getSymbols` and `getModuleSlide`: if the current thread
     already holds the lock, return `error.UnsupportedDebugInfo` (or
     `MissingDebugInfo`) instead of locking. The panic handler then prints
     "unable to unwind" for that frame and still aborts.
   - Alternatively, when `std.debug` is panicking (`panic_stage != 0`), use
     `Io.Mutex.tryLock` (exists, `lib/std/Io.zig:1727`) and bail on failure.
     This also covers the case where another thread panicked while holding the
     lock.
   - Apply the same to `SelfInfo/Elf.zig`.
2. **Unknown encodings fail softly.** Make `UNWIND_ARM64_MODE` and
   `UNWIND_X86_64_MODE` non-exhaustive (add `_`), and add
   `_ => return error.UnsupportedDebugInfo` arms at `SelfInfo/MachO.zig:298` and
   `:406`.
   - Check other users of these enums (`src/link/MachO` writes compact unwind)
     for exhaustive switches that would need an `else`.

## Verification

- Unit test: call the unwinder from inside a fake locked region, either by
  setting the guard by hand or by a test hook that panics while the lock is
  held, using a panic handler override that records whether
  `writeCurrentStackTrace` returned. Expect no hang.
- Regression for part 2: bit-cast a `CompactUnwindEncoding` with arm64 mode 6
  and check that `unwindFrame` returns `error.UnsupportedDebugInfo` in
  ReleaseSafe instead of panicking.
- End to end (needs a macOS that emits a new mode, so not currently possible):
  the reported reproduction, a `DebugAllocator` with default
  `stack_trace_frames` allocating on a spawned thread, should print a trace and
  not hang.

## Notes

- Upstream issue: not searched.
- Workaround:
  - Use a `DebugAllocator(.{ .stack_trace_frames = 0 })` so allocations do not
    enter the unwinder.
  - It is needed only for the 0.16.0 mode-5 trigger, which 0.17.1 already
    fixes, so it is unnecessary on 0.17.1 even before this hardening.
  - This entry is what keeps the next unknown Apple encoding from turning into a
    hang again.
