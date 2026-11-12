pub fn build(b: *Build) void {
    const test_step = b.step("test", "Test linking BSD-format archives with the ELF linkers");
    b.default_step = test_step;

    const target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux });

    const short_obj = b.addObject(.{
        .name = "short",
        .root_module = b.createModule(.{ .target = target, .optimize = .debug }),
    });
    short_obj.root_module.addCSourceFile(.{ .file = b.path("short.c") });

    // Longer than `ar_name`, so the name is stored in the member's data as `#1/<len>`.
    const long_obj = b.addObject(.{
        .name = "a_very_long_object_name",
        .root_module = b.createModule(.{ .target = target, .optimize = .debug }),
    });
    long_obj.root_module.addCSourceFile(.{ .file = b.path("long.c") });

    const ar = b.addSystemCommand(&.{ b.graph.zig_exe, "ar", "rcs", "--format=bsd" });
    const archive = ar.addOutputFileArg("libbsd.a");
    ar.addFileArg(short_obj.getEmittedBin());
    ar.addFileArg(long_obj.getEmittedBin());

    for ([_]bool{ false, true }) |use_new_linker| {
        const exe = b.addExecutable(.{
            .name = if (use_new_linker) "main-new-linker" else "main-old-linker",
            .root_module = b.createModule(.{
                .root_source_file = b.path("main.zig"),
                .target = target,
                .optimize = .debug,
            }),
            .use_llvm = false,
        });
        exe.use_new_linker = use_new_linker;
        exe.root_module.addObjectFile(archive);

        const run = b.addRunArtifact(exe);
        run.expectExitCode(0);
        run.skip_foreign_checks = true;
        test_step.dependOn(&run.step);
    }
}

const std = @import("std");
const Build = std.Build;
