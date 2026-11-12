---
title: One-line statement of the defect
priority: 2 # 1 | 2 | 3, see README.md
area: lib/std # compiler | codegen | linker | zig-cc | build-system | lib/std | bundled-libc | translate-c | target-defs | upstream-llvm
targets: [all] # e.g. [aarch64-ios, loongarch64-linux-gnu], or [all]
upstream: [] # e.g. [codeberg#31427, github#22807]
affects-line: unknown # yes | likely | unknown | no
---

## Symptom

What a user sees: the error text, crash, or wrong behavior, and the smallest
known way to trigger it.

## Evidence

Where this was observed: upstream issue ids, project file:line, commits, PRs.
Say what was reproduced and on which Zig version, and what is only reported.

## Root cause

The responsible code on this line, as `path:line`, and why it misbehaves.
Write "Not investigated." when unknown. Mark guesses as guesses.

## Fix sketch

The shape of the fix and a rough size. Write "Not investigated." when unknown.

## Verification

How to tell it is fixed: a reproduction command, a test to add or re-enable.

## Fix

Added when the entry moves to `fixed/`: what was changed and where, and how it
was verified. For a fix taken from upstream, the upstream commit.

## Notes

Anything else: related entries (by slug), upstream's stance.
