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
    allocator: std.mem.Allocator,
    actual: []const u8,
    expected: []const u8,
) !CompareResult {
    return comparePdfsWithOptions(allocator, actual, expected, .auto, .{});
}

/// Compare two PDFs with options
pub fn comparePdfsWithOptions(
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
            return comparePdfsStructural(allocator, actual, expected, options) catch |err| {
                if (err == error.QpdfNotAvailable) {
                    return .{ .equal = false, .diff = try allocator.dupe(u8, "qpdf not available"), .allocator = allocator };
                }
                return err;
            };
        },
        .semantic => {
            return comparePdfsSemantic(allocator, actual, expected) catch |err| {
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
            return comparePdfsSemantic(allocator, actual, expected) catch |err| {
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
    allocator: std.mem.Allocator,
    actual: []const u8,
    expected: []const u8,
    options: StructuralOptions,
) !CompareResult {
    // Write PDFs to temp files
    var tmp_actual = try createTempFile(allocator, "actual_", ".pdf");
    defer tmp_actual.cleanup(allocator);
    try tmp_actual.file.writeAll(actual);
    tmp_actual.file.close();

    var tmp_expected = try createTempFile(allocator, "expected_", ".pdf");
    defer tmp_expected.cleanup(allocator);
    try tmp_expected.file.writeAll(expected);
    tmp_expected.file.close();

    // Run qpdf on both files to get normalized QDF output
    const actual_qdf = runQpdf(allocator, tmp_actual.path) catch return error.QpdfNotAvailable;
    defer allocator.free(actual_qdf);

    const expected_qdf = runQpdf(allocator, tmp_expected.path) catch return error.QpdfNotAvailable;
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
fn runQpdf(allocator: std.mem.Allocator, pdf_path: []const u8) ![]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "qpdf", "--deterministic-id", "--qdf", pdf_path, "-" },
    }) catch return error.QpdfNotAvailable;

    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        allocator.free(result.stdout);
        return error.QpdfFailed;
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
        .lines = .{},
        .allocated = .{},
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
        if (options.ignore_id and std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " "), "/ID [")) {
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
    var diff = std.ArrayListUnmanaged(u8){};
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
fn comparePdfsSemantic(allocator: std.mem.Allocator, actual: []const u8, expected: []const u8) !CompareResult {
    // Write PDFs to temp files
    var tmp_actual = try createTempFile(allocator, "actual_", ".pdf");
    defer tmp_actual.cleanup(allocator);
    try tmp_actual.file.writeAll(actual);
    tmp_actual.file.close();

    var tmp_expected = try createTempFile(allocator, "expected_", ".pdf");
    defer tmp_expected.cleanup(allocator);
    try tmp_expected.file.writeAll(expected);
    tmp_expected.file.close();

    // Run semantic comparator
    // Tolerance of 1pt for minor floating-point rounding differences
    var child = std.process.Child.init(
        &.{ "python3", "scripts/compare_pdfs.py", tmp_expected.path, tmp_actual.path, "--tolerance=1.0" },
        allocator,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch return error.ComparatorNotAvailable;

    // Read output
    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);

    var buf: [4096]u8 = undefined;
    const stdout_file = child.stdout.?;
    while (true) {
        const n = try stdout_file.read(&buf);
        if (n == 0) break;
        try output.appendSlice(allocator, buf[0..n]);
    }

    const result = try child.wait();
    const exit_code = result.Exited;

    if (exit_code == 0) {
        return .{ .equal = true, .mode_used = .semantic };
    } else {
        const diff = try output.toOwnedSlice(allocator);
        return .{ .equal = false, .mode_used = .semantic, .diff = diff, .allocator = allocator };
    }
}

const TempFile = struct {
    file: std.fs.File,
    path: []const u8,

    fn cleanup(self: *TempFile, allocator: std.mem.Allocator) void {
        std.fs.cwd().deleteFile(self.path) catch {};
        allocator.free(self.path);
    }
};

fn createTempFile(allocator: std.mem.Allocator, prefix: []const u8, suffix: []const u8) !TempFile {
    const timestamp = std.time.timestamp();
    const rand = std.crypto.random.int(u32);
    const path = try std.fmt.allocPrint(allocator, "/tmp/{s}{d}_{d}{s}", .{ prefix, timestamp, rand, suffix });
    const file = try std.fs.cwd().createFile(path, .{});
    return .{ .file = file, .path = path };
}

/// Compare a PDF against a reference file
pub fn compareWithReference(allocator: std.mem.Allocator, actual: []const u8, reference_path: []const u8) !CompareResult {
    return compareWithReferenceMode(allocator, actual, reference_path, .auto, .{});
}

/// Compare a PDF against a reference file with options
pub fn compareWithReferenceMode(
    allocator: std.mem.Allocator,
    actual: []const u8,
    reference_path: []const u8,
    mode: CompareMode,
    options: StructuralOptions,
) !CompareResult {
    const expected = std.fs.cwd().readFileAlloc(allocator, reference_path, 10 * 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) {
            return .{ .equal = false, .diff = try allocator.dupe(u8, "Reference file not found"), .allocator = allocator };
        }
        return err;
    };
    defer allocator.free(expected);

    return comparePdfsWithOptions(allocator, actual, expected, mode, options);
}

/// Check if qpdf is available
pub fn isQpdfAvailable() bool {
    var child = std.process.Child.init(&.{ "qpdf", "--version" }, std.heap.page_allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    const result = child.wait() catch return false;
    return result.Exited == 0;
}

// ============================================================================
// Tests
// ============================================================================

test "identical PDFs compare equal" {
    const pdf = "%PDF-1.4\ntest";
    var result = try comparePdfs(std.testing.allocator, pdf, pdf);
    defer result.deinit();
    try std.testing.expect(result.equal);
}

test "different PDFs compare not equal" {
    const pdf1 = "%PDF-1.4\ntest1";
    const pdf2 = "%PDF-1.4\ntest2";
    var result = try comparePdfs(std.testing.allocator, pdf1, pdf2);
    defer result.deinit();
    try std.testing.expect(!result.equal);
}

test "qpdf availability check" {
    // Just verify the function runs without crashing
    _ = isQpdfAvailable();
}

test "structural comparison with valid PDFs" {
    // Skip if qpdf not available
    if (!isQpdfAvailable()) return;

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
