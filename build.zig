const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zlib dependency (built from source, no system dependency)
    const zlib_dep = b.dependency("zlib", .{
        .target = target,
        .optimize = optimize,
    });

    // Library module
    const platen_mod = b.createModule(.{
        .root_source_file = b.path("src/platen.zig"),
        .target = target,
        .optimize = optimize,
    });
    platen_mod.linkLibrary(zlib_dep.artifact("z"));

    // CLI executable
    const exe = b.addExecutable(.{
        .name = "platen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "platen", .module = platen_mod },
            },
        }),
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the CLI tool");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/platen.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.linkLibrary(zlib_dep.artifact("z"));
    const lib_tests = b.addTest(.{
        .root_module = test_mod,
        // Vendored runner working around a Zig 0.16.0 compile error in the
        // stock runner's fuzz mode; see scripts/test_runner.zig.
        .test_runner = .{ .path = b.path("scripts/test_runner.zig"), .mode = .server },
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);

    // Performance test executable
    // Run with: zig build perf -Doptimize=ReleaseFast -- [args]
    const perf_exe = b.addExecutable(.{
        .name = "platen-perf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/perf_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "platen", .module = platen_mod },
            },
        }),
    });

    const run_perf = b.addRunArtifact(perf_exe);
    if (b.args) |args| {
        run_perf.addArgs(args);
    }

    const perf_step = b.step("perf", "Run performance tests (use -Doptimize=ReleaseFast)");
    perf_step.dependOn(&run_perf.step);

    // Documentation (using zigmarkdoc via shell script)
    const docs_cmd = b.addSystemCommand(&.{ "scripts/gen_docs.sh" });
    const docs_step = b.step("docs", "Generate API documentation (Markdown)");
    docs_step.dependOn(&docs_cmd.step);
}
