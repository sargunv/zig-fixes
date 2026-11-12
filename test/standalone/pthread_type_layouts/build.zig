const std = @import("std");

pub fn build(b: *std.Build) void {
    const test_step = b.step("test", "Test it");
    b.default_step = test_step;

    for ([_][]const u8{
        "aarch64-linux-gnu",
        "aarch64-linux-musl",
        "aarch64_be-linux-gnu",
        "arm-linux-gnueabihf",
        "arm-linux-musleabihf",
        "loongarch64-linux-muslsf",
        "mips64el-linux-gnuabin32",
        "mips64el-linux-muslabi64",
        "mips64el-linux-muslabin32",
        "riscv32-linux-gnu",
        "riscv32-linux-musl",
        "x86-linux-gnu",
        "x86-linux-musl",
        "x86_64-linux-gnu",
        "x86_64-linux-gnux32",
        "x86_64-linux-musl",
        "x86_64-linux-muslx32",
    }) |t| {
        const target = b.resolveTargetQuery(std.Target.Query.parse(
            .{ .arch_os_abi = t },
        ) catch unreachable);

        const pthread_h = b.addTranslateC(.{
            .root_source_file = b.path("pthread.h"),
            .target = target,
            .optimize = .debug,
            .link_libc = true,
        });
        const obj = b.addObject(.{
            .name = t,
            .root_module = b.createModule(.{
                .root_source_file = b.path("main.zig"),
                .target = target,
                .optimize = .debug,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "pthread.h", .module = pthread_h.createModule() },
                },
            }),
        });
        _ = obj.getEmittedBin();
        test_step.dependOn(&obj.step);
    }
}
