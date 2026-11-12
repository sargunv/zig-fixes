// compiler_rt must provide the ARM EABI helpers that LLVM calls on this target.

var a: u64 = 0xFEDCBA9876543210;
var d: f64 = 1.5;

pub const panic = @import("std").debug.no_panic;

pub export fn _start() callconv(.c) noreturn {
    const x = @as(*volatile u64, &a).*;
    const y = @as(*volatile f64, &d).*;
    a = x / 7 + @as(u64, @intFromFloat(y * 3.0));
    while (true) {}
}

// compile
// output_mode=Exe
// backend=llvm
// target=arm-linux-ohoseabi
