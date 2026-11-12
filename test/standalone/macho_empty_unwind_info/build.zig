const std = @import("std");

/// Links a dylib whose only function is hidden and dead-stripped, so an input
/// has unwind records but none of them are live.
pub fn build(b: *std.Build) void {
    const test_step = b.step("test", "Test it");
    b.default_step = test_step;

    for ([_]std.Target.Cpu.Arch{ .aarch64, .x86_64 }) |cpu_arch| {
        const lib = b.addLibrary(.{
            .linkage = .dynamic,
            .name = b.fmt("empty-{t}", .{cpu_arch}),
            .root_module = b.createModule(.{
                .target = b.resolveTargetQuery(.{ .cpu_arch = cpu_arch, .os_tag = .macos }),
                .optimize = .fast,
            }),
        });
        lib.root_module.addCSourceFile(.{
            .file = b.path("lib.c"),
            .flags = &.{"-fvisibility=hidden"},
        });
        _ = lib.getEmittedBin();
        test_step.dependOn(&lib.step);
    }
}
