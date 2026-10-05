//! PDF/A image conformance. PDF/A-1b (PDF 1.4) forbids soft masks and has
//! no 16-bit samples; images bypassed every conformance check, so a
//! "PDF/A-1b" file could carry both. PDF/A-2b allows both.

const std = @import("std");
const platen = @import("platen.zig");

const Case = struct { file: []const u8, pdfa_1b: ?anyerror };

const cases = [_]Case{
    .{ .file = "basn2c08.png", .pdfa_1b = null }, // 8-bit RGB, opaque
    .{ .file = "basn3p04.png", .pdfa_1b = null }, // indexed, opaque
    .{ .file = "basn6a08.png", .pdfa_1b = error.TransparencyNotAllowed }, // RGBA
    .{ .file = "tbrn2c08.png", .pdfa_1b = error.TransparencyNotAllowed }, // tRNS color key
    .{ .file = "basn2c16.png", .pdfa_1b = error.BitDepthNotAllowed }, // 16-bit RGB
    .{ .file = "basn0g16.png", .pdfa_1b = error.BitDepthNotAllowed }, // 16-bit gray
};

fn drawUnder(conformance: platen.Conformance, file: []const u8) !void {
    const a = std.testing.allocator;
    var doc = platen.Document.init(a, std.testing.io);
    defer doc.deinit();
    doc.setConformance(conformance);
    try doc.addPage(.{});
    var path_buf: [64]u8 = undefined;
    const img = try doc.loadImage(try std.fmt.bufPrint(&path_buf, "test/images/pngsuite/{s}", .{file}));
    const before = doc.pages.items[0].commands.items.len;
    doc.drawImage(img, .{ .x = 10, .y = 10, .width = 20, .height = 20 }) catch |err| {
        // Rejected before anything is recorded.
        try std.testing.expectEqual(before, doc.pages.items[0].commands.items.len);
        try std.testing.expectEqual(@as(usize, 0), doc.pages.items[0].used_images.items.len);
        return err;
    };
    const pdf = try doc.output();
    a.free(pdf);
}

test "PDF/A-1b rejects images with soft masks or 16-bit samples" {
    for (cases) |c| {
        if (c.pdfa_1b) |expected| {
            try std.testing.expectError(expected, drawUnder(.pdfa_1b, c.file));
        } else {
            try drawUnder(.pdfa_1b, c.file);
        }
    }
}

test "PDF/A-2b and plain output accept every case" {
    for (cases) |c| {
        try drawUnder(.pdfa_2b, c.file);
        try drawUnder(.none, c.file);
    }
}
