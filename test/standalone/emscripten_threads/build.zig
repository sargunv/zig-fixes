const std = @import("std");

pub fn build(b: *std.Build) void {
    const test_step = b.step("test", "Test it");
    b.default_step = test_step;

    // Linking needs Emscripten's toolchain, so only check that a multithreaded
    // object compiles.
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .emscripten,
        .cpu_features_add = std.Target.wasm.featureSet(&.{ .atomics, .bulk_memory }),
    });

    for ([_]std.builtin.Optimize{ .debug, .safe, .fast, .small }) |optimize| {
        const obj = b.addObject(.{
            .name = "main",
            .root_module = b.createModule(.{
                .root_source_file = b.path("main.zig"),
                .target = target,
                .optimize = optimize,
                .single_threaded = false,
            }),
        });
        _ = obj.getEmittedBin();
        test_step.dependOn(&obj.step);
    }
}
