//! CLI commands for font collections and system font lookup:
//! font-faces, extract-face, find-font, shape.

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
/// Without --bold/--italic/--out, lists the whole family.
pub fn findFont(io: std.Io, allocator: Allocator, out: *std.Io.Writer, args: []const []const u8, home: ?[]const u8) !void {
    if (args.len < 1) return out.writeAll(
        \\Usage: platen find-font <family> [--bold] [--italic] [--no-prefilter]
        \\                        [--dir DIR]... [--out FILE]
        \\
    );
    var style: platen.system_fonts.Style = .{};
    var single = false;
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
