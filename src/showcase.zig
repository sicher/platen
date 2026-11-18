//! Feature showcase: one single-page PDF per topic - typography, vector
//! graphics, color fonts/images, and scripts with fallback fonts. The README gallery shows them
//! rasterized (scripts/render-readme-images) and links each image to its
//! PDF.
//!
//! Run with: zig build showcase -- [--output-dir=DIR]
//! Default output: examples/showcase_{typography,graphics,color,scripts}.pdf

const std = @import("std");
const platen = @import("platen");

const page_w: f64 = 595.0;
const page_h: f64 = 842.0;
const margin: f64 = 56.0;

const ink = platen.Color.rgb(28, 32, 44);
const muted = platen.Color.rgb(110, 116, 130);
const accent = platen.Color.rgb(240, 120, 40);
const deep = platen.Color.rgb(36, 52, 110);

const Fonts = struct {
    charter: platen.Font,
    inter: platen.Font,
    gentium: platen.Font,
    emoji: platen.Font,
    bungee: platen.Font,
};

const pages = [_]struct {
    name: []const u8,
    title: []const u8,
    render: *const fn (*platen.Document, Fonts) anyerror!void,
}{
    .{ .name = "typography", .title = "platen showcase: typography", .render = typographyPage },
    .{ .name = "graphics", .title = "platen showcase: vector graphics", .render = graphicsPage },
    .{ .name = "color", .title = "platen showcase: color fonts and images", .render = colorPage },
    .{ .name = "scripts", .title = "platen showcase: scripts and fallback fonts", .render = scriptsPage },
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var output_dir: []const u8 = "examples";
    var args = init.minimal.args.iterate();
    _ = args.next(); // program name
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--output-dir=")) {
            output_dir = arg["--output-dir=".len..];
        } else {
            std.debug.print("Usage: showcase [--output-dir=DIR]\n", .{});
            return error.InvalidArgument;
        }
    }

    for (pages) |page| {
        var doc = platen.Document.init(allocator, init.io);
        defer doc.deinit();
        doc.compression_level = 9;
        doc.setMetadata(.{ .title = page.title, .creator = "platen showcase" });

        try page.render(&doc, try loadFonts(&doc));

        const pdf = try doc.output();
        defer allocator.free(pdf);
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/showcase_{s}.pdf", .{ output_dir, page.name });
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = pdf });
        std.debug.print("wrote {s} ({d} KB)\n", .{ path, pdf.len / 1024 });
    }
}

/// Fonts shared by the pages; only the glyphs a page uses are embedded.
fn loadFonts(doc: *platen.Document) !Fonts {
    return .{
        .charter = try doc.loadFontFamily(.{
            .regular = "test/fonts/Charter/Charter Regular.ttf",
            .bold = "test/fonts/Charter/Charter Bold.ttf",
            .italic = "test/fonts/Charter/Charter Italic.ttf",
            .bold_italic = "test/fonts/Charter/Charter Bold Italic.ttf",
        }),
        .inter = try doc.loadFontFamily(.{
            .regular = "test/fonts/Inter/Inter-Regular.ttf",
            .bold = "test/fonts/Inter/Inter-Bold.ttf",
        }),
        .gentium = try doc.loadFont("test/fonts/Gentium/Gentium-Regular.ttf", .identity),
        .emoji = try doc.loadFont("test/fonts/Noto_Color_Emoji/NotoColorEmoji-Regular.ttf", .identity),
        .bungee = try doc.loadFont("test/fonts/Bungee Color/BungeeSpice-Regular-COLRv1.ttf", .identity),
    };
}

/// Page header: small caps label, title, and a rule.
fn header(doc: *platen.Document, fonts: Fonts, label: []const u8, title: []const u8) !void {
    _ = try doc.writeAt(.{ .x = margin, .y = margin + 8 }, label, .{ .font = fonts.inter, .size = 9, .bold = true, .color = accent, .char_spacing = 1.5 }, .{});
    _ = try doc.writeAt(.{ .x = margin, .y = margin + 40 }, title, .{ .font = fonts.charter, .size = 30, .bold = true, .color = ink }, .{});
    try doc.drawLine(.{ .x = margin, .y = margin + 56 }, .{ .x = page_w - margin, .y = margin + 56 }, .{ .color = ink, .width = 1.2 });
}

fn footer(doc: *platen.Document, fonts: Fonts, text: []const u8) !void {
    _ = try doc.writeAt(.{ .x = page_w / 2, .y = page_h - 32 }, text, .{ .font = fonts.inter, .size = 8, .color = muted }, .{ .anchor = .center });
}

const body_text =
    "Printing changed the world not because it was fast, but because it was " ++
    "repeatable: the same forme, inked and pressed against paper, gave the same " ++
    "page every time. A PDF library inherits that promise. Given the same input it " ++
    "should produce the same bytes, whether it runs once on a laptop or ten thousand " ++
    "times a second on a server, and it should do so without global state, hidden " ++
    "caches, or surprises. ";

fn sectionLabel(doc: *platen.Document, fonts: Fonts, y: f64, text: []const u8) !void {
    _ = try doc.writeAt(.{ .x = margin, .y = y }, text, .{ .font = fonts.inter, .size = 8, .bold = true, .color = muted, .char_spacing = 1.2 }, .{});
}

fn typographyPage(doc: *platen.Document, fonts: Fonts) !void {
    try doc.addPage(.{});
    try header(doc, fonts, "TYPOGRAPHY", "The art of the platen");
    const full_w = page_w - 2 * margin;

    // Lead paragraph
    var lead = platen.Region{ .x = margin, .y = margin + 74, .width = full_w, .height = 80 };
    _ = try doc.writeBlock(&lead, "A platen is the flat plate that presses paper against inked type. This one presses glyphs into PDF: shaped, kerned, subset and laid out, in pure Zig.", .{ .font = fonts.charter, .size = 14, .italic = true, .color = deep }, .{ .line_height = 1.35 });
    var y = lead.y + lead.cursor_y + 18;

    // One styled text in two balanced, justified columns: Knuth-Plass line
    // breaking with mixed spans, measured first, then continued from the
    // left column into the right one with resume_at
    const col_gap = 22.0;
    const col_w = (full_w - col_gap) / 2;
    const base = platen.TextStyle{ .font = fonts.charter, .size = 10.5, .color = ink };
    const para = platen.ParagraphOptions{ .alignment = .justify, .line_breaking = .optimal, .line_height = 1.4 };

    var st = doc.createStyledText();
    defer st.deinit();
    try st.append("Same input, same bytes. ", .{ .bold = true });
    try st.append(body_text, .{});
    try st.append("Justified text here is set with ", .{});
    try st.append("Knuth-Plass optimal line breaking", .{ .italic = true });
    try st.append(", the algorithm behind TeX. ", .{});
    try st.append("Fonts are embedded and subset. ", .{ .bold = true });
    try st.append("TrueType and OpenType fonts are parsed once and cut down to ", .{});
    try st.append("only the glyphs you use", .{ .color = accent });
    try st.append(", so a page of text in a large font family still makes a small file. Kerning, ligatures and mark positioning come from the font's own OpenType tables: ", .{});
    try st.append("office, affluent, fjord, waffle", .{ .italic = true });
    try st.append(". Diacritics are positioned from GPOS anchors, stylistic sets and character variants can be switched per document, and color fonts are drawn as real vector glyphs. Nothing is cached between documents, so any number of them can be rendered on any number of threads.", .{});

    var measure = platen.Region{ .x = margin, .y = y, .width = col_w, .height = 10_000 };
    var measure_opts = para;
    measure_opts.measure_only = true;
    const total_lines = (try doc.writeStyled(&measure, &st, base, measure_opts)).lines_written;
    const line_h = base.size * para.line_height;
    const col_h = @as(f64, @floatFromInt((total_lines + 1) / 2)) * line_h + 1;

    var left = platen.Region{ .x = margin, .y = y, .width = col_w, .height = col_h };
    const first = try doc.writeStyled(&left, &st, base, para);
    var right = platen.Region{ .x = margin + col_w + col_gap, .y = y, .width = col_w, .height = 400 };
    if (first.resume_at) |pos| {
        var cont = para;
        cont.start = pos;
        _ = try doc.writeStyled(&right, &st, base, cont);
    }
    y += @max(left.cursor_y, right.cursor_y) + 26;

    // Pull quote
    var quote = platen.Region{ .x = margin + 18, .y = y, .width = full_w - 18, .height = 80 };
    _ = try doc.writeBlock(&quote, "\u{201C}Same input, same bytes \u{2014} on one core or on eight.\u{201D}", .{ .font = fonts.charter, .size = 20, .italic = true, .color = deep }, .{ .line_height = 1.3 });
    try doc.drawRect(.{ .x = margin, .y = y - 4, .width = 3, .height = quote.cursor_y + 4 }, .{ .fill = .{ .color = accent } });
    y += quote.cursor_y + 34;

    // Scripts and diacritics
    try sectionLabel(doc, fonts, y, "UNICODE, MARKS & SCRIPTS");
    y += 26;
    const samples = [_][]const u8{
        "Ἐν ἀρχῇ ἦν ὁ λόγος — Ελληνικά",
        "Съешь же ещё этих мягких французских булок",
        "Tiếng Việt · Ærøskøbing · Żółć · Ångström · ǅemal",
    };
    for (samples) |sample| {
        _ = try doc.writeAt(.{ .x = margin, .y = y }, sample, .{ .font = fonts.gentium, .size = 15, .color = ink }, .{});
        y += 25;
    }
    y += 14;

    // Families, weights and decorations
    try sectionLabel(doc, fonts, y, "FAMILIES, WEIGHTS & DECORATIONS");
    y += 34;
    var x: f64 = margin;
    const specimens = [_]struct { text: []const u8, style: platen.TextStyle }{
        .{ .text = "Inter Bold", .style = .{ .font = fonts.inter, .size = 24, .bold = true, .color = ink } },
        .{ .text = "Inter", .style = .{ .font = fonts.inter, .size = 18, .color = ink } },
        .{ .text = "Charter Italic", .style = .{ .font = fonts.charter, .size = 16, .italic = true, .color = muted } },
        .{ .text = "underlined", .style = .{ .font = fonts.charter, .size = 16, .color = deep, .decoration = .{ .underline = true } } },
        .{ .text = "struck", .style = .{ .font = fonts.charter, .size = 16, .color = accent, .decoration = .{ .strikethrough = true } } },
    };
    for (specimens) |sp| {
        const r = try doc.writeAt(.{ .x = x, .y = y }, sp.text, sp.style, .{});
        x += r.width + 18;
    }
    y += 44;

    // One family, five weights (each weight is its own face)
    try sectionLabel(doc, fonts, y, "SATOSHI, LIGHT TO BLACK");
    y += 34;
    const weights = [_][]const u8{ "Light", "Regular", "Medium", "Bold", "Black" };
    x = margin;
    for (weights) |w| {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "test/fonts/Satoshi/Satoshi-{s}.otf", .{w});
        const face = try doc.loadFont(path, .identity);
        const r = try doc.writeAt(.{ .x = x, .y = y }, w, .{ .font = face, .size = 22, .color = ink }, .{});
        x += r.width + 20;
    }
    y += 62;
    const black = try doc.loadFont("test/fonts/Satoshi/Satoshi-Black.otf", .identity);
    _ = try doc.writeAt(.{ .x = margin, .y = y }, "Typeset in Zig.", .{ .font = black, .size = 46, .color = deep }, .{});

    try footer(doc, fonts, "Charter, Gentium, Inter and Satoshi, embedded and subset by platen");
}

const band_stops = [_]platen.ColorStop{
    .{ .offset = 0.0, .color = platen.Color.rgb(36, 52, 110) },
    .{ .offset = 0.6, .color = platen.Color.rgb(120, 60, 140) },
    .{ .offset = 1.0, .color = accent },
};
const sphere_stops = [_]platen.ColorStop{
    .{ .offset = 0.0, .color = platen.Color.rgb(255, 236, 200) },
    .{ .offset = 1.0, .color = platen.Color.rgb(200, 80, 20) },
};

fn graphicsPage(doc: *platen.Document, fonts: Fonts) !void {
    try doc.addPage(.{});

    // Full-bleed gradient band behind the header
    const band = try doc.addLinearGradient(.{ .x0 = 0, .y0 = 0, .x1 = page_w, .y1 = 140, .stops = &band_stops });
    try doc.fillRectGradient(.{ .x = 0, .y = 0, .width = page_w, .height = 140 }, band);
    _ = try doc.writeAt(.{ .x = margin, .y = margin + 8 }, "VECTOR GRAPHICS", .{ .font = fonts.inter, .size = 9, .bold = true, .color = platen.Color.white, .char_spacing = 1.5 }, .{});
    _ = try doc.writeAt(.{ .x = margin, .y = margin + 40 }, "Shapes, paths & SVG", .{ .font = fonts.charter, .size = 30, .bold = true, .color = platen.Color.white }, .{});

    // SVG: the classic Ghostscript tiger
    const tiger = try doc.loadSvg("test/images/tiger.svg");
    try doc.drawSvg(tiger, .{ .x = margin - 10, .y = 160, .width = 290, .height = 290 });

    // Translucent overlapping circles
    const cx = 430.0;
    const cy = 290.0;
    const r = 62.0;
    const circle_colors = [_]platen.Color{ platen.Color.rgb(240, 80, 80), platen.Color.rgb(60, 170, 120), platen.Color.rgb(70, 110, 230) };
    const offsets = [_][2]f64{ .{ 0, -36 }, .{ -32, 20 }, .{ 32, 20 } };
    for (circle_colors, offsets) |c, o| {
        try doc.drawCircle(.{ .x = cx + o[0], .y = cy + o[1] }, r, .{ .fill = .{ .color = c, .opacity = 0.55 } });
    }
    _ = try doc.writeAt(.{ .x = cx, .y = 420 }, "fill opacity 0.55", .{ .font = fonts.inter, .size = 8, .color = muted }, .{ .anchor = .center });

    // Radial gradient sphere
    const sphere = try doc.addRadialGradient(.{ .x0 = 106, .y0 = 528, .r0 = 2, .x1 = 120, .y1 = 540, .r1 = 52, .stops = &sphere_stops });
    var circle_path = doc.createPath();
    defer circle_path.deinit();
    try appendCircle(&circle_path, 120, 540, 48);
    try doc.pushState();
    try doc.clipPath(&circle_path);
    try doc.fillRectGradient(.{ .x = 72, .y = 492, .width = 96, .height = 96 }, sphere);
    try doc.popState();

    // Rotated squares fan
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / 12.0;
        try doc.pushState();
        try doc.rotateAt(.{ .x = 300, .y = 540 }, t * 90);
        try doc.drawRect(.{ .x = 260, .y = 500, .width = 80, .height = 80 }, .{ .stroke = .{ .color = platen.Color.rgbf(0.15 + 0.7 * t, 0.25, 0.75 - 0.5 * t), .width = 1.2 } });
        try doc.popState();
    }

    // Rounded rect with dashed stroke
    try doc.drawRoundedRect(.{ .x = 400, .y = 496, .width = 140, .height = 88 }, 14, .{
        .fill = .{ .color = platen.Color.rgb(250, 240, 228) },
        .stroke = .{ .color = accent, .width = 2, .dash = .{ .dash = 6, .gap = 4 }, .cap = .round },
    });
    _ = try doc.writeAt(.{ .x = 470, .y = 545 }, "drawRoundedRect", .{ .font = fonts.inter, .size = 10, .bold = true, .color = ink }, .{ .anchor = .center });

    // Bezier wave
    var wave = doc.createPath();
    defer wave.deinit();
    try wave.moveTo(.{ .x = margin, .y = 680 });
    var x: f64 = margin;
    var up = true;
    while (x < 220) : (x += 60) {
        const dy: f64 = if (up) -60 else 60;
        try wave.curveTo(.{ .x = x + 20, .y = 680 + dy }, .{ .x = x + 40, .y = 680 + dy }, .{ .x = x + 60, .y = 680 });
        up = !up;
    }
    try doc.drawPath(&wave, .{ .stroke = .{ .color = deep, .width = 3, .cap = .round, .join = .round } });

    // SVG gradients: linear, radial with a focal point, href inheritance,
    // gradientTransform, user-space units, a hard edge; on text and strokes
    const gradients = try doc.loadSvg("test/images/gradients.svg");
    try doc.drawSvg(gradients, .{ .x = 256, .y = 628, .width = 160, .height = 112 });
    _ = try doc.writeAt(.{ .x = 336, .y = 758 }, "SVG gradients", .{ .font = fonts.inter, .size = 8, .color = muted }, .{ .anchor = .center });

    // Polygon star
    var star: [10]platen.Point = undefined;
    for (&star, 0..) |*p, k| {
        const ang = std.math.pi * (@as(f64, @floatFromInt(k)) / 5.0) - std.math.pi / 2.0;
        const rr: f64 = if (k % 2 == 0) 48 else 20;
        p.* = .{ .x = 486 + rr * @cos(ang), .y = 684 + rr * @sin(ang) };
    }
    try doc.drawPolygon(&star, .{ .fill = .{ .color = platen.Color.gold }, .stroke = .{ .color = accent, .width = 1.5, .join = .round } });

    try footer(doc, fonts, "SVG, gradients, clipping, transforms, transparency and Bezier paths");
}

/// Four-arc circle approximation (kappa = 0.5523).
fn appendCircle(path: *platen.Path, cx: f64, cy: f64, r: f64) !void {
    const k = 0.5523 * r;
    try path.moveTo(.{ .x = cx + r, .y = cy });
    try path.curveTo(.{ .x = cx + r, .y = cy + k }, .{ .x = cx + k, .y = cy + r }, .{ .x = cx, .y = cy + r });
    try path.curveTo(.{ .x = cx - k, .y = cy + r }, .{ .x = cx - r, .y = cy + k }, .{ .x = cx - r, .y = cy });
    try path.curveTo(.{ .x = cx - r, .y = cy - k }, .{ .x = cx - k, .y = cy - r }, .{ .x = cx, .y = cy - r });
    try path.curveTo(.{ .x = cx + k, .y = cy - r }, .{ .x = cx + r, .y = cy - k }, .{ .x = cx + r, .y = cy });
    try path.closePath();
}

fn colorPage(doc: *platen.Document, fonts: Fonts) !void {
    try doc.addPage(.{});
    try header(doc, fonts, "COLOR FONTS & IMAGES", "Emoji, color type, pictures");

    // COLRv1 color font: gradients inside the glyphs
    _ = try doc.writeAt(.{ .x = margin, .y = 190 }, "PLATEN", .{ .font = fonts.bungee, .size = 72 }, .{});
    _ = try doc.writeAt(.{ .x = margin, .y = 212 }, "Bungee Spice \u{2014} a COLRv1 font with gradient fills", .{ .font = fonts.inter, .size = 8, .color = muted }, .{});

    // Emoji grid (Noto Color Emoji, COLRv1)
    const emoji_rows = [_][7][]const u8{
        .{ "\u{1F600}", "\u{1F60D}", "\u{1F929}", "\u{1F973}", "\u{1F60E}", "\u{1F914}", "\u{1F92F}" },
        .{ "\u{1F680}", "\u{1F308}", "\u{1F525}", "\u{2B50}", "\u{1F30D}", "\u{1F319}", "\u{26A1}" },
        .{ "\u{1F355}", "\u{1F369}", "\u{1F34E}", "\u{1F951}", "\u{1F363}", "\u{2615}", "\u{1F382}" },
        .{ "\u{1F431}", "\u{1F98A}", "\u{1F427}", "\u{1F419}", "\u{1F98B}", "\u{1F984}", "\u{1F422}" },
    };
    var y: f64 = 268;
    for (emoji_rows) |row| {
        for (row, 0..) |e, k| {
            _ = try doc.writeAt(.{ .x = margin + @as(f64, @floatFromInt(k)) * 42, .y = y }, e, .{ .font = fonts.emoji, .size = 26 }, .{});
        }
        y += 42;
    }
    _ = try doc.writeAt(.{ .x = margin, .y = y - 10 }, "Noto Color Emoji, drawn as vector glyphs", .{ .font = fonts.inter, .size = 8, .color = muted }, .{});

    // PNG with alpha channel over a patterned background
    const ix = 380.0;
    const iy = 236.0;
    const iw = 160.0;
    const ih = 240.0;
    var row: usize = 0;
    while (row < 12) : (row += 1) {
        var col: usize = 0;
        while (col < 8) : (col += 1) {
            if ((row + col) % 2 == 0) {
                try doc.drawRect(.{ .x = ix + @as(f64, @floatFromInt(col)) * 20, .y = iy + @as(f64, @floatFromInt(row)) * 20, .width = 20, .height = 20 }, .{ .fill = .{ .color = platen.Color.rgb(232, 234, 240) } });
            }
        }
    }
    const robot = try doc.loadImage("test/images/robot_480.png");
    try doc.drawImage(robot, .{ .x = ix, .y = iy, .width = iw, .height = ih });
    _ = try doc.writeAt(.{ .x = ix + iw / 2, .y = iy + ih + 16 }, "PNG with alpha channel", .{ .font = fonts.inter, .size = 8, .color = muted }, .{ .anchor = .center });

    // The same typeface in two more color formats
    const formats = [_]struct { path: []const u8, caption: []const u8 }{
        .{ .path = "test/fonts/Bungee Color/BungeeColor-Regular-COLRv0.ttf", .caption = "COLRv0 (flat color layers)" },
        .{ .path = "test/fonts/Bungee Color/BungeeColor-Regular-SVG.ttf", .caption = "OpenType-SVG" },
    };
    for (formats, 0..) |f, k| {
        const fx = margin + @as(f64, @floatFromInt(k)) * 250;
        const face = try doc.loadFont(f.path, .identity);
        _ = try doc.writeAt(.{ .x = fx, .y = 584 }, "Color", .{ .font = face, .size = 44 }, .{});
        _ = try doc.writeAt(.{ .x = fx, .y = 604 }, f.caption, .{ .font = fonts.inter, .size = 8, .color = muted }, .{});
    }

    // Mixed text and emoji in a card
    const card_y = 646.0;
    try doc.drawRoundedRect(.{ .x = margin, .y = card_y, .width = page_w - 2 * margin, .height = 110 }, 12, .{ .fill = .{ .color = platen.Color.rgb(246, 247, 251) } });
    const title_rect = try doc.writeAt(.{ .x = margin + 20, .y = card_y + 40 }, "Text and emoji, side by side", .{ .font = fonts.inter, .size = 18, .bold = true, .color = ink }, .{});
    _ = try doc.writeAt(.{ .x = title_rect.x + title_rect.width + 8, .y = card_y + 40 }, "\u{1F389}", .{ .font = fonts.emoji, .size = 18 }, .{});
    var card = platen.Region{ .x = margin + 20, .y = card_y + 56, .width = page_w - 2 * margin - 40, .height = 60 };
    _ = try doc.writeBlock(&card, "Each run uses its own font: Inter for the words, Noto Color Emoji for the pictures. Text is measured with the same shaping as rendering, so runs can be placed precisely next to each other.", .{ .font = fonts.inter, .size = 10.5, .color = muted }, .{ .line_height = 1.45 });

    try footer(doc, fonts, "COLRv0, COLRv1 and SVG color fonts, emoji, and PNG transparency");
}

/// Cells for a monospaced screenplay line: Courier Prime at 12 pt
const cell_size: f64 = 12;

fn scriptsPage(doc: *platen.Document, fonts: Fonts) !void {
    try doc.addPage(.{});
    try header(doc, fonts, "SCRIPTS & FALLBACK", "Every character, a font");
    const full_w = page_w - 2 * margin;
    var y: f64 = margin + 86;

    // One style, three fonts: what Charter lacks comes from the fallbacks
    try sectionLabel(doc, fonts, y, "FALLBACK FONTS");
    y += 10;
    const fallbacks = [_]platen.Font{ fonts.gentium, fonts.emoji };
    const mixed = platen.TextStyle{ .font = fonts.charter, .size = 14, .color = ink, .fallback = &fallbacks };
    var block = platen.Region{ .x = margin, .y = y, .width = full_w, .height = 120 };
    _ = try doc.writeBlock(&block, "One style, three fonts. Charter sets the Latin; Gentium takes what Charter lacks, Greek (ἐν ἀρχῇ ἦν ὁ λόγος) " ++
        "and Cyrillic (съешь же ещё этих мягких французских булок); Noto Color Emoji draws the pictures \u{1F3DB}\u{FE0F} \u{1F4DC} \u{1F3A8} \u{1F984}.", mixed, .{ .line_height = 1.45 });
    y += block.cursor_y + 22;

    // Bold and italic: Charter's own faces; Gentium is loaded in Regular
    // only, so its bold and italic are synthesized
    try sectionLabel(doc, fonts, y, "SYNTHESIZED BOLD & ITALIC");
    y += 26;
    const styled = [_]struct { bold: bool, italic: bool }{ .{ .bold = true, .italic = false }, .{ .bold = false, .italic = true }, .{ .bold = true, .italic = true } };
    for (styled) |st| {
        var style = mixed;
        style.bold = st.bold;
        style.italic = st.italic;
        _ = try doc.writeAt(.{ .x = margin, .y = y }, "Charter \u{00B7} Ελληνικά \u{00B7} Русский", style, .{});
        y += 22;
    }
    _ = try doc.writeAt(.{ .x = margin, .y = y - 4 }, "Charter's own bold and italic; Gentium loaded in Regular only, its bold stroked and its italic slanted", .{ .font = fonts.inter, .size = 8, .color = muted }, .{});
    y += 24;

    // A screenplay in Courier Prime: every fallback cluster centered in
    // its cells (two for an emoji), so the columns hold
    try sectionLabel(doc, fonts, y, "MONOSPACE CELLS");
    y += 16;
    const courier = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf", .identity);
    const korean = try doc.loadFont("test/fonts/Noto Sans KR/NotoSansKR-Regular-subset.otf", .identity);
    const devanagari = try doc.loadFont("test/fonts/Noto Sans Devanagari/NotoSansDevanagari-Regular.ttf", .identity);
    const screen_fallbacks = [_]platen.Font{ fonts.gentium, korean, fonts.emoji };
    const mono = platen.TextStyle{ .font = courier, .size = cell_size, .color = ink, .fallback = &screen_fallbacks, .fallback_advance = .monospace, .fallback_max_em = 0.88 };
    const cell_w = cell_size * 0.6;
    const columns = 66;
    const lines = [_]struct { indent: u8, text: []const u8 }{
        .{ .indent = 0, .text = "INT. ΚΑΦΕΝΕΙΟ, ATHENS \u{2014} NIGHT" },
        .{ .indent = 0, .text = "" },
        .{ .indent = 0, .text = "Rain on the glass. MARIA (40s) slides a postcard \u{2709}\u{FE0F}" },
        .{ .indent = 0, .text = "across the table: \"Привет из Москвы!\"" },
        .{ .indent = 0, .text = "" },
        .{ .indent = 22, .text = "MARIA" },
        .{ .indent = 10, .text = "Γεια σου. You kept it? \u{1F642}" },
        .{ .indent = 0, .text = "" },
        .{ .indent = 22, .text = "NIKOLAI" },
        .{ .indent = 16, .text = "(in Russian)" },
        .{ .indent = 10, .text = "Конечно. Every word. \u{2615}\u{2615}" },
        .{ .indent = 0, .text = "" },
        .{ .indent = 22, .text = "SEO-YEON" },
        .{ .indent = 10, .text = "안녕하세요! 대본 있어요?" },
    };
    const line_h = cell_size * 1.25;
    const grid_top = y;
    const grid_h = @as(f64, @floatFromInt(lines.len)) * line_h + 6;
    var c: usize = 0;
    while (c <= columns) : (c += 1) {
        const gx = margin + @as(f64, @floatFromInt(c)) * cell_w;
        try doc.drawLine(.{ .x = gx, .y = grid_top }, .{ .x = gx, .y = grid_top + grid_h }, .{ .color = platen.Color.rgb(226, 229, 238), .width = 0.4 });
    }
    y += line_h;
    for (lines) |line| {
        if (line.text.len > 0) {
            _ = try doc.writeAt(.{ .x = margin + @as(f64, @floatFromInt(line.indent)) * cell_w, .y = y }, line.text, mono, .{});
        }
        y += line_h;
    }
    _ = try doc.writeAt(.{ .x = margin, .y = grid_top + grid_h + 14 }, "Courier Prime, falling back to Gentium, Noto Sans KR and emoji: centered in their cells, shrunk when wider (М)", .{ .font = fonts.inter, .size = 8, .color = muted }, .{});

    y = grid_top + grid_h + 46;

    // Complex scripts, shaped as HarfBuzz shapes them
    try sectionLabel(doc, fonts, y, "HANGUL & DEVANAGARI");
    y += 34;
    const ko = platen.TextStyle{ .font = korean, .size = 20, .color = ink };
    _ = try doc.writeAt(.{ .x = margin, .y = y }, "다람쥐 헌 쳇바퀴에 타고파", ko, .{});
    // Conjoining jamo apart, then together: one precomposed syllable
    const jamo = try doc.writeAt(.{ .x = margin + 300, .y = y }, "\u{1112} \u{1161} \u{11AB}  \u{2192}  ", ko, .{});
    _ = try doc.writeAt(.{ .x = jamo.x + jamo.width, .y = y }, "\u{1112}\u{1161}\u{11AB}", ko, .{});
    _ = try doc.writeAt(.{ .x = margin, .y = y + 18 }, "Noto Sans KR (CID-keyed CFF, subset). Right: three conjoining jamo apart, then composed into one syllable", .{ .font = fonts.inter, .size = 8, .color = muted }, .{});
    y += 56;
    const hi = platen.TextStyle{ .font = devanagari, .size = 20, .color = ink };
    _ = try doc.writeAt(.{ .x = margin, .y = y }, "नमस्ते दुनिया \u{2014} हिन्दी, क्षत्रिय, ज्ञान, श्री", hi, .{});
    _ = try doc.writeAt(.{ .x = margin, .y = y + 18 }, "Noto Sans Devanagari: conjuncts, and the i-matra drawn before its consonant cluster", .{ .font = fonts.inter, .size = 8, .color = muted }, .{});

    try footer(doc, fonts, "Fallback fonts, synthesized styles, monospace cells, Hangul and Devanagari, embedded and subset by platen");
}
