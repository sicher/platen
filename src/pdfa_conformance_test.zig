//! PDF/A conformance rules enforced at the API (veraPDF validates the
//! output in integration_tests.zig). Images: PDF/A-1b (PDF 1.4) forbids
//! soft masks and has no 16-bit samples; PDF/A-2b allows both. Fonts:
//! every PDF/A level requires embedded fonts, which the standard 14 lack.

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

test "PDF/A rejects standard (non-embedded) fonts in every text call" {
    const a = std.testing.allocator;
    const helv = platen.TextStyle{ .font = platen.Font.helvetica, .size = 12 };
    for ([_]platen.Conformance{ .pdfa_1b, .pdfa_2b }) |conformance| {
        var doc = platen.Document.init(a, std.testing.io);
        defer doc.deinit();
        doc.setConformance(conformance);
        try doc.addPage(.{});
        var region = platen.Region{ .x = 50, .y = 50, .width = 200, .height = 200 };
        try std.testing.expectError(error.FontNotEmbedded, doc.writeAt(.{ .x = 50, .y = 50 }, "x", helv, .{}));
        try std.testing.expectError(error.FontNotEmbedded, doc.write(&region, "x", helv, .{}));
        try std.testing.expectError(error.FontNotEmbedded, doc.writeBlock(&region, "x", helv, .{}));
        var st = doc.createStyledText();
        defer st.deinit();
        try st.append("x", .{});
        try std.testing.expectError(error.FontNotEmbedded, doc.writeStyled(&region, &st, helv, .{}));
        try std.testing.expectError(error.FontNotEmbedded, doc.writeAt(.{ .x = 50, .y = 50 }, "x", .{ .font = .symbol, .size = 12 }, .{}));
        try std.testing.expectEqual(@as(usize, 0), doc.pages.items[0].commands.items.len);

        // Embedded fonts are fine.
        const inter = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf", .identity);
        _ = try doc.writeAt(.{ .x = 50, .y = 50 }, "x", .{ .font = inter, .size = 12 }, .{});
    }
    // Outside PDF/A, standard fonts work as always.
    var plain = platen.Document.init(a, std.testing.io);
    defer plain.deinit();
    try plain.addPage(.{});
    _ = try plain.writeAt(.{ .x = 50, .y = 50 }, "x", helv, .{});
}

test "PDF/A rejects SVGs with text (rendered in standard fonts)" {
    const a = std.testing.allocator;
    var doc = platen.Document.init(a, std.testing.io);
    defer doc.deinit();
    doc.setConformance(.pdfa_2b);
    try doc.addPage(.{});
    const with_text = try doc.loadSvgFromMemory("<svg width=\"40\" height=\"20\"><text x=\"2\" y=\"12\">Hi</text></svg>");
    try std.testing.expectError(error.FontNotEmbedded, doc.drawSvg(with_text, .{ .x = 10, .y = 10 }));
    try std.testing.expectEqual(@as(usize, 0), doc.pages.items[0].used_svgs.items.len);
    const shapes = try doc.loadSvgFromMemory("<svg width=\"10\" height=\"10\"><rect width=\"10\" height=\"10\"/></svg>");
    try doc.drawSvg(shapes, .{ .x = 10, .y = 10 });
}

/// Text between `open` and `close` after the first `open` in `pdf`.
fn between(pdf: []const u8, open: []const u8, close: []const u8) ![]const u8 {
    const start = (std.mem.indexOf(u8, pdf, open) orelse return error.TestUnexpectedResult) + open.len;
    const len = std.mem.indexOf(u8, pdf[start..], close) orelse return error.TestUnexpectedResult;
    return pdf[start..][0..len];
}

fn pdfaWithDates(meta: platen.DocumentMetadata) ![]u8 {
    var doc = platen.Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    doc.setConformance(.pdfa_1b);
    doc.setMetadata(meta);
    try doc.addPage(.{});
    return doc.output();
}

test "PDF/A: explicit dates reach both /Info and XMP, as the same instants" {
    // Explicit dates used to reach /Info only, while XMP got the clock:
    // every PDF/A file with explicit dates failed veraPDF 6.7.3.
    const pdf = try pdfaWithDates(.{
        .creation_date = "D:20260101120000+02'00'",
        .mod_date = "D:20260315083005Z",
    });
    defer std.testing.allocator.free(pdf);
    try std.testing.expectEqualStrings("D:20260101120000+02'00'", try between(pdf, "/CreationDate (", ")"));
    try std.testing.expectEqualStrings("2026-01-01T12:00:00+02:00", try between(pdf, "<xmp:CreateDate>", "<"));
    try std.testing.expectEqualStrings("D:20260315083005Z", try between(pdf, "/ModDate (", ")"));
    try std.testing.expectEqualStrings("2026-03-15T08:30:05Z", try between(pdf, "<xmp:ModifyDate>", "<"));
}

test "PDF/A: automatic dates are one clock reading in /Info and XMP" {
    // /Info and XMP each read the clock; a second boundary in between made
    // CreateDate != CreationDate. Repeat to give a straddle a chance.
    for (0..50) |_| {
        const pdf = try pdfaWithDates(.{});
        defer std.testing.allocator.free(pdf);
        const info = try between(pdf, "/CreationDate (", ")");
        var buf: [32]u8 = undefined;
        const iso = @import("pdf_output.zig").pdfDateToIso(&buf, info) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(iso, try between(pdf, "<xmp:CreateDate>", "<"));
        try std.testing.expectEqualStrings(iso, try between(pdf, "<xmp:ModifyDate>", "<"));
        try std.testing.expectEqualStrings(info, try between(pdf, "/ModDate (", ")"));
    }
}

test "PDF/A rejects explicit dates that are not PDF dates; plain output keeps them" {
    try std.testing.expectError(error.InvalidDate, pdfaWithDates(.{ .creation_date = "2026-01-01" }));
    try std.testing.expectError(error.InvalidDate, pdfaWithDates(.{ .mod_date = "D:20261332" }));

    var doc = platen.Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    doc.setMetadata(.{ .creation_date = "2026-01-01" });
    try doc.addPage(.{});
    const pdf = try doc.output();
    defer std.testing.allocator.free(pdf);
    try std.testing.expectEqualStrings("2026-01-01", try between(pdf, "/CreationDate (", ")"));
}

fn pdfaSeeded(seed: ?u64) ![]u8 {
    var prng = std.Random.DefaultPrng.init(seed orelse 0);
    var doc = platen.Document.init(std.testing.allocator, std.testing.io);
    defer doc.deinit();
    doc.setConformance(.pdfa_1b);
    doc.setMetadata(.{ .creation_date = "D:20260101120000Z" });
    if (seed != null) doc.rng = prng.random();
    try doc.addPage(.{});
    return doc.output();
}

fn expectUuidV4(s: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 36), s.len);
    for (s, 0..) |c, i| switch (i) {
        8, 13, 18, 23 => try std.testing.expectEqual(@as(u8, '-'), c),
        else => try std.testing.expect(std.ascii.isHex(c) and !std.ascii.isUpper(c)),
    };
    try std.testing.expectEqual(@as(u8, '4'), s[14]); // version
    try std.testing.expect(std.mem.indexOfScalar(u8, "89ab", s[19]) != null); // variant
}

test "PDF/A: file IDs come from the RNG, not the clock" {
    // Trailer /ID and XMP IDs were the millisecond clock: outputs in the
    // same millisecond got identical IDs, and no rng made bytes stable.
    const a = try pdfaSeeded(1);
    defer std.testing.allocator.free(a);
    const b = try pdfaSeeded(1);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualSlices(u8, a, b); // seeded rng + explicit dates: reproducible

    const doc_id = try between(a, "<xmpMM:DocumentID>uuid:", "<");
    const inst_id = try between(a, "<xmpMM:InstanceID>uuid:", "<");
    try expectUuidV4(doc_id);
    try expectUuidV4(inst_id);
    try std.testing.expect(!std.mem.eql(u8, doc_id, inst_id));
    const trailer = try between(a, "/ID [<", ">");
    try std.testing.expectEqual(@as(usize, 32), trailer.len);
    for (trailer) |c| try std.testing.expect(std.ascii.isHex(c));

    const c = try pdfaSeeded(2);
    defer std.testing.allocator.free(c);
    try std.testing.expect(!std.mem.eql(u8, trailer, try between(c, "/ID [<", ">")));

    // Default (system CSPRNG): back-to-back outputs never share IDs.
    const d = try pdfaSeeded(null);
    defer std.testing.allocator.free(d);
    const e = try pdfaSeeded(null);
    defer std.testing.allocator.free(e);
    try std.testing.expect(!std.mem.eql(u8, try between(d, "/ID [<", ">"), try between(e, "/ID [<", ">")));
    try std.testing.expect(!std.mem.eql(u8, try between(d, "<xmpMM:DocumentID>", "<"), try between(e, "<xmpMM:DocumentID>", "<")));
}
