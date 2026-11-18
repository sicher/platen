//! Document.drawGlyphs: glyphs by ID at absolute positions, with the
//! ToUnicode text of their clusters, drawing shapeText's output.

const std = @import("std");
const platen = @import("platen.zig");

const testing = std.testing;
const Document = platen.Document;
const FontFace = platen.FontFace;
const PlacedGlyph = platen.PlacedGlyph;

/// Shape `text` and place its glyphs from (x, y), as a layout engine would.
fn place(allocator: std.mem.Allocator, face: *const FontFace, text: []const u8, size: f64, x: f64, y: f64) ![]PlacedGlyph {
    const shaped = try platen.shapeText(allocator, face, text, .{});
    defer allocator.free(shaped);
    const scale = size / @as(f64, @floatFromInt(platen.shaping.unitsPerEm(face)));
    const out = try allocator.alloc(PlacedGlyph, shaped.len);
    var pen = x;
    for (shaped, out) |g, *p| {
        p.* = .{
            .id = g.id,
            .x = pen + @as(f64, @floatFromInt(g.x_offset)) * scale,
            .y = y - @as(f64, @floatFromInt(g.y_offset)) * scale,
            .cluster = g.cluster,
        };
        pen += @as(f64, @floatFromInt(g.x_advance)) * scale;
    }
    return out;
}

fn pdftotext(allocator: std.mem.Allocator, pdf: []const u8, name: []const u8) ![]u8 {
    std.Io.Dir.cwd().createDir(testing.io, "test/output", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "test/output/{s}.pdf", .{name});
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = pdf });
    const result = std.process.run(allocator, testing.io, .{ .argv = &.{ "pdftotext", "-raw", path, "-" } }) catch return error.SkipZigTest;
    allocator.free(result.stderr);
    return result.stdout;
}

test "drawGlyphs: shaped glyphs extract as their text, ligatures and marks too" {
    const a = testing.allocator;
    var face = try FontFace.fromFile(testing.io, a, "test/fonts/Gentium/Gentium-Regular.ttf");
    defer face.deinit();
    var doc = Document.init(a, testing.io);
    defer doc.deinit();
    try doc.addPage(.{});

    // "ffi" is one ligature glyph; q + U+0303 a base and an attached mark
    const lines = [_][]const u8{ "office affluent", "q\u{303} r\u{E9}sum\u{E9}" };
    for (lines, 0..) |line, i| {
        const glyphs = try place(a, &face, line, 14, 72, 100 + 30 * @as(f64, @floatFromInt(i)));
        defer a.free(glyphs);
        try doc.drawGlyphs(line, glyphs, .{ .font = .{ .face = &face }, .size = 14 });
    }
    const pdf = try doc.output();
    defer a.free(pdf);
    const text = try pdftotext(a, pdf, "draw_glyphs");
    defer a.free(text);
    // Exactly what writeAt's text extracts as. The page ends in a form
    // feed, after a newline up to poppler 25 and right after the last
    // line from 26: the lines are compared, not how the page ends
    try testing.expect(std.mem.endsWith(u8, text, "\x0c"));
    try testing.expectEqualStrings("office affluent\nq\u{303} r\u{E9}sum\u{E9}", std.mem.trimEnd(u8, text, "\n\x0c"));
}

test "drawGlyphs: each glyph at its position, the subset holding it" {
    const a = testing.allocator;
    var face = try FontFace.fromFile(testing.io, a, "test/fonts/Gentium/Gentium-Regular.ttf");
    defer face.deinit();
    var doc = Document.init(a, testing.io);
    defer doc.deinit();
    doc.compression_level = 0; // keep the content stream readable
    try doc.addPage(.{ .size = .{ .width = 200, .height = 100 } });
    // Thousandths of a point survive; y flips to PDF's bottom-left origin
    const glyphs = [_]PlacedGlyph{
        .{ .id = 793, .x = 10.125, .y = 40, .cluster = 0 }, // ffi
        .{ .id = 82, .x = 30.0626, .y = 50.25, .cluster = 3 }, // o
    };
    try doc.drawGlyphs("ffio", &glyphs, .{ .font = .{ .face = &face }, .size = 12.5 });
    const pdf = try doc.output();
    defer a.free(pdf);
    try testing.expect(std.mem.indexOf(u8, pdf, "12.500 Tf") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "1 0 0 1 10.125 60.000 Tm <") != null);
    try testing.expect(std.mem.indexOf(u8, pdf, "1 0 0 1 30.063 49.750 Tm <") != null);
    // Subset to the two glyphs (plus .notdef), not the 971 KB font
    try testing.expect(pdf.len < 40 * 1024);
}

test "drawGlyphs rejects what it cannot draw" {
    const a = testing.allocator;
    var face = try FontFace.fromFile(testing.io, a, "test/fonts/Gentium/Gentium-Regular.ttf");
    defer face.deinit();
    var doc = Document.init(a, testing.io);
    defer doc.deinit();
    const one = [_]PlacedGlyph{.{ .id = 82, .x = 10, .y = 10, .cluster = 0 }};
    const style: platen.TextStyle = .{ .font = .{ .face = &face }, .size = 12 };
    try testing.expectError(error.NoPage, doc.drawGlyphs("o", &one, style));
    try doc.addPage(.{});

    try testing.expectError(error.GlyphsNeedIdentityFont, doc.drawGlyphs("o", &one, .{ .font = .helvetica, .size = 12 }));
    const win = try doc.loadFont("test/fonts/Gentium/Gentium-Regular.ttf", .win_ansi);
    try testing.expectError(error.GlyphsNeedIdentityFont, doc.drawGlyphs("o", &one, .{ .font = win, .size = 12 }));

    const past = [_]PlacedGlyph{.{ .id = 0xFFFF, .x = 10, .y = 10, .cluster = 0 }};
    try testing.expectError(error.InvalidGlyphId, doc.drawGlyphs("o", &past, style));

    var spaced = style;
    spaced.char_spacing = 1;
    try testing.expectError(error.UnsupportedStyle, doc.drawGlyphs("o", &one, spaced));
    var underlined = style;
    underlined.decoration = .{ .underline = true };
    try testing.expectError(error.UnsupportedStyle, doc.drawGlyphs("o", &one, underlined));

    const nan = [_]PlacedGlyph{.{ .id = 82, .x = std.math.nan(f64), .y = 10, .cluster = 0 }};
    try testing.expectError(error.InvalidNumber, doc.drawGlyphs("o", &nan, style));
    var bold = style;
    bold.bold = true;
    try testing.expectError(error.FontVariantNotLoaded, doc.drawGlyphs("o", &one, bold));

    // Nothing drawn, nothing broken
    try doc.drawGlyphs("", &.{}, style);
    const pdf = try doc.output();
    a.free(pdf);
}

test "drawGlyphs: with sources, each glyph maps to its own characters" {
    const a = testing.allocator;
    var doc = Document.init(a, testing.io);
    defer doc.deinit();
    try doc.addPage(.{});
    const font = try doc.loadFont("test/fonts/Gentium/Gentium-Regular.ttf", .identity);
    var face = try FontFace.fromFile(testing.io, a, "test/fonts/Gentium/Gentium-Regular.ttf");
    defer face.deinit();
    const text = "office q\u{303}";
    const shaped = try platen.shapeText(a, &face, text, .{});
    defer a.free(shaped);
    const placed = try a.alloc(PlacedGlyph, shaped.len);
    defer a.free(placed);
    for (shaped, placed, 0..) |g, *p, i| p.* = .{
        .id = g.id,
        .x = 72 + 20 * @as(f64, @floatFromInt(i)),
        .y = 100,
        .cluster = g.cluster,
        .source = .{ .start = g.text_start, .end = g.text_end },
    };
    try doc.drawGlyphs(text, placed, .{ .font = font, .size = 12 });
    const emb = font.embedded;
    // The ffi ligature maps to f, f, i; the tilde mark to itself, not to
    // "q" + tilde on the base
    try testing.expectEqualSlices(u21, &.{ 'f', 'f', 'i' }, emb.ligature_codepoints.get(shaped[1].id).?);
    try testing.expectEqual(@as(u21, 'q'), emb.glyph_to_codepoint.get(shaped[5].id).?);
    try testing.expectEqual(@as(u21, 0x0303), emb.glyph_to_codepoint.get(shaped[6].id).?);

    // A source past the text is refused
    var bad = placed[0];
    bad.source = .{ .start = 3, .end = 99 };
    try testing.expectError(error.InvalidGlyphSource, doc.drawGlyphs(text, &.{bad}, .{ .font = font, .size = 12 }));
}

test "written text: a glyph split by a multiple substitution maps part by part" {
    const a = testing.allocator;
    var doc = Document.init(a, testing.io);
    defer doc.deinit();
    try doc.addPage(.{});
    const font = try doc.loadFont("test/fonts/Gentium/Gentium-Regular.ttf", .identity);
    // Gentium's ccmp splits U+1ECB (i dot below) and U+012F (i ogonek)
    // into dotless i + the mark. Dotless i first maps with i dot below;
    // the ogonek must still get its own text (it used to get none)
    _ = try doc.writeAt(.{ .x = 72, .y = 100 }, "\u{1ECB}\u{0301} \u{012F}\u{0301}", .{ .font = font, .size = 12 }, .{});
    const emb = font.embedded;
    var face = try FontFace.fromFile(testing.io, a, "test/fonts/Gentium/Gentium-Regular.ttf");
    defer face.deinit();
    const shaped = try platen.shapeText(a, &face, "\u{012F}\u{0301}", .{});
    defer a.free(shaped);
    try testing.expectEqual(@as(usize, 3), shaped.len);
    try testing.expectEqual(@as(u21, 0x0328), emb.glyph_to_codepoint.get(shaped[1].id).?);
    try testing.expectEqual(@as(u21, 0x0301), emb.glyph_to_codepoint.get(shaped[2].id).?);
}

test "written text is shaped as shapeText shapes it (Devanagari, Kohinoor)" {
    const a = testing.allocator;
    const ttc = std.Io.Dir.cwd().readFileAlloc(testing.io, "/System/Library/Fonts/Kohinoor.ttc", a, .limited(64 << 20)) catch return error.SkipZigTest;
    defer a.free(ttc);
    var doc = Document.init(a, testing.io);
    defer doc.deinit();
    try doc.addPage(.{});
    const font = try doc.loadFontFromCollection(ttc, 4, .identity);
    const data = try platen.font_collection.extractFace(a, ttc, 4);
    defer a.free(data);
    var face = try FontFace.fromMemory(a, data);
    defer face.deinit();

    const text = "नमस्ते, कि क्ष हैं";
    const shaped = try platen.shapeText(a, &face, text, .{});
    defer a.free(shaped);
    const scale = 12.0 / @as(f64, @floatFromInt(platen.shaping.unitsPerEm(&face)));
    const expected = @as(f64, @floatFromInt(platen.shaping.totalAdvance(shaped))) * scale;
    // Measured and written widths are the shaped advances (the sa-ta
    // conjunct, not sa + virama + ta)
    try testing.expectApproxEqAbs(expected, (try doc.measureStyled(text, .{ .font = font, .size = 12 })).width, 1e-9);
    const rect = try doc.writeAt(.{ .x = 72, .y = 100 }, text, .{ .font = font, .size = 12 }, .{});
    try testing.expectApproxEqAbs(expected, rect.width, 1e-9);
    // The written glyphs are shapeText's
    const page = &doc.pages.items[0];
    const cmd = page.commands.items[page.commands.items.len - 1].text;
    try testing.expectEqual(shaped.len, cmd.cached_glyphs.?.len);
    for (shaped, cmd.cached_glyphs.?) |g, id| try testing.expectEqual(g.id, id);
}
