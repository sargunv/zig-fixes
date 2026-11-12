const std = @import("std");
const c = @import("pthread.h");

comptime {
    if (@sizeOf(std.c.pthread_rwlock_t) != @sizeOf(c.pthread_rwlock_t) or
        @alignOf(std.c.pthread_rwlock_t) != @alignOf(c.pthread_rwlock_t))
    {
        @compileError(std.fmt.comptimePrint("std.c.pthread_rwlock_t has size {d} align {d}, but C has size {d} align {d}", .{
            @sizeOf(std.c.pthread_rwlock_t), @alignOf(std.c.pthread_rwlock_t),
            @sizeOf(c.pthread_rwlock_t),     @alignOf(c.pthread_rwlock_t),
        }));
    }
}
