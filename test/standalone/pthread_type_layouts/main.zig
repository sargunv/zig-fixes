const std = @import("std");
const c = @import("pthread.h");

comptime {
    for (.{ "pthread_mutex_t", "pthread_cond_t", "pthread_rwlock_t", "pthread_attr_t", "sem_t" }) |name| {
        const Zig = @field(std.c, name);
        const C = @field(c, name);
        if (@sizeOf(Zig) != @sizeOf(C) or @alignOf(Zig) != @alignOf(C)) {
            @compileError(std.fmt.comptimePrint("std.c.{s} has size {d} align {d}, but C has size {d} align {d}", .{
                name, @sizeOf(Zig), @alignOf(Zig), @sizeOf(C), @alignOf(C),
            }));
        }
    }
}
