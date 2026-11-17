//! CID-keyed CFF subsetting (reveal's Apple SD Gothic Neo Hangul bug): text
//! in a CID-keyed font must render exactly as the same outlines in a
//! name-keyed font (test/fonts/cff, scripts/gen_cff_test_fonts.py).

const std = @import("std");
const platen = @import("platen.zig");

const testing = std.testing;

fn pdfWith(a: std.mem.Allocator, font_path: []const u8, text: []const u8) ![]u8 {
    var doc = platen.Document.init(a, testing.io);
    defer doc.deinit();
    try doc.addPage(.{ .size = .{ .width = 400, .height = 120 } });
    const font = try doc.loadFont(font_path, .identity);
    _ = try doc.writeAt(.{ .x = 20, .y = 80 }, text, .{ .font = font, .size = 40 }, .{});
    return doc.output();
}

/// Page 1 as a grayscale PGM at 72 dpi (raw pixels, no metadata to
/// differ); null without pdftoppm.
fn render(a: std.mem.Allocator, pdf: []const u8, name: []const u8) !?[]u8 {
    std.Io.Dir.cwd().createDir(testing.io, "test/output", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "test/output/{s}.pdf", .{name});
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = pdf });
    var prefix_buf: [128]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "test/output/{s}", .{name});
    const result = std.process.run(a, testing.io, .{ .argv = &.{ "pdftoppm", "-r", "72", "-gray", "-singlefile", path, prefix } }) catch return null;
    a.free(result.stdout);
    a.free(result.stderr);
    var pgm_buf: [128]u8 = undefined;
    const pgm = try std.fmt.bufPrint(&pgm_buf, "{s}.pgm", .{prefix});
    return try std.Io.Dir.cwd().readFileAlloc(testing.io, pgm, a, .limited(16 << 20));
}

test "a CID-keyed CFF subset draws the same glyphs as a name-keyed one" {
    const a = testing.allocator;
    // Glyphs alternate between two Font DICTs whose local subroutines draw
    // a box or a triangle; their CIDs are not their glyph IDs
    const text = "HBDF ACEG";
    const name_pdf = try pdfWith(a, "test/fonts/cff/NameKeyed.otf", text);
    defer a.free(name_pdf);
    const cid_pdf = try pdfWith(a, "test/fonts/cff/CidKeyed.otf", text);
    defer a.free(cid_pdf);
    const name_pgm = (try render(a, name_pdf, "cff_name_keyed")) orelse return error.SkipZigTest;
    defer a.free(name_pgm);
    const cid_pgm = (try render(a, cid_pdf, "cff_cid_keyed")) orelse return error.SkipZigTest;
    defer a.free(cid_pgm);
    try testing.expect(name_pgm.len > 100);
    try testing.expectEqualSlices(u8, name_pgm, cid_pgm);
}
