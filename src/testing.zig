//! PDF Testing Utilities
//!
//! Provides utilities for comparing PDF outputs against reference files.
//! Uses semantic comparison (text content + positions) rather than structural comparison.

const std = @import("std");

/// Result of PDF comparison
pub const CompareResult = struct {
    equal: bool,
    diff: ?[]const u8 = null, // Diff output if available
    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *CompareResult) void {
        if (self.diff) |d| {
            if (self.allocator) |a| {
                a.free(d);
            }
        }
    }
};

/// Compare two PDFs semantically (text + positions)
/// Returns comparison result with optional diff output
pub fn comparePdfs(allocator: std.mem.Allocator, actual: []const u8, expected: []const u8) !CompareResult {
    // Quick check: if identical, no need for further comparison
    if (std.mem.eql(u8, actual, expected)) {
        return .{ .equal = true };
    }

    // Use semantic comparison via Python script
    return comparePdfsSemantic(allocator, actual, expected) catch |err| {
        // Fallback to hash comparison if semantic comparison fails
        if (err == error.ComparatorNotAvailable) {
            const actual_hash = std.hash.Wyhash.hash(0, actual);
            const expected_hash = std.hash.Wyhash.hash(0, expected);
            return .{ .equal = actual_hash == expected_hash };
        }
        return err;
    };
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
    var child = std.process.Child.init(
        &.{ "python3", "scripts/compare_pdfs.py", tmp_expected.path, tmp_actual.path, "--tolerance=5.0" },
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
        return .{ .equal = true };
    } else {
        const diff = try output.toOwnedSlice(allocator);
        return .{ .equal = false, .diff = diff, .allocator = allocator };
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
    const path = try std.fmt.allocPrint(allocator, "/tmp/{s}{d}{s}", .{ prefix, timestamp, suffix });
    const file = try std.fs.cwd().createFile(path, .{});
    return .{ .file = file, .path = path };
}

/// Compare a PDF file against a reference file
pub fn compareWithReference(allocator: std.mem.Allocator, actual: []const u8, reference_path: []const u8) !CompareResult {
    const expected = std.fs.cwd().readFileAlloc(allocator, reference_path, 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) {
            return .{ .equal = false, .diff = try allocator.dupe(u8, "Reference file not found"), .allocator = allocator };
        }
        return err;
    };
    defer allocator.free(expected);

    return comparePdfs(allocator, actual, expected);
}

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
