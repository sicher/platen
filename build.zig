const std = @import("std");
const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The version lives in ONE place, build.zig.zon: `devkit release X.Y.Z`
    // sets it there, and src/version.zig reads it from this option.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", manifest.version);
    const build_options_mod = build_options.createModule();

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
        .imports = &.{.{ .name = "build_options", .module = build_options_mod }},
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
            // module, so it does not inherit the module's `link_libc` (or
            // its imports).
            .link_libc = true,
            .imports = &.{.{ .name = "build_options", .module = build_options_mod }},
        }),
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

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
        .imports = &.{.{ .name = "build_options", .module = build_options_mod }},
    });
    const lib_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);
    // The reference tests shell out to these scripts; declare them as
    // inputs so editing a script re-runs the tests instead of serving a
    // cached pass that never exercised the change.
    for ([_][]const u8{ "scripts/compare_pdfs.py", "scripts/test_compare_pdfs.py" }) |script| {
        run_lib_tests.addFileInput(b.path(script));
    }
    // Same for the fixtures the tests read at runtime (reference PDFs,
    // fonts, images, PngSuite truth): without this, regenerating or
    // corrupting a reference still produced a cached "pass".
    addFileInputsUnder(b, run_lib_tests, "test");
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
    run_perf.addPassthruArgs();

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
    run_invoice_bench.addPassthruArgs();

    const invoice_bench_step = b.step("bench-invoice", "Run invoice throughput benchmark (use -Doptimize=ReleaseFast)");
    invoice_bench_step.dependOn(&run_invoice_bench.step);

    // Feature showcase (source of the README gallery images)
    // Run with: zig build showcase -- [--output=PATH]
    const showcase_exe = b.addExecutable(.{
        .name = "platen-showcase",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/showcase.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "platen", .module = platen_mod },
            },
        }),
    });

    const run_showcase = b.addRunArtifact(showcase_exe);
    run_showcase.addPassthruArgs();

    const showcase_step = b.step("showcase", "Render the feature showcase PDF (zig-out/showcase.pdf)");
    showcase_step.dependOn(&run_showcase.step);
}

/// Declare every file under `dir` (relative to the build root) as an input
/// of `run`, except test/output, which the tests themselves write (as an
/// input it would invalidate the cache on every run).
fn addFileInputsUnder(b: *std.Build, run: *std.Build.Step.Run, dir: []const u8) void {
    const io = b.graph.io;
    var root = b.root.root_dir.handle.openDir(io, b.pathJoin(&.{ b.root.sub_path, dir }), .{ .iterate = true }) catch |err|
        std.debug.panic("cannot open {s}/ to declare test inputs: {t}", .{ dir, err });
    defer root.close(io);
    var walker = root.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch |err| std.debug.panic("walking {s}/: {t}", .{ dir, err })) |entry| {
        if (std.mem.startsWith(u8, entry.path, "output")) continue;
        if (entry.kind != .file) continue;
        run.addFileInput(b.path(b.pathJoin(&.{ dir, entry.path })));
    }
}
