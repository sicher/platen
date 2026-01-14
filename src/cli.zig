//! zpdf command line tool

const std = @import("std");
const zpdf = @import("zpdf");

const stdout = std.fs.File.stdout();

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = std.process.argsAlloc(allocator) catch {
        try printUsage();
        return;
    };
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "version")) {
        try print("zpdf version {s}\n", .{zpdf.version});
    } else if (std.mem.eql(u8, cmd, "test")) {
        // Generate a minimal test PDF
        const output_path = if (args.len > 2) args[2] else "test.pdf";
        try generateTestPdf(allocator, output_path);
        try print("Generated: {s}\n", .{output_path});
    } else {
        try printUsage();
    }
}

fn print(comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return error.BufferTooSmall;
    try stdout.writeAll(msg);
}

fn printUsage() !void {
    const usage =
        \\zpdf - PDF generation library and tool
        \\
        \\Usage: zpdf <command> [args]
        \\
        \\Commands:
        \\  version          Print version
        \\  test [output]    Generate a minimal test PDF (default: test.pdf)
        \\
    ;
    try stdout.writeAll(usage);
}

fn generateTestPdf(allocator: std.mem.Allocator, path: []const u8) !void {
    var doc = zpdf.Document.init(allocator);
    defer doc.deinit();

    try doc.addPage();

    const pdf = try doc.output();
    defer allocator.free(pdf);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(pdf);
}
