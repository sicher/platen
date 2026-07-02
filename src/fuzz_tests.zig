//! Fuzz tests hardening zapdf against malformed input and hostile API usage.
//!
//! Continuous fuzzing:
//!   zig build test --fuzz
//!
//! Under a plain `zig build test`, each fuzz body runs once per corpus seed
//! plus once with empty input, so these double as smoke tests.
//!
//! Two kinds of targets:
//! - Byte parsers (TTF, PNG/JPEG, SVG): raw fuzz-generated input. Any error
//!   return is acceptable; panics, hangs, and leaks are bugs.
//! - The Document API: a Smith-driven random sequence of drawing/text
//!   operations, finished with output(). The library must survive any call
//!   sequence and parameter values without crashing or leaking.

const std = @import("std");
const zapdf = @import("zapdf.zig");
const ttf = @import("ttf.zig");
const images = @import("images.zig");
const svg = @import("svg.zig");

const Smith = std.testing.Smith;

/// Upper bound for fuzz-generated parser input.
const max_input_len = 64 * 1024;

// ---------------------------------------------------------------------------
// Corpus helpers
// ---------------------------------------------------------------------------

/// `Smith.slice` consumes a 4-byte little-endian length prefix followed by
/// the slice bytes; wrap raw seed data in that framing so a corpus entry
/// reproduces the seed exactly.
fn frameSeed(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, data.len + 4);
    std.mem.writeInt(u32, out[0..4], @intCast(data.len), .little);
    @memcpy(out[4..], data);
    return out;
}

fn frameSeedFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const data = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(max_input_len),
    );
    defer allocator.free(data);
    return frameSeed(allocator, data);
}

/// Read fuzz input into `buf` and return the filled slice.
fn fuzzInput(smith: *Smith, buf: []u8) []const u8 {
    return buf[0..smith.slice(buf)];
}

// ---------------------------------------------------------------------------
// TTF parser
// ---------------------------------------------------------------------------

fn fuzzTtfParse(_: void, smith: *Smith) !void {
    const allocator = std.testing.allocator;
    const buf = try allocator.alloc(u8, max_input_len);
    defer allocator.free(buf);
    const data = fuzzInput(smith, buf);

    const font = ttf.Font.parse(data) catch return;

    // Exercise accessors on anything that parses successfully; they must not
    // trust offsets from the (malformed) table data.
    _ = font.isCFF();
    _ = font.isTrueType();
    _ = font.getCFFTable();
    _ = font.getFamilyName();
    _ = font.getStyleName();
    _ = font.getFullName();
    _ = font.getPostScriptName();

    const codepoint = smith.valueRangeAtMost(u21, 0, 0x10FFFF);
    if (font.getGlyphId(codepoint)) |glyph_id| {
        _ = font.getGlyphWidth(glyph_id);
        _ = font.getGlyphWidthFast(glyph_id, codepoint);
    }
    _ = font.getCharWidth(codepoint);
    _ = font.getGlyphWidth(smith.value(u16));
}

test "fuzz ttf.Font.parse" {
    const allocator = std.testing.allocator;
    const seed = try frameSeedFile(allocator, "test/fuzz/tiny.ttf");
    defer allocator.free(seed);
    try std.testing.fuzz({}, fuzzTtfParse, .{ .corpus = &.{seed} });
}

// ---------------------------------------------------------------------------
// Image parsers (PNG, JPEG)
// ---------------------------------------------------------------------------

fn fuzzImageFromMemory(_: void, smith: *Smith) !void {
    const allocator = std.testing.allocator;
    const buf = try allocator.alloc(u8, max_input_len);
    defer allocator.free(buf);
    const data = fuzzInput(smith, buf);

    const image = images.Image.fromMemory(allocator, data, false) catch return;
    image.deinit();
    allocator.destroy(image);
}

test "fuzz images.Image.fromMemory" {
    const allocator = std.testing.allocator;
    const seed_paths = [_][]const u8{
        "test/fuzz/tiny_rgb.png",
        "test/fuzz/tiny_gray.png",
        "test/fuzz/tiny_rgba.png",
        "test/fuzz/tiny.jpg",
        "test/fuzz/tiny_gray.jpg",
    };
    var seeds: [seed_paths.len][]const u8 = undefined;
    var n_seeds: usize = 0;
    defer for (seeds[0..n_seeds]) |s| allocator.free(s);
    for (seed_paths) |path| {
        seeds[n_seeds] = try frameSeedFile(allocator, path);
        n_seeds += 1;
    }
    try std.testing.fuzz({}, fuzzImageFromMemory, .{ .corpus = seeds[0..n_seeds] });
}

// ---------------------------------------------------------------------------
// SVG parser and renderer
// ---------------------------------------------------------------------------

fn fuzzSvgFromMemory(_: void, smith: *Smith) !void {
    const allocator = std.testing.allocator;
    const buf = try allocator.alloc(u8, max_input_len);
    defer allocator.free(buf);
    const data = fuzzInput(smith, buf);

    const s = svg.Svg.fromMemory(allocator, data) catch return;
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    // Also exercise rendering of whatever parsed.
    const content = s.toPdfContent(allocator) catch return;
    allocator.free(content);
}

const svg_seed_shapes =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 100 100">
    \\<rect x="1" y="2" width="30" height="40" fill="#f00" fill-opacity="0.5"/>
    \\<circle cx="9" cy="9" r="5" stroke="blue" stroke-width="2"/>
    \\<ellipse cx="50" cy="50" rx="20" ry="10" fill="green"/>
    \\<line x1="0" y1="0" x2="99" y2="99" stroke="black" stroke-linecap="round"/>
    \\<polygon points="10,10 40,10 25,40" fill="navy"/>
    \\<path d="M0 0 L10 10 C20 20 40 20 50 10 Q60 0 70 10 A5 5 0 0 1 80 20 Z"/>
    \\<g transform="translate(3,4) rotate(30) scale(1.5)"><rect width="5" height="5"/></g>
    \\<text x="5" y="95" font-family="serif" font-size="8">hi</text>
    \\</svg>
;

test "fuzz svg.Svg.fromMemory" {
    const allocator = std.testing.allocator;
    const file_seed = try frameSeedFile(allocator, "test/images/test.svg");
    defer allocator.free(file_seed);
    const shapes_seed = try frameSeed(allocator, svg_seed_shapes);
    defer allocator.free(shapes_seed);
    try std.testing.fuzz({}, fuzzSvgFromMemory, .{
        .corpus = &.{ file_seed, shapes_seed },
    });
}

// ---------------------------------------------------------------------------
// Document API
// ---------------------------------------------------------------------------

/// Mostly plausible page-space values; occasionally raw f64 bit patterns
/// (NaN, infinities, huge magnitudes) to probe numeric robustness.
fn fuzzCoord(smith: *Smith) f64 {
    if (smith.valueRangeAtMost(u8, 0, 7) == 0) return smith.value(f64);
    return @as(f64, @floatFromInt(smith.valueRangeAtMost(i32, -320_000, 320_000))) / 16.0;
}

fn fuzzPoint(smith: *Smith) zapdf.Point {
    return .{ .x = fuzzCoord(smith), .y = fuzzCoord(smith) };
}

fn fuzzRect(smith: *Smith) zapdf.Rect {
    return .{
        .x = fuzzCoord(smith),
        .y = fuzzCoord(smith),
        .width = fuzzCoord(smith),
        .height = fuzzCoord(smith),
    };
}

fn fuzzColor(smith: *Smith) zapdf.Color {
    return switch (smith.valueRangeAtMost(u8, 0, 2)) {
        0 => .{ .greyscale_val = fuzzCoord(smith) },
        1 => .{ .rgb_val = .{
            .r = fuzzCoord(smith),
            .g = fuzzCoord(smith),
            .b = fuzzCoord(smith),
        } },
        else => .{ .cmyk_val = .{
            .c = fuzzCoord(smith),
            .m = fuzzCoord(smith),
            .y = fuzzCoord(smith),
            .k = fuzzCoord(smith),
        } },
    };
}

fn fuzzStrokeStyle(smith: *Smith) zapdf.StrokeStyle {
    return .{
        .color = fuzzColor(smith),
        .width = fuzzCoord(smith),
        .cap = smith.value(zapdf.LineCap),
        .join = smith.value(zapdf.LineJoin),
        .dash = .{
            .dash = fuzzCoord(smith),
            .gap = fuzzCoord(smith),
            .phase = fuzzCoord(smith),
        },
        .opacity = fuzzCoord(smith),
    };
}

fn fuzzShapeStyle(smith: *Smith) zapdf.ShapeStyle {
    return .{
        .stroke = if (smith.value(bool)) fuzzStrokeStyle(smith) else null,
        .fill = if (smith.value(bool)) .{
            .color = fuzzColor(smith),
            .opacity = fuzzCoord(smith),
        } else null,
    };
}

fn fuzzTextStyle(smith: *Smith, embedded_font: ?zapdf.Font) zapdf.TextStyle {
    const font: zapdf.Font = switch (smith.valueRangeAtMost(u8, 0, 5)) {
        0 => zapdf.Font.helvetica,
        1 => zapdf.Font.times,
        2 => zapdf.Font.courier,
        3 => .symbol,
        4 => .zapf_dingbats,
        else => embedded_font orelse zapdf.Font.helvetica,
    };
    return .{
        .font = font,
        .size = fuzzCoord(smith),
        .bold = smith.value(bool),
        .italic = smith.value(bool),
        .color = fuzzColor(smith),
        .decoration = smith.value(zapdf.TextDecoration),
        .char_spacing = fuzzCoord(smith),
    };
}

const DocOp = enum {
    add_page,
    select_page,
    load_embedded_font,
    write_at,
    write_region,
    draw_line,
    draw_rect,
    draw_rounded_rect,
    draw_ellipse,
    draw_circle,
    draw_polygon,
    add_link,
};

const FuzzDocContext = struct {
    font_data: []const u8,
};

fn fuzzDocument(ctx: FuzzDocContext, smith: *Smith) !void {
    const allocator = std.testing.allocator;

    var doc = zapdf.Document.init(allocator, std.testing.io);
    defer doc.deinit();
    try doc.addPage(.{});

    var embedded_font: ?zapdf.Font = null;
    var text_buf: [48]u8 = undefined;

    var ops: usize = 0;
    while (ops < 64 and !smith.eos()) : (ops += 1) {
        switch (smith.value(DocOp)) {
            .add_page => doc.addPage(.{}) catch {},
            .select_page => doc.selectPage(smith.index(doc.getPageCount())),
            .load_embedded_font => {
                if (embedded_font == null) {
                    embedded_font = doc.loadFontFromMemory(ctx.font_data, null) catch null;
                }
            },
            .write_at => {
                const text = text_buf[0..smith.slice(&text_buf)];
                _ = doc.writeAt(fuzzPoint(smith), text, fuzzTextStyle(smith, embedded_font)) catch {};
            },
            .write_region => {
                var region = doc.getPageRegion() orelse continue;
                const text = text_buf[0..smith.slice(&text_buf)];
                _ = doc.write(&region, text, fuzzTextStyle(smith, embedded_font), .{}) catch {};
            },
            .draw_line => doc.drawLine(fuzzPoint(smith), fuzzPoint(smith), fuzzStrokeStyle(smith)) catch {},
            .draw_rect => doc.drawRect(fuzzRect(smith), fuzzShapeStyle(smith)) catch {},
            .draw_rounded_rect => doc.drawRoundedRect(fuzzRect(smith), fuzzCoord(smith), fuzzShapeStyle(smith)) catch {},
            .draw_ellipse => doc.drawEllipse(fuzzRect(smith), fuzzShapeStyle(smith)) catch {},
            .draw_circle => doc.drawCircle(fuzzPoint(smith), fuzzCoord(smith), fuzzShapeStyle(smith)) catch {},
            .draw_polygon => {
                var points: [6]zapdf.Point = undefined;
                const n = smith.valueRangeAtMost(u8, 0, points.len);
                for (points[0..n]) |*p| p.* = fuzzPoint(smith);
                doc.drawPolygon(points[0..n], fuzzShapeStyle(smith)) catch {};
            },
            .add_link => {
                const dest: zapdf.Destination = .{
                    .page_index = smith.index(doc.getPageCount()),
                    .y = fuzzCoord(smith),
                };
                doc.addLink(fuzzRect(smith), dest) catch {};
            },
        }
    }

    // Whatever sequence of calls happened, output() must produce a PDF (or a
    // clean error) without crashing or leaking.
    const out = doc.output() catch return;
    defer allocator.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "%PDF-"));
}

test "fuzz Document API" {
    const allocator = std.testing.allocator;
    const font_data = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "test/fuzz/tiny.ttf",
        allocator,
        .limited(max_input_len),
    );
    defer allocator.free(font_data);
    try std.testing.fuzz(
        FuzzDocContext{ .font_data = font_data },
        fuzzDocument,
        .{},
    );
}
