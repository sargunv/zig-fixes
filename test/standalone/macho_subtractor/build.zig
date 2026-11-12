const std = @import("std");

pub fn build(b: *std.Build) void {
    const test_step = b.step("test", "Test it");
    b.default_step = test_step;

    // A difference with an imported symbol cannot be resolved at link time.
    for ([_][]const u8{ "import_minuend", "import_subtrahend" }) |name| {
        const link = b.addSystemCommand(&.{ b.graph.zig_exe, "build-exe", "-target", "aarch64-macos", "-lc" });
        link.addFileArg(b.path(b.fmt("{s}.s", .{name})));
        _ = link.addPrefixedOutputFileArg("-femit-bin=", name);
        link.expectExitCode(1);
        link.expectStdErrMatch("illegal difference relocation: imported symbol _malloc does not have an address");
        test_step.dependOn(&link.step);
    }

    const target = b.graph.host;
    if (!target.result.os.tag.isDarwin()) return;

    const asm_file = switch (target.result.cpu.arch) {
        .aarch64 => "aarch64.s",
        .x86_64 => "x86_64.s",
        else => return,
    };

    const exe = b.addExecutable(.{
        .name = "main",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = .debug,
        }),
    });
    exe.root_module.addAssemblyFile(b.path(asm_file));

    const run = b.addRunArtifact(exe);
    run.expectExitCode(0);
    test_step.dependOn(&run.step);
}
