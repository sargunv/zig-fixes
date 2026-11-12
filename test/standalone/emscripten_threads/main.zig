const std = @import("std");

fn worker() void {
    std.debug.print("in thread\n", .{});
}

pub fn main() !void {
    const thread = try std.Thread.spawn(.{}, worker, .{});
    thread.join();
    std.debug.print("done\n", .{});
}
