const std = @import("std");

threadlocal var x: u32 = 1;

fn worker(result: *u32) void {
    x += 10;
    result.* = x;
}

pub fn main() !void {
    x += 1;
    var result: u32 = 0;
    const thread = try std.Thread.spawn(.{}, worker, .{&result});
    thread.join();
    if (x != 2 or result != 11) return error.TestFailed;
}

// run
// backend=llvm
// target=aarch64-linux-ohos,x86_64-linux-ohos
//
