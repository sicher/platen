//! CLI commands for font collections and system font lookup:
//! font-faces, extract-face, find-font, shape, fallback.

const std = @import("std");
const platen = @import("platen.zig");

const Allocator = std.mem.Allocator;

/// font-faces <file>: one line per face.
pub fn fontFaces(io: std.Io, allocator: Allocator, out: *std.Io.Writer, args: []const []const u8) !void {
    if (args.len < 1) return out.writeAll("Usage: platen font-faces <font.ttc|ttf|otf>\n");
    const data = try std.Io.Dir.cwd().readFileAlloc(io, args[0], allocator, .limited(512 << 20));
    defer allocator.free(data);
    const faces = try platen.listFaces(allocator, data);
    defer platen.font_collection.freeFaces(allocator, faces);
    try out.print("{s}: {d} face(s){s}\n", .{ args[0], try platen.font_collection.faceCount(data), if (platen.font_collection.isCollection(data)) " (collection)" else "" });
    for (faces) |f| {
        try out.print("  {d:>3}  {s} | {s} | {s} | weight {d} width {d}{s}{s}\n", .{
            f.index, f.family, f.subfamily, f.postscript_name, f.weight, f.width, if (f.bold) " bold" else "", if (f.italic) " italic" else "",
        });
    }
}

/// shape <font> [+feat|-feat]...: shape each stdin line (UTF-8, one text
/// per line) through the same path rendering uses, and print its glyph IDs
/// space-separated, one line per input. Features not named keep their
/// defaults. Used by scripts/compare_shaping.py against HarfBuzz.
pub fn shape(io: std.Io, allocator: Allocator, out: *std.Io.Writer, args: []const []const u8) !void {
    if (args.len < 1) return out.writeAll("Usage: platen shape <font> [+feat|-feat]... < lines\n");
    const font = try platen.EmbeddedFont.fromFile(io, allocator, args[0]);
    defer font.deinit();
    for (args[1..]) |arg| {
        if (arg.len != 5 or (arg[0] != '+' and arg[0] != '-')) return out.print("Bad feature: {s} (use +liga or -liga)\n", .{arg});
        const feature = platen.opentype.Feature.fromTag(std.mem.readInt(u32, arg[1..5], .big)) orelse
            return out.print("Unknown feature: {s}\n", .{arg[1..]});
        font.setFeature(feature, arg[0] == '+');
    }

    var in_buffer: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &in_buffer);
    while (try stdin.interface.takeDelimiter('\n')) |line| {
        const glyphs = try font.markUnicodeCharsUsed(line, allocator);
        defer allocator.free(glyphs);
        for (glyphs, 0..) |gid, i| try out.print("{s}{d}", .{ if (i == 0) "" else " ", gid });
        try out.writeAll("\n");
    }
}

/// shape-text <font> [+feat|-feat]...: shape each stdin line with the pure
/// shapeText call and print its glyphs as HarfBuzz's hb-shape does
/// (--no-glyph-names): gid=cluster@x_offset,y_offset+x_advance, joined by
/// "|", the @ part only when an offset is nonzero; font units, clusters as
/// byte offsets. Used by scripts/compare_shaping.py against HarfBuzz.
pub fn shapeText(io: std.Io, allocator: Allocator, out: *std.Io.Writer, args: []const []const u8) !void {
    if (args.len < 1) return out.writeAll("Usage: platen shape-text <font> [+feat|-feat]... < lines\n");
    var face = try platen.FontFace.fromFile(io, allocator, args[0]);
    defer face.deinit();
    var features: std.ArrayList(platen.shaping.FeatureSetting) = .empty;
    defer features.deinit(allocator);
    for (args[1..]) |arg| {
        if (arg.len != 5 or (arg[0] != '+' and arg[0] != '-')) return out.print("Bad feature: {s} (use +liga or -liga)\n", .{arg});
        const feature = platen.opentype.Feature.fromTag(std.mem.readInt(u32, arg[1..5], .big)) orelse
            return out.print("Unknown feature: {s}\n", .{arg[1..]});
        try features.append(allocator, .{ .feature = feature, .enabled = arg[0] == '+' });
    }

    var in_buffer: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &in_buffer);
    while (try stdin.interface.takeDelimiter('\n')) |line| {
        const glyphs = try platen.shapeText(allocator, &face, line, .{ .features = features.items });
        defer allocator.free(glyphs);
        for (glyphs, 0..) |g, i| {
            try out.print("{s}{d}={d}", .{ if (i == 0) "" else "|", g.id, g.cluster });
            if (g.x_offset != 0 or g.y_offset != 0) try out.print("@{d},{d}", .{ g.x_offset, g.y_offset });
            try out.print("+{d}", .{g.x_advance});
        }
        try out.writeAll("\n");
    }
}

/// glyphs <out.pdf> <font> [--size PT] [+feat|-feat]...: shape each stdin
/// line with shapeText and draw it glyph by glyph with drawGlyphs, one line
/// per baseline; prints each line's glyph count and width.
pub fn drawGlyphs(io: std.Io, allocator: Allocator, out: *std.Io.Writer, args: []const []const u8) !void {
    if (args.len < 2) return out.writeAll("Usage: platen glyphs <out.pdf> <font> [--size PT] [+feat|-feat]... < lines\n");
    var face = try platen.FontFace.fromFile(io, allocator, args[1]);
    defer face.deinit();
    var size: f64 = 14;
    var features: std.ArrayList(platen.shaping.FeatureSetting) = .empty;
    defer features.deinit(allocator);
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--size") and i + 1 < args.len) {
            i += 1;
            size = try std.fmt.parseFloat(f64, args[i]);
        } else if (a.len == 5 and (a[0] == '+' or a[0] == '-')) {
            const feature = platen.opentype.Feature.fromTag(std.mem.readInt(u32, a[1..5], .big)) orelse
                return out.print("Unknown feature: {s}\n", .{a[1..]});
            try features.append(allocator, .{ .feature = feature, .enabled = a[0] == '+' });
        } else return out.print("Unknown option: {s}\n", .{a});
    }

    var doc = platen.Document.init(allocator, io);
    defer doc.deinit();
    try doc.addPage(.{});
    const scale = size / @as(f64, @floatFromInt(platen.shaping.unitsPerEm(&face)));
    var y: f64 = 72;
    var in_buffer: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &in_buffer);
    while (try stdin.interface.takeDelimiter('\n')) |line| {
        const shaped = try platen.shapeText(allocator, &face, line, .{ .features = features.items });
        defer allocator.free(shaped);
        const placed = try allocator.alloc(platen.PlacedGlyph, shaped.len);
        defer allocator.free(placed);
        var pen: f64 = 72;
        for (shaped, placed) |g, *p| {
            p.* = .{
                .id = g.id,
                .x = pen + @as(f64, @floatFromInt(g.x_offset)) * scale,
                .y = y - @as(f64, @floatFromInt(g.y_offset)) * scale,
                .cluster = g.cluster,
                .source = .{ .start = g.text_start, .end = g.text_end },
            };
            pen += @as(f64, @floatFromInt(g.x_advance)) * scale;
        }
        try doc.drawGlyphs(line, placed, .{ .font = .{ .face = &face }, .size = size });
        try out.print("{d} glyphs, {d:.3} pt\n", .{ shaped.len, pen - 72 });
        y += size * 1.5;
    }
    const pdf = try doc.output();
    defer allocator.free(pdf);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[0], .data = pdf });
}

/// extract-face <file> <index> <out.ttf>: write face N as a standalone sfnt.
pub fn extractFace(io: std.Io, allocator: Allocator, out: *std.Io.Writer, args: []const []const u8) !void {
    if (args.len < 3) return out.writeAll("Usage: platen extract-face <font.ttc> <index> <out.ttf>\n");
    const index = try std.fmt.parseInt(u32, args[1], 10);
    const data = try std.Io.Dir.cwd().readFileAlloc(io, args[0], allocator, .limited(512 << 20));
    defer allocator.free(data);
    const face = try platen.extractFace(allocator, data, index);
    defer allocator.free(face);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = face });
    try out.print("Wrote face {d} ({d} bytes): {s}\n", .{ index, face.len, args[2] });
}

/// find-font <family> [--bold] [--italic] [--all] [--no-prefilter]
///           [--dir DIR]... [--out FILE]
/// Without --bold/--italic/--out, shows the four faces findFamily picks;
/// --all lists every face of the family (listFamily), any weight or width.
pub fn findFont(io: std.Io, allocator: Allocator, out: *std.Io.Writer, args: []const []const u8, home: ?[]const u8) !void {
    if (args.len < 1) return out.writeAll(
        \\Usage: platen find-font <family> [--bold] [--italic] [--all] [--no-prefilter]
        \\                        [--dir DIR]... [--out FILE]
        \\
    );
    var style: platen.system_fonts.Style = .{};
    var single = false;
    var all = false;
    var opts: platen.SystemFontOptions = .{ .home = home };
    var dirs: std.ArrayList([]const u8) = .empty;
    defer dirs.deinit(allocator);
    var out_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--bold")) {
            style.bold = true;
            single = true;
        } else if (std.mem.eql(u8, a, "--italic")) {
            style.italic = true;
            single = true;
        } else if (std.mem.eql(u8, a, "--all")) {
            all = true;
        } else if (std.mem.eql(u8, a, "--no-prefilter")) {
            opts.prefilter = false;
        } else if (std.mem.eql(u8, a, "--dir") and i + 1 < args.len) {
            i += 1;
            try dirs.append(allocator, args[i]);
        } else if (std.mem.eql(u8, a, "--out") and i + 1 < args.len) {
            i += 1;
            out_path = args[i];
            single = true;
        } else {
            return out.print("Unknown option: {s}\n", .{a});
        }
    }
    if (dirs.items.len > 0) opts.dirs = dirs.items;

    if (all) {
        if (single) return out.writeAll("--all lists faces; it takes no --bold, --italic or --out\n");
        const faces = try platen.listSystemFontFaces(io, allocator, args[0], opts);
        defer platen.system_fonts.freeFamilyFaces(allocator, faces);
        if (faces.len == 0) return out.print("Not found: {s}\n", .{args[0]});
        for (faces) |f| try out.print("{s} | {s} | {s} | weight {d} width {d}{s} | {s} #{d}\n", .{
            f.info.family, f.info.subfamily, f.info.postscript_name, f.info.weight, f.info.width, if (f.info.italic) " italic" else "", f.path, f.info.index,
        });
        return;
    }
    if (single) {
        const f = try platen.findSystemFont(io, allocator, args[0], style, opts) orelse
            return out.print("Not found: {s}\n", .{args[0]});
        defer f.deinit(allocator);
        try printFound(out, "face", f);
        if (out_path) |p| {
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = f.data });
            try out.print("Wrote {d} bytes: {s}\n", .{ f.data.len, p });
        }
        return;
    }
    var fam = try platen.findSystemFontFamily(io, allocator, args[0], opts) orelse
        return out.print("Not found: {s}\n", .{args[0]});
    defer fam.deinit(allocator);
    const slots = [_]struct { []const u8, platen.system_fonts.Style }{
        .{ "regular", .{} },                .{ "bold", .{ .bold = true } },
        .{ "italic", .{ .italic = true } }, .{ "bold_italic", .{ .bold = true, .italic = true } },
    };
    for (slots) |s| {
        if (fam.face(s[1]).*) |f| try printFound(out, s[0], f) else try out.print("{s:<12} -\n", .{s[0]});
    }
}

fn printFound(out: *std.Io.Writer, label: []const u8, f: platen.FoundFont) !void {
    try out.print("{s:<12} {s} | {s} | {s} | {s} #{d} ({d} bytes)\n", .{
        label, f.family, f.subfamily, f.postscript_name, f.path, f.face_index, f.data.len,
    });
}

/// fallback <out.pdf> <font> [--fallback FONT]... [--monospace]
///          [--max-em F] [--bold] [--italic] [--size PT]: write each stdin line in <font>, with
///          the characters it lacks drawn from the fallback fonts in order
///          (TextStyle.fallback); prints each line's width. --bold/--italic
///          apply to the fallbacks (synthesized, as these are single faces),
///          so <font> itself must then be a family member that has them.
pub fn fallback(io: std.Io, allocator: Allocator, out: *std.Io.Writer, args: []const []const u8) !void {
    if (args.len < 2) return out.writeAll(
        \\Usage: platen fallback <out.pdf> <font> [--fallback FONT]... [--monospace]
        \\                       [--max-em F] [--bold] [--italic] [--size PT] < lines
        \\
    );
    var doc = platen.Document.init(allocator, io);
    defer doc.deinit();
    const primary = try doc.loadFont(args[1], .identity);
    var fallbacks: std.ArrayList(platen.Font) = .empty;
    defer fallbacks.deinit(allocator);
    var style: platen.TextStyle = .{ .font = primary, .size = 12 };
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--fallback") and i + 1 < args.len) {
            i += 1;
            try fallbacks.append(allocator, try doc.loadFont(args[i], .identity));
        } else if (std.mem.eql(u8, a, "--monospace")) {
            style.fallback_advance = .monospace;
        } else if (std.mem.eql(u8, a, "--max-em") and i + 1 < args.len) {
            i += 1;
            style.fallback_max_em = try std.fmt.parseFloat(f32, args[i]);
        } else if (std.mem.eql(u8, a, "--bold")) {
            style.bold = true;
        } else if (std.mem.eql(u8, a, "--italic")) {
            style.italic = true;
        } else if (std.mem.eql(u8, a, "--size") and i + 1 < args.len) {
            i += 1;
            style.size = try std.fmt.parseFloat(f64, args[i]);
        } else {
            return out.print("Unknown option: {s}\n", .{a});
        }
    }
    style.fallback = fallbacks.items;

    try doc.addPage(.{});
    var y: f64 = 72;
    var in_buffer: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &in_buffer);
    while (try stdin.interface.takeDelimiter('\n')) |line| {
        const rect = try doc.writeAt(.{ .x = 72, .y = y }, line, style, .{});
        try out.print("{d:.3}\t{s}\n", .{ rect.width, line });
        y += style.size * 1.2;
    }
    const pdf = try doc.output();
    defer allocator.free(pdf);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[0], .data = pdf });
}

/// graphemes: each stdin line's extended grapheme clusters (UAX #29), one
/// per line with its code points and the cells it takes with `.monospace`
/// fallback (unicode_props.cells).
pub fn graphemes(io: std.Io, out: *std.Io.Writer) !void {
    const props = platen.unicode_props;
    var in_buffer: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &in_buffer);
    while (try stdin.interface.takeDelimiter('\n')) |line| {
        var i: usize = 0;
        while (i < line.len) {
            const end = props.graphemeEndBytes(line, i);
            var cps: [32]u21 = undefined;
            var n: usize = 0;
            const view = std.unicode.Utf8View.init(line[i..end]) catch {
                try out.print("{d}..{d}\tinvalid UTF-8\n", .{ i, end });
                i = end;
                continue;
            };
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| : (n += 1) cps[n] = cp;
            try out.print("{d}..{d}\t{d} cell(s)\t", .{ i, end, props.cells(cps[0..n]) });
            for (cps[0..n], 0..) |cp, k| try out.print("{s}U+{X:0>4}", .{ if (k == 0) "" else " ", cp });
            try out.print("\t{s}\n", .{line[i..end]});
            i = end;
        }
    }
}
