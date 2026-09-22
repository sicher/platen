const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module. addModule (not createModule) so DEPENDENTS can reach it
    // as `b.dependency("platen", ...).module("platen")` — the form the README
    // documents. It is returned as well, so the internal uses below are
    // unaffected.
    //
    // `link_libc` because `document.zig` reaches for `std.c.clock_gettime`
    // when it stamps PDF/A metadata. macOS links libc whether or not
    // anyone says so, so this built here for a year and failed the first
    // time a Linux runner tried it, pointing at a line in std that looks
    // nothing like a build setting. Declared on the MODULE, so dependents
    // inherit it rather than each rediscovering the same thing.
    const platen_mod = b.addModule("platen", .{
        .root_source_file = b.path("src/platen.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // CLI executable. cli.zig imports the library source relatively (same
    // module) so it can reach test infrastructure (integration test cases
    // for check-refs) without those being exported from the platen module.
    const exe = b.addExecutable(.{
        .name = "platen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            // Roots at the source directly rather than importing the
            // module, so it does not inherit the module's `link_libc`.
            .link_libc = true,
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
        // A separate module instance over the same source, so it needs the
        // declaration of its own — `link_libc` is per module, not per file.
        .link_libc = true,
    });
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

    // Invoice throughput benchmark (SlothPDF comparison)
    // Run with: zig build bench-invoice -Doptimize=ReleaseFast -- [args]
    const invoice_bench_exe = b.addExecutable(.{
        .name = "platen-bench-invoice",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/invoice_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "platen", .module = platen_mod },
            },
        }),
    });

    const run_invoice_bench = b.addRunArtifact(invoice_bench_exe);
    if (b.args) |args| {
        run_invoice_bench.addArgs(args);
    }

    const invoice_bench_step = b.step("bench-invoice", "Run invoice throughput benchmark (use -Doptimize=ReleaseFast)");
    invoice_bench_step.dependOn(&run_invoice_bench.step);

    // Documentation (using zigmarkdoc via shell script)
    const docs_cmd = b.addSystemCommand(&.{ "scripts/gen_docs.sh" });
    const docs_step = b.step("docs", "Generate API documentation (Markdown)");
    docs_step.dependOn(&docs_cmd.step);
}
