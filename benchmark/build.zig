const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const opts = .{ .target = target, .optimize = optimize };
    const zbench_module = b.dependency("zbench", opts).module("zbench");

    const benchmark_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });

    const shifters = b.addModule("shifters", .{
        .root_source_file = b.path("../src/shift_bytes.zig"),
    });

    benchmark_exe.root_module.addImport("zbench", zbench_module);
    benchmark_exe.root_module.addImport("shifters", shifters);

    b.installArtifact(benchmark_exe);

    const benchmark_run = b.step("benchmark", "Run the app");

    const run_cmd = b.addRunArtifact(benchmark_exe);
    benchmark_run.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());
}
