---
title: "Signed vector <<| with a runtime shift amount produces invalid LLVM bitcode (\"Invalid record\")"
priority: 1
area: codegen
targets: [all]
upstream: [codeberg#31116, github#19635]
affects-line: yes
---

## Symptom

```zig
fn u32Splat(val: u32) @Vector(2, u32) { return @splat(val); }
pub fn main() !void {
    const vec = @Vector(2, i32){ 100, 100 };
    const result = vec <<| u32Splat(16);
    std.debug.print("result: {}\n", .{result});
}
```

fails to compile in Debug with
`error: Invalid record (Producer: 'zig 0.17.1' Reader: 'LLVM 22.1.8')`.
With a comptime-known shift vector it compiles.

## Evidence

- codeberg#31116, reported on 0.16.0-dev.2354.
- Reproduced on 0.17.1 (aarch64-macos, `zig build-exe`, Debug): exact error
  above. The same program with `@Vector(2, u32)` as the left operand compiles
  and prints `{ 6553600, 6553600 }`, so only the signed path is broken.

## Root cause

`src/codegen/llvm/FuncGen.zig:4450-4457` (`airShlSat`, signed branch) calls
`minIntConst(&o.builder, lhs_ty, llvm_lhs_ty, zcu)` and `maxIntConst(...)`
with the *vector* LLVM type, then `splatValue`s the result. `minIntConst`
(`FuncGen.zig:8149`) builds `intConst(as_ty, ...)` with that vector type, so
the splat operand is not a scalar of the element type. The unsigned branch
uses `llvm_lhs_scalar_ty` and works. (Diagnosis from reading the code; not
confirmed with a patched build.)

## Fix sketch

Pass `lhs_ty.scalarType(zcu)` and `llvm_lhs_scalar_ty` to `minIntConst` /
`maxIntConst` in the signed branch. Two-line change.

## Verification

The snippet compiles and prints `{ 6553600, 6553600 }` (100 << 16 fits in
i32). Add a behavior test
for signed vector `<<|` with runtime shift amounts, including saturating
cases, in `test/behavior/vector.zig`.

## Notes

Same code on origin/master (`FuncGen.zig:4520`).
