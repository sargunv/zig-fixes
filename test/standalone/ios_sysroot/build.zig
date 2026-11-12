const std = @import("std");

/// Links for aarch64-ios with `--sysroot` pointing at the minimal fake SDK in
/// sdk/, so no Apple SDK is needed. A sysroot without SDKSettings.json is not
/// treated as an SDK, so the second case still links against Zig's bundled
/// libSystem stub.
pub fn build(b: *std.Build) void {
    const test_step = b.step("test", "Test it");
    b.default_step = test_step;

    const check = b.addExecutable(.{
        .name = "check",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .debug,
            .root_source_file = b.path("check.zig"),
        }),
    });

    const cases = [_]struct { src: []const u8, sysroot: []const u8, expect: []const u8 }{
        .{ .src = "main.c", .sysroot = "sdk", .expect = "sdk" },
        .{ .src = "plain.c", .sysroot = "sdk/usr", .expect = "stub" },
    };
    for (cases) |case| {
        const link = std.Build.Step.Run.create(b, b.fmt("link {s} with --sysroot {s}", .{ case.src, case.sysroot }));
        link.addFileArg(.zig_exe);
        link.addArgs(&.{ "build-exe", "-target", "aarch64-ios", "--zig-lib-dir" });
        link.addDirectoryArg(.zig_lib);
        link.addArg("--sysroot");
        link.addDirectoryArg(b.path(case.sysroot));
        link.addFileArg(b.path(case.src));
        const bin = link.addPrefixedOutputFileArg("-femit-bin=", "main");

        const run_check = b.addRunArtifact(check);
        run_check.addFileArg(bin);
        run_check.addArg(case.expect);
        run_check.expectExitCode(0);
        test_step.dependOn(&run_check.step);
    }
}
