const std = @import("std");

fn worker() void {
    // Portable code picks these allocators by name on wasm.
    for ([_]std.mem.Allocator{ std.heap.page_allocator, std.heap.wasm_allocator }) |allocator| {
        const bytes = allocator.alloc(u8, 1) catch return;
        allocator.free(bytes);
    }
    std.debug.print("in thread\n", .{});
}

pub fn main() !void {
    const thread = try std.Thread.spawn(.{}, worker, .{});
    thread.join();
    std.debug.print("done\n", .{});
}
