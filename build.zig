const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("shift_bytes", .{
        .root_source_file = b.path("src/shift_bytes.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run library tests");

    const tests = b.addTest(.{ .name = "shift_bytes", .root_module = module });
    const run_main_tests = b.addRunArtifact(tests);

    test_step.dependOn(&run_main_tests.step);
}
