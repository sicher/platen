//! PDF Testing Utilities
//!
//! Provides utilities for comparing PDF outputs against reference files.
//! Supports two comparison modes:
//! - Structural: qpdf-based QDF normalization (preferred, catches structural issues)
//! - Semantic: text content + positions (tolerant, catches visual differences)

const std = @import("std");

/// Comparison mode
pub const CompareMode = enum {
    /// Structural comparison using qpdf QDF normalization
    structural,
    /// Semantic comparison (text + positions via pdftotext)
    semantic,
    /// Try structural first, fall back to semantic
    auto,
};

/// Options for structural comparison
pub const StructuralOptions = struct {
    /// Ignore document ID changes (/ID [<...])
    ignore_id: bool = true,
    /// Ignore original object ID comments
    ignore_obj_ids: bool = false,
    /// Ignore xref offset lines
    ignore_xref: bool = false,
};

/// Options for semantic comparison
pub const SemanticOptions = struct {
    /// Skip font comparison (useful for SVG Form XObjects)
    skip_fonts: bool = false,
};

/// Result of PDF comparison
pub const CompareResult = struct {
    equal: bool,
    mode_used: CompareMode = .auto,
    diff: ?[]const u8 = null,
    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *CompareResult) void {
        if (self.diff) |d| {
            if (self.allocator) |a| {
                a.free(d);
            }
        }
    }
};

/// Compare two PDFs using the specified mode
pub fn comparePdfs(
    io: std.Io,
    allocator: std.mem.Allocator,
    actual: []const u8,
    expected: []const u8,
) !CompareResult {
    return comparePdfsWithOptions(io, allocator, actual, expected, .auto, .{});
}

/// Compare two PDFs with options
pub fn comparePdfsWithOptions(
    io: std.Io,
    allocator: std.mem.Allocator,
    actual: []const u8,
    expected: []const u8,
    mode: CompareMode,
    options: StructuralOptions,
) !CompareResult {
    // Quick check: if identical, no need for further comparison
    if (std.mem.eql(u8, actual, expected)) {
        return .{ .equal = true, .mode_used = mode };
    }

    switch (mode) {
        .structural => {
            return comparePdfsStructural(io, allocator, actual, expected, options) catch |err| {
                if (err == error.QpdfNotAvailable) {
                    return .{ .equal = false, .diff = try allocator.dupe(u8, "qpdf not available"), .allocator = allocator };
                }
                return err;
            };
        },
        .semantic => {
            return comparePdfsSemantic(io, allocator, actual, expected) catch |err| {
                if (err == error.ComparatorNotAvailable) {
                    return hashComparison(actual, expected, .semantic);
                }
                return err;
            };
        },
        .auto => {
            // For comparing against external references (like fpdf2), use semantic
            // Structural comparison would fail because PDF structure differs
            // Structural is best for regression testing (comparing against self)
            return comparePdfsSemantic(io, allocator, actual, expected) catch |err| {
                if (err == error.ComparatorNotAvailable) {
                    return hashComparison(actual, expected, .auto);
                }
                return err;
            };
        },
    }
}

fn hashComparison(actual: []const u8, expected: []const u8, mode: CompareMode) CompareResult {
    const actual_hash = std.hash.Wyhash.hash(0, actual);
    const expected_hash = std.hash.Wyhash.hash(0, expected);
    return .{ .equal = actual_hash == expected_hash, .mode_used = mode };
}

/// Compare PDFs using qpdf structural comparison
fn comparePdfsStructural(
    io: std.Io,
    allocator: std.mem.Allocator,
    actual: []const u8,
    expected: []const u8,
    options: StructuralOptions,
) !CompareResult {
    // Write PDFs to temp files
    var tmp_actual = try createTempFile(io, allocator, "actual_", ".pdf", actual);
    defer tmp_actual.cleanup(io, allocator);

    var tmp_expected = try createTempFile(io, allocator, "expected_", ".pdf", expected);
    defer tmp_expected.cleanup(io, allocator);

    // Run qpdf on both files to get normalized QDF output
    const actual_qdf = runQpdf(io, allocator, tmp_actual.path) catch return error.QpdfNotAvailable;
    defer allocator.free(actual_qdf);

    const expected_qdf = runQpdf(io, allocator, tmp_expected.path) catch return error.QpdfNotAvailable;
    defer allocator.free(expected_qdf);

    // Filter and compare lines
    var actual_filtered = filterLines(allocator, actual_qdf, options) catch return error.OutOfMemory;
    defer actual_filtered.deinit(allocator);

    var expected_filtered = filterLines(allocator, expected_qdf, options) catch return error.OutOfMemory;
    defer expected_filtered.deinit(allocator);

    const actual_lines = actual_filtered.lines.items;
    const expected_lines = expected_filtered.lines.items;

    // Compare line by line
    if (actual_lines.len != expected_lines.len) {
        const diff = try generateDiff(allocator, expected_lines, actual_lines);
        return .{ .equal = false, .mode_used = .structural, .diff = diff, .allocator = allocator };
    }

    for (actual_lines, expected_lines) |actual_line, expected_line| {
        if (!std.mem.eql(u8, actual_line, expected_line)) {
            const diff = try generateDiff(allocator, expected_lines, actual_lines);
            return .{ .equal = false, .mode_used = .structural, .diff = diff, .allocator = allocator };
        }
    }

    return .{ .equal = true, .mode_used = .structural };
}

/// Run qpdf to normalize PDF to QDF format
fn runQpdf(io: std.Io, allocator: std.mem.Allocator, pdf_path: []const u8) ![]const u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "qpdf", "--deterministic-id", "--qdf", pdf_path, "-" },
    }) catch return error.QpdfNotAvailable;

    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            allocator.free(result.stdout);
            return error.QpdfFailed;
        },
        else => {
            allocator.free(result.stdout);
            return error.QpdfFailed;
        },
    }

    return result.stdout;
}

/// Filtered lines with any allocated strings
const FilteredLines = struct {
    lines: std.ArrayListUnmanaged([]const u8),
    allocated: std.ArrayListUnmanaged([]const u8), // Strings we need to free

    fn deinit(self: *FilteredLines, allocator: std.mem.Allocator) void {
        for (self.allocated.items) |s| {
            allocator.free(s);
        }
        self.allocated.deinit(allocator);
        self.lines.deinit(allocator);
    }
};

/// Filter QDF lines based on options
fn filterLines(
    allocator: std.mem.Allocator,
    qdf: []const u8,
    options: StructuralOptions,
) !FilteredLines {
    var result = FilteredLines{
        .lines = .empty,
        .allocated = .empty,
    };
    errdefer result.deinit(allocator);

    var in_stream = false;
    var stream_hash: u64 = 0;

    var iter = std.mem.splitScalar(u8, qdf, '\n');
    while (iter.next()) |line| {
        // Track stream state for hashing binary content
        if (std.mem.eql(u8, line, "stream")) {
            in_stream = true;
            stream_hash = 0;
            try result.lines.append(allocator, line);
            continue;
        }

        if (in_stream) {
            if (std.mem.endsWith(u8, line, "endstream")) {
                // End of stream - add hash summary instead of binary
                const hash_line = try std.fmt.allocPrint(allocator, "<stream hash: {x}>", .{stream_hash});
                try result.allocated.append(allocator, hash_line);
                try result.lines.append(allocator, hash_line);
                try result.lines.append(allocator, "endstream");
                in_stream = false;
            } else {
                // Accumulate hash of stream content
                stream_hash = std.hash.Wyhash.hash(stream_hash, line);
            }
            continue;
        }

        // Apply filters
        if (options.ignore_id and std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "/ID [")) {
            continue;
        }
        if (options.ignore_obj_ids and std.mem.startsWith(u8, line, "%% Original object ID:")) {
            continue;
        }
        if (options.ignore_xref and std.mem.endsWith(u8, line, " 00000 n ")) {
            continue;
        }

        try result.lines.append(allocator, line);
    }

    return result;
}

/// Generate a simple diff output
fn generateDiff(
    allocator: std.mem.Allocator,
    expected: []const []const u8,
    actual: []const []const u8,
) ![]const u8 {
    var diff = std.ArrayListUnmanaged(u8).empty;
    errdefer diff.deinit(allocator);

    try diff.appendSlice(allocator, "=== Structural diff ===\n");

    const max_lines = @min(20, @max(expected.len, actual.len));
    var differences: usize = 0;

    for (0..max_lines) |i| {
        const exp_line = if (i < expected.len) expected[i] else "<missing>";
        const act_line = if (i < actual.len) actual[i] else "<missing>";

        if (!std.mem.eql(u8, exp_line, act_line)) {
            differences += 1;
            if (differences <= 10) {
                try diff.appendSlice(allocator, "Line ");
                var buf: [16]u8 = undefined;
                const num = std.fmt.bufPrint(&buf, "{d}", .{i + 1}) catch "?";
                try diff.appendSlice(allocator, num);
                try diff.appendSlice(allocator, ":\n  expected: ");
                try diff.appendSlice(allocator, exp_line[0..@min(100, exp_line.len)]);
                try diff.appendSlice(allocator, "\n  actual:   ");
                try diff.appendSlice(allocator, act_line[0..@min(100, act_line.len)]);
                try diff.appendSlice(allocator, "\n");
            }
        }
    }

    if (expected.len != actual.len) {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "\nLine count: expected {d}, actual {d}\n", .{ expected.len, actual.len }) catch "";
        try diff.appendSlice(allocator, msg);
    }

    if (differences > 10) {
        var buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "\n... and {d} more differences\n", .{differences - 10}) catch "";
        try diff.appendSlice(allocator, msg);
    }

    return diff.toOwnedSlice(allocator);
}

/// Compare PDFs using semantic comparison (text + positions)
fn comparePdfsSemantic(io: std.Io, allocator: std.mem.Allocator, actual: []const u8, expected: []const u8) !CompareResult {
    return comparePdfsSemanticWithOptions(io, allocator, actual, expected, .{});
}

/// Compare PDFs using semantic comparison with options
fn comparePdfsSemanticWithOptions(io: std.Io, allocator: std.mem.Allocator, actual: []const u8, expected: []const u8, options: SemanticOptions) !CompareResult {
    // Write PDFs to temp files
    var tmp_actual = try createTempFile(io, allocator, "actual_", ".pdf", actual);
    defer tmp_actual.cleanup(io, allocator);

    var tmp_expected = try createTempFile(io, allocator, "expected_", ".pdf", expected);
    defer tmp_expected.cleanup(io, allocator);

    // Run semantic comparator
    // Tolerance of 1pt for minor floating-point rounding differences
    const argv: []const []const u8 = if (options.skip_fonts)
        &.{ "python3", "scripts/compare_pdfs.py", tmp_expected.path, tmp_actual.path, "--tolerance=1.0", "--skip-fonts" }
    else
        &.{ "python3", "scripts/compare_pdfs.py", tmp_expected.path, tmp_actual.path, "--tolerance=1.0" };

    const result = std.process.run(allocator, io, .{ .argv = argv }) catch return error.ComparatorNotAvailable;
    defer allocator.free(result.stderr);

    const exited = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };

    if (exited) {
        allocator.free(result.stdout);
        return .{ .equal = true, .mode_used = .semantic };
    } else {
        return .{ .equal = false, .mode_used = .semantic, .diff = result.stdout, .allocator = allocator };
    }
}

const TempFile = struct {
    path: []const u8,

    fn cleanup(self: *TempFile, io: std.Io, allocator: std.mem.Allocator) void {
        std.Io.Dir.cwd().deleteFile(io, self.path) catch {};
        allocator.free(self.path);
    }
};

var temp_file_counter: u32 = 0;

fn createTempFile(io: std.Io, allocator: std.mem.Allocator, prefix: []const u8, suffix: []const u8, contents: []const u8) !TempFile {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    temp_file_counter +%= 1;
    const counter = temp_file_counter;
    const path = try std.fmt.allocPrint(allocator, "/tmp/{s}{d}_{d}{s}", .{ prefix, ts.nsec, counter, suffix });
    errdefer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = contents });
    return .{ .path = path };
}

/// Compare a PDF against a reference file
pub fn compareWithReference(io: std.Io, allocator: std.mem.Allocator, actual: []const u8, reference_path: []const u8) !CompareResult {
    return compareWithReferenceSemantic(io, allocator, actual, reference_path, .{});
}

/// Compare a PDF against a reference file with semantic options
pub fn compareWithReferenceSemantic(io: std.Io, allocator: std.mem.Allocator, actual: []const u8, reference_path: []const u8, options: SemanticOptions) !CompareResult {
    const expected = std.Io.Dir.cwd().readFileAlloc(io, reference_path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) {
            return .{ .equal = false, .diff = try allocator.dupe(u8, "Reference file not found"), .allocator = allocator };
        }
        return err;
    };
    defer allocator.free(expected);

    // Quick check: if identical, no need for further comparison
    if (std.mem.eql(u8, actual, expected)) {
        return .{ .equal = true, .mode_used = .semantic };
    }

    return comparePdfsSemanticWithOptions(io, allocator, actual, expected, options);
}

/// Compare a PDF against a reference file with options
pub fn compareWithReferenceMode(
    io: std.Io,
    allocator: std.mem.Allocator,
    actual: []const u8,
    reference_path: []const u8,
    mode: CompareMode,
    options: StructuralOptions,
) !CompareResult {
    const expected = std.Io.Dir.cwd().readFileAlloc(io, reference_path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) {
            return .{ .equal = false, .diff = try allocator.dupe(u8, "Reference file not found"), .allocator = allocator };
        }
        return err;
    };
    defer allocator.free(expected);

    return comparePdfsWithOptions(io, allocator, actual, expected, mode, options);
}

/// Check if qpdf is available
pub fn isQpdfAvailable(io: std.Io) bool {
    const result = std.process.run(std.heap.page_allocator, io, .{
        .argv = &.{ "qpdf", "--version" },
    }) catch return false;
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "identical PDFs compare equal" {
    const pdf = "%PDF-1.4\ntest";
    var result = try comparePdfs(std.testing.io, std.testing.allocator, pdf, pdf);
    defer result.deinit();
    try std.testing.expect(result.equal);
}

test "different PDFs compare not equal" {
    const pdf1 = "%PDF-1.4\ntest1";
    const pdf2 = "%PDF-1.4\ntest2";
    var result = try comparePdfs(std.testing.io, std.testing.allocator, pdf1, pdf2);
    defer result.deinit();
    try std.testing.expect(!result.equal);
}

test "qpdf availability check" {
    // Just verify the function runs without crashing
    _ = isQpdfAvailable(std.testing.io);
}

test "structural comparison with valid PDFs" {
    // Skip if qpdf not available
    if (!isQpdfAvailable(std.testing.io)) return;

    // Use a minimal valid PDF for testing
    const pdf1 =
        \\%PDF-1.4
        \\1 0 obj
        \\<< /Type /Catalog /Pages 2 0 R >>
        \\endobj
        \\2 0 obj
        \\<< /Type /Pages /Kids [3 0 R] /Count 1 >>
        \\endobj
        \\3 0 obj
        \\<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>
        \\endobj
        \\xref
        \\0 4
        \\0000000000 65535 f
        \\0000000009 00000 n
        \\0000000058 00000 n
        \\0000000115 00000 n
        \\trailer
        \\<< /Size 4 /Root 1 0 R >>
        \\startxref
        \\196
        \\%%EOF
    ;

    // Same PDF should be equal
    var result = try comparePdfsWithOptions(
        std.testing.io,
        std.testing.allocator,
        pdf1,
        pdf1,
        .structural,
        .{ .ignore_id = true },
    );
    defer result.deinit();
    try std.testing.expect(result.equal);
    try std.testing.expectEqual(CompareMode.structural, result.mode_used);
}
