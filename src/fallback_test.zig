//! TextStyle.fallback: per-character fallback fonts, monospace cells and
//! synthesized styles. Courier Prime (Latin only) is the primary, Gentium
//! (with Cyrillic) the fallback.

const std = @import("std");
const platen = @import("platen.zig");
const fallback = @import("fallback.zig");

const testing = std.testing;
const a = testing.allocator;

const courier_dir = "test/fonts/Courier Prime/";
const gentium_dir = "test/fonts/Gentium/";

fn courier(doc: *platen.Document) !platen.Font {
    return doc.loadFontFamily(.{
        .regular = courier_dir ++ "Courier Prime.ttf",
        .bold = courier_dir ++ "Courier Prime Bold.ttf",
        .italic = courier_dir ++ "Courier Prime Italic.ttf",
        .bold_italic = courier_dir ++ "Courier Prime Bold Italic.ttf",
    });
}

fn gentium(doc: *platen.Document) !platen.Font {
    return doc.loadFontFamily(.{
        .regular = gentium_dir ++ "Gentium-Regular.ttf",
        .bold = gentium_dir ++ "Gentium-Bold.ttf",
        .italic = gentium_dir ++ "Gentium-Italic.ttf",
        .bold_italic = gentium_dir ++ "Gentium-BoldItalic.ttf",
    });
}

fn gentiumRegular(doc: *platen.Document) !platen.Font {
    return doc.loadFont(gentium_dir ++ "Gentium-Regular.ttf", .identity);
}

fn newDoc() !platen.Document {
    var doc = platen.Document.init(a, testing.io);
    doc.compression_level = 0;
    try doc.addPage(.{});
    return doc;
}

fn width(doc: *platen.Document, text: []const u8, style: platen.TextStyle) !f64 {
    return (try doc.measureStyled(text, style)).width;
}

/// The font resources the content streams select, in order of use.
fn fontsUsed(pdf: []const u8, out: *[16][]const u8) []const []const u8 {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, pdf, '\n');
    while (lines.next()) |line| {
        if (!std.mem.endsWith(u8, line, " Tf")) continue;
        const name = line[0 .. std.mem.indexOfScalar(u8, line, ' ') orelse continue];
        for (out[0..n]) |seen| {
            if (std.mem.eql(u8, seen, name)) break;
        } else if (n < out.len) {
            out[n] = name;
            n += 1;
        }
    }
    return out[0..n];
}

/// x of every text positioning (`x y Td` or `... x y Tm`), in order.
fn textX(pdf: []const u8, out: []f64) []f64 {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, pdf, '\n');
    while (lines.next()) |line| {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        var prev2: ?[]const u8 = null;
        var prev1: ?[]const u8 = null;
        while (it.next()) |tok| {
            if ((std.mem.eql(u8, tok, "Td") or std.mem.eql(u8, tok, "Tm")) and prev2 != null and n < out.len) {
                out[n] = std.fmt.parseFloat(f64, prev2.?) catch continue;
                n += 1;
            }
            prev2 = prev1;
            prev1 = tok;
        }
    }
    return out[0..n];
}

test "each character is drawn in the first font that has it" {
    var doc = try newDoc();
    defer doc.deinit();
    const cp = try courier(&doc);
    const gen = try gentium(&doc);
    const style: platen.TextStyle = .{ .font = cp, .size = 12, .fallback = &.{gen} };

    const expected = try width(&doc, "Hi ", .{ .font = cp, .size = 12 }) +
        try width(&doc, "Жук", .{ .font = gen, .size = 12 }) +
        try width(&doc, "!", .{ .font = cp, .size = 12 });
    try testing.expectApproxEqAbs(expected, try width(&doc, "Hi Жук!", style), 1e-9);

    const rect = try doc.writeAt(.{ .x = 72, .y = 100 }, "Hi Жук!", style, .{});
    try testing.expectApproxEqAbs(expected, rect.width, 1e-9);

    const pdf = try doc.output();
    defer a.free(pdf);
    var buf: [16][]const u8 = undefined;
    const used = fontsUsed(pdf, &buf);
    try testing.expectEqual(@as(usize, 2), used.len); // Courier, Gentium, Courier
}

test "a character the primary has never falls back" {
    var doc = try newDoc();
    defer doc.deinit();
    const style: platen.TextStyle = .{ .font = try courier(&doc), .size = 12, .fallback = &.{try gentium(&doc)} };
    _ = try doc.writeAt(.{ .x = 72, .y = 100 }, "Hello, world.", style, .{});
    const pdf = try doc.output();
    defer a.free(pdf);
    var buf: [16][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 1), fontsUsed(pdf, &buf).len);
}

test "the fallback list is tried in order" {
    var doc = try newDoc();
    defer doc.deinit();
    const cp = try courier(&doc);
    const gen = try gentium(&doc);
    const inter = try doc.loadFont("test/fonts/Inter/Inter-Regular.ttf", .identity);
    // Both have Cyrillic: the first listed draws it
    const first_gen: platen.TextStyle = .{ .font = cp, .size = 12, .fallback = &.{ gen, inter } };
    const first_inter: platen.TextStyle = .{ .font = cp, .size = 12, .fallback = &.{ inter, gen } };
    try testing.expectApproxEqAbs(try width(&doc, "Жук", .{ .font = gen, .size = 12 }), try width(&doc, "Жук", first_gen), 1e-9);
    try testing.expectApproxEqAbs(try width(&doc, "Жук", .{ .font = inter, .size = 12 }), try width(&doc, "Жук", first_inter), 1e-9);
}

test "monospace keeps every character on its column" {
    var doc = try newDoc();
    defer doc.deinit();
    const cp = try courier(&doc);
    const gen = try gentium(&doc);
    const style: platen.TextStyle = .{ .font = cp, .size = 12, .fallback = &.{gen}, .fallback_advance = .monospace };
    const cell = try width(&doc, " ", .{ .font = cp, .size = 12 });

    try testing.expectApproxEqAbs(5 * cell, try width(&doc, "AЖ Bа", style), 1e-9);
    const rect = try doc.writeAt(.{ .x = 72, .y = 100 }, "AЖ Bа", style, .{});
    try testing.expectApproxEqAbs(5 * cell, rect.width, 1e-9);

    // Runs: "A" at 72; "Ж", wider than a cell, shrunk to fill cell 1;
    // " B" at cell 2; "а", narrower, at its own size centered in cell 4
    const pdf = try doc.output();
    defer a.free(pdf);
    var xs_buf: [8]f64 = undefined;
    const xs = textX(pdf, &xs_buf);
    try testing.expectEqual(@as(usize, 4), xs.len);
    const w_wide = try width(&doc, "Ж", .{ .font = gen, .size = 12 });
    const w_narrow = try width(&doc, "а", .{ .font = gen, .size = 12 });
    try testing.expect(w_wide > cell and w_narrow < cell);
    try testing.expectApproxEqAbs(72.0, xs[0], 0.006);
    try testing.expectApproxEqAbs(72 + cell, xs[1], 0.006);
    try testing.expectApproxEqAbs(72 + 2 * cell, xs[2], 0.006);
    try testing.expectApproxEqAbs(72 + 4 * cell + (cell - w_narrow) / 2, xs[3], 0.006);

    var sizes_buf: [8]f64 = undefined;
    const sizes = fontSizes(pdf, &sizes_buf);
    try testing.expectEqual(@as(usize, 4), sizes.len);
    try testing.expectApproxEqAbs(12 * cell / w_wide, sizes[1], 0.005);
    for ([_]usize{ 0, 2, 3 }) |k| try testing.expectApproxEqAbs(12.0, sizes[k], 1e-9);
}

/// The size of every `Tf`, in order.
fn fontSizes(pdf: []const u8, out: []f64) []f64 {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, pdf, '\n');
    while (lines.next()) |line| {
        if (!std.mem.endsWith(u8, line, " Tf") or n == out.len) continue;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        _ = it.next();
        out[n] = std.fmt.parseFloat(f64, it.next() orelse continue) catch continue;
        n += 1;
    }
    return out[0..n];
}

test "a base and its combining marks share one font and one cell" {
    var doc = try newDoc();
    defer doc.deinit();
    const cp = try courier(&doc);
    const gen = try gentium(&doc);
    const cell = try width(&doc, " ", .{ .font = cp, .size = 12 });
    const decomposed = "и\u{0306}"; // й as base + breve
    const mono: platen.TextStyle = .{ .font = cp, .size = 12, .fallback = &.{gen}, .fallback_advance = .monospace };
    try testing.expectApproxEqAbs(cell, try width(&doc, decomposed, mono), 1e-9);
    const natural: platen.TextStyle = .{ .font = cp, .size = 12, .fallback = &.{gen} };
    try testing.expectApproxEqAbs(try width(&doc, decomposed, .{ .font = gen, .size = 12 }), try width(&doc, decomposed, natural), 1e-9);
}

test "a base and a mark the primary lacks compose in the primary" {
    // Courier Prime has no lone U+0301 but has "é": the pair stays in it,
    // composed, instead of the accent drifting into a fallback of its own
    var doc = try newDoc();
    defer doc.deinit();
    const cp = try courier(&doc);
    const mono: platen.TextStyle = .{ .font = cp, .size = 12, .fallback = &.{try gentium(&doc)}, .fallback_advance = .monospace };
    try testing.expectApproxEqAbs(try width(&doc, "café", .{ .font = cp, .size = 12 }), try width(&doc, "cafe\u{0301}", mono), 1e-9);
    _ = try doc.writeAt(.{ .x = 72, .y = 100 }, "cafe\u{0301}", mono, .{});
    const pdf = try doc.output();
    defer a.free(pdf);
    var buf: [16][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 1), fontsUsed(pdf, &buf).len);
}

fn renderOne(bold: bool, italic: bool, comptime family: bool, text: []const u8) ![]u8 {
    var doc = try newDoc();
    defer doc.deinit();
    const fb = if (family) try gentium(&doc) else try gentiumRegular(&doc);
    const style: platen.TextStyle = .{ .font = try courier(&doc), .size = 12, .bold = bold, .italic = italic, .fallback = &.{fb} };
    _ = try doc.writeAt(.{ .x = 72, .y = 100 }, text, style, .{});
    return doc.output();
}

const stroked = "2 Tr";
const embolden_width = "0.500 w"; // 12 pt / 24
const slanted = "1 0 0.213 1 "; // FreeType's oblique shear

test "a fallback face without the style asked for is synthesized" {
    const bold = try renderOne(true, false, false, "Жук");
    defer a.free(bold);
    try testing.expect(std.mem.indexOf(u8, bold, stroked) != null);
    try testing.expect(std.mem.indexOf(u8, bold, embolden_width) != null);
    try testing.expect(std.mem.indexOf(u8, bold, slanted) == null);

    const italic = try renderOne(false, true, false, "Жук");
    defer a.free(italic);
    try testing.expect(std.mem.indexOf(u8, italic, slanted) != null);
    try testing.expect(std.mem.indexOf(u8, italic, stroked) == null);
}

test "the primary's own styles are never synthesized" {
    const pdf = try renderOne(true, true, false, "Latin only");
    defer a.free(pdf);
    try testing.expect(std.mem.indexOf(u8, pdf, stroked) == null);
    try testing.expect(std.mem.indexOf(u8, pdf, slanted) == null);
}

test "a fallback family's own variants are used" {
    const pdf = try renderOne(true, true, true, "Жук");
    defer a.free(pdf);
    try testing.expect(std.mem.indexOf(u8, pdf, stroked) == null);
    try testing.expect(std.mem.indexOf(u8, pdf, slanted) == null);
}

test "a family without bold italic keeps its italic and synthesizes bold" {
    var doc = try newDoc();
    defer doc.deinit();
    const partial = try doc.loadFontFamily(.{
        .regular = gentium_dir ++ "Gentium-Regular.ttf",
        .italic = gentium_dir ++ "Gentium-Italic.ttf",
    });
    const f = try fallback.face(partial, true, true);
    try testing.expect(f.synth_bold and !f.synth_italic);
    try testing.expect(f.font.embedded == partial.embedded_family.italic.?);
    const r = try fallback.face(partial, true, false);
    try testing.expect(r.synth_bold and !r.synth_italic);
    try testing.expect(r.font.embedded == partial.embedded_family.regular);
}

test "synthesized bold fades with the fill" {
    var doc = try newDoc();
    defer doc.deinit();
    const style: platen.TextStyle = .{ .font = try courier(&doc), .size = 12, .bold = true, .opacity = 0.5, .fallback = &.{try gentiumRegular(&doc)} };
    _ = try doc.writeAt(.{ .x = 72, .y = 100 }, "Жук", style, .{});
    const pdf = try doc.output();
    defer a.free(pdf);
    try testing.expect(std.mem.indexOf(u8, pdf, "/CA 0.5") != null or std.mem.indexOf(u8, pdf, "/CA 0.50") != null);
}

test "anchored text moves every run" {
    var doc = try newDoc();
    defer doc.deinit();
    const style: platen.TextStyle = .{ .font = try courier(&doc), .size = 12, .fallback = &.{try gentium(&doc)} };
    const rect = try doc.writeAt(.{ .x = 300, .y = 100 }, "AЖ", style, .{ .anchor = .right });
    try testing.expectApproxEqAbs(300 - rect.width, rect.x, 1e-9);
    const pdf = try doc.output();
    defer a.free(pdf);
    var xs_buf: [4]f64 = undefined;
    const xs = textX(pdf, &xs_buf);
    try testing.expectEqual(@as(usize, 2), xs.len);
    try testing.expectApproxEqAbs(rect.x, xs[0], 0.006);
    try testing.expect(xs[1] > xs[0] and xs[1] < 300);
}

test "a fallback run is underlined like the text around it" {
    var doc = try newDoc();
    defer doc.deinit();
    const style: platen.TextStyle = .{
        .font = try courier(&doc),
        .size = 12,
        .decoration = .{ .underline = true },
        .fallback = &.{try gentium(&doc)},
        .fallback_advance = .monospace,
    };
    _ = try doc.writeAt(.{ .x = 72, .y = 100 }, "AЖA", style, .{});
    const pdf = try doc.output();
    defer a.free(pdf);
    var first: ?[]const u8 = null;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, pdf, '\n');
    while (lines.next()) |line| {
        if (!std.mem.endsWith(u8, line, " re f")) continue;
        // "x y w h re f": y and h must agree across runs
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        _ = it.next();
        const rest = it.rest();
        const y_and_h = rest[0..std.mem.indexOfScalar(u8, rest, ' ').?];
        var it2 = std.mem.tokenizeScalar(u8, rest, ' ');
        _ = it2.next();
        _ = it2.next();
        const h = it2.next().?;
        var key_buf: [64]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "{s} {s}", .{ y_and_h, h });
        if (first) |f| try testing.expectEqualStrings(f, key) else first = try a.dupe(u8, key);
        count += 1;
    }
    defer if (first) |f| a.free(f);
    try testing.expectEqual(@as(usize, 3), count);
}

test "fonts that cannot fall back are rejected" {
    var doc = try newDoc();
    defer doc.deinit();
    const gen = try gentium(&doc);
    try testing.expectError(error.InvalidFallbackFont, doc.writeAt(.{ .x = 72, .y = 100 }, "Жук", .{
        .font = platen.Font.helvetica,
        .size = 12,
        .fallback = &.{gen},
    }, .{}));
    try testing.expectError(error.InvalidFallbackFont, doc.writeAt(.{ .x = 72, .y = 100 }, "Жук", .{
        .font = try courier(&doc),
        .size = 12,
        .fallback = &.{platen.Font.times},
    }, .{}));
}

test "fallback text extracts as written, in every style" {
    var doc = try newDoc();
    defer doc.deinit();
    const cp = try courier(&doc);
    const family = try gentium(&doc);
    const single = try gentiumRegular(&doc); // bold/italic synthesized
    const line = "INT. КУХНЯ — ДЕНЬ | Иван: «Где кофе?»";
    var y: f64 = 100;
    for ([_]platen.Font{ family, single }) |fb| {
        for ([_][2]bool{ .{ false, false }, .{ true, false }, .{ false, true }, .{ true, true } }) |bi| {
            _ = try doc.writeAt(.{ .x = 72, .y = y }, line, .{
                .font = cp,
                .size = 12,
                .bold = bi[0],
                .italic = bi[1],
                .decoration = .{ .underline = bi[0] and bi[1] },
                .fallback = &.{fb},
                .fallback_advance = .monospace,
            }, .{});
            y += 14.4;
        }
        y += 14.4;
    }
    // The page grid: one character per column, Latin above Cyrillic
    _ = try doc.writeAt(.{ .x = 72, .y = y }, "ABCDEFGHIJ", .{ .font = cp, .size = 12 }, .{});
    _ = try doc.writeAt(.{ .x = 72, .y = y + 14.4 }, "АБВГДЕЖЗИЙ", .{ .font = cp, .size = 12, .fallback = &.{family}, .fallback_advance = .monospace }, .{});

    const pdf = try doc.output();
    defer a.free(pdf);
    const path = "test/output/fallback_styles.pdf";
    std.Io.Dir.cwd().createDir(testing.io, "test/output", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = pdf });
    const result = std.process.run(a, testing.io, .{ .argv = &.{ "pdftotext", "-raw", path, "-" } }) catch return error.SkipZigTest;
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    var found: usize = 0;
    while (lines.next()) |l| {
        if (std.mem.eql(u8, std.mem.trim(u8, l, " "), line)) found += 1;
    }
    try testing.expectEqual(@as(usize, 8), found);
}

const emoji_path = "test/fonts/Noto Emoji/NotoEmoji-Regular.ttf";

test "monospace: a wide cluster takes two cells" {
    var doc = try newDoc();
    defer doc.deinit();
    const cp = try courier(&doc);
    const emoji = try doc.loadFont(emoji_path, .identity);
    const style: platen.TextStyle = .{ .font = cp, .size = 12, .fallback = &.{emoji}, .fallback_advance = .monospace };
    const cell = try width(&doc, " ", .{ .font = cp, .size = 12 });
    // U+1F600 is East Asian Wide; U+263A is narrow until VS16 asks for
    // emoji presentation
    try testing.expectApproxEqAbs(4 * cell, try width(&doc, "A\u{1F600}B", style), 1e-9);
    try testing.expectApproxEqAbs(3 * cell, try width(&doc, "A\u{263A}B", style), 1e-9);
    try testing.expectApproxEqAbs(4 * cell, try width(&doc, "A\u{263A}\u{FE0F}B", style), 1e-9);

    const rect = try doc.writeAt(.{ .x = 72, .y = 100 }, "A\u{1F600}B", style, .{});
    try testing.expectApproxEqAbs(4 * cell, rect.width, 1e-9);
    const pdf = try doc.output();
    defer a.free(pdf);
    var xs_buf: [8]f64 = undefined;
    const xs = textX(pdf, &xs_buf);
    try testing.expectEqual(@as(usize, 3), xs.len);
    // B starts after the emoji's two cells; the emoji is centered in them
    try testing.expectApproxEqAbs(72 + 3 * cell, xs[2], 0.006);
    const w_emoji = try width(&doc, "\u{1F600}", .{ .font = emoji, .size = 12 });
    const room = 2 * cell;
    const expected = if (w_emoji > room) 72 + cell else 72 + cell + (room - w_emoji) / 2;
    try testing.expectApproxEqAbs(expected, xs[1], 0.006);
}

fn threeCells(_: []const u8) u8 {
    return 3;
}

test "monospace: fallback_cells overrides the cell count" {
    var doc = try newDoc();
    defer doc.deinit();
    const cp = try courier(&doc);
    const style: platen.TextStyle = .{
        .font = cp,
        .size = 12,
        .fallback = &.{try gentium(&doc)},
        .fallback_advance = .monospace,
        .fallback_cells = threeCells,
    };
    const cell = try width(&doc, " ", .{ .font = cp, .size = 12 });
    // A and B one cell each, Ж and ж three
    try testing.expectApproxEqAbs(8 * cell, try width(&doc, "AЖBж", style), 1e-9);
    const rect = try doc.writeAt(.{ .x = 72, .y = 100 }, "AЖBж", style, .{});
    try testing.expectApproxEqAbs(8 * cell, rect.width, 1e-9);
}

test "monospace: a cluster is shaped, its mark placed on its base" {
    var doc = try newDoc();
    defer doc.deinit();
    const cp = try courier(&doc);
    const gen = try gentiumRegular(&doc);
    const style: platen.TextStyle = .{ .font = cp, .size = 12, .fallback = &.{gen}, .fallback_advance = .monospace };
    const cell = try width(&doc, " ", .{ .font = cp, .size = 12 });
    // zhe + acute: no precomposed letter, so two glyphs in one cell
    const text = "Aж\u{0301}B";
    try testing.expectApproxEqAbs(3 * cell, try width(&doc, text, style), 1e-9);
    _ = try doc.writeAt(.{ .x = 72, .y = 100 }, text, style, .{});
    const pdf = try doc.output();
    defer a.free(pdf);
    var xs_buf: [8]f64 = undefined;
    const xs = textX(pdf, &xs_buf);
    // A; zhe and the acute, each placed; B
    try testing.expectEqual(@as(usize, 4), xs.len);
    // The acute sits over the zhe (GPOS mark attachment), not after it
    const w_zhe = try width(&doc, "ж", .{ .font = gen, .size = 12 });
    try testing.expect(xs[2] >= xs[1] and xs[2] < xs[1] + w_zhe);
    try testing.expectApproxEqAbs(72 + 2 * cell, xs[3], 0.006);

    const path = "test/output/fallback_shaped_cluster.pdf";
    std.Io.Dir.cwd().createDir(testing.io, "test/output", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = pdf });
    const result = std.process.run(a, testing.io, .{ .argv = &.{ "pdftotext", "-raw", path, "-" } }) catch return error.SkipZigTest;
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try testing.expectEqualStrings(text, std.mem.trim(u8, result.stdout, " \n\x0c"));
}

test "monospace: a Devanagari conjunct is one cluster, shaped (Kohinoor)" {
    const ttc = std.Io.Dir.cwd().readFileAlloc(testing.io, "/System/Library/Fonts/Kohinoor.ttc", a, .limited(64 << 20)) catch return error.SkipZigTest;
    defer a.free(ttc);
    var doc = try newDoc();
    defer doc.deinit();
    const cp = try courier(&doc);
    const deva = try doc.loadFontFromCollection(ttc, 4, .identity);
    const style: platen.TextStyle = .{ .font = cp, .size = 12, .fallback = &.{deva}, .fallback_advance = .monospace };
    const cell = try width(&doc, " ", .{ .font = cp, .size = 12 });
    // sa-virama-ta-e is one extended grapheme cluster (GB9c): one cell
    try testing.expectApproxEqAbs(3 * cell, try width(&doc, "Aस्तेB", style), 1e-9);
    _ = try doc.writeAt(.{ .x = 72, .y = 100 }, "Aस्तेB", style, .{});
    const pdf = try doc.output();
    defer a.free(pdf);
    var xs_buf: [8]f64 = undefined;
    // A; the sa-ta conjunct and the e matra (two glyphs, not four); B
    try testing.expectEqual(@as(usize, 4), textX(pdf, &xs_buf).len);
}
