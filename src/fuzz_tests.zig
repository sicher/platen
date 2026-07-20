//! Fuzz tests hardening platen against malformed input and hostile API usage.
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
const platen = @import("platen.zig");
const ttf = @import("ttf.zig");
const images = @import("images.zig");
const svg = @import("svg.zig");
const colr = @import("colr.zig");
const bitmap_glyphs = @import("bitmap_glyphs.zig");
const svg_table = @import("svg_table.zig");

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

/// Read a whole font file (fonts may exceed max_input_len; only extracted
/// tables are size-capped).
fn readFontFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(32 * 1024 * 1024),
    );
}

/// Extract font tables and concatenate them as framed slices, so a corpus
/// seed feeds each table to the fuzz body's successive `Smith.slice` reads.
/// Tables larger than max_input_len are truncated (the fuzz body's input
/// buffers cannot hold more anyway).
fn frameSeedFontTables(
    allocator: std.mem.Allocator,
    font_path: []const u8,
    tags: []const [4]u8,
) ![]u8 {
    const data = try readFontFile(allocator, font_path);
    defer allocator.free(data);
    const font = try ttf.Font.parse(data);

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);
    for (tags) |tag| {
        const table = font.getTable(tag) orelse return error.MissingTable;
        const capped = table[0..@min(table.len, max_input_len)];
        const framed = try frameSeed(allocator, capped);
        defer allocator.free(framed);
        try out.appendSlice(allocator, framed);
    }
    return out.toOwnedSlice(allocator);
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
// COLR/CPAL color-font tables and paint-graph interpreter
// ---------------------------------------------------------------------------

const FuzzColrContext = struct {
    /// Real CPAL fallback and glyf context from a fixture font, so the paint
    /// interpreter can be driven even when the fuzzed CPAL fails to parse.
    cpal: colr.Cpal,
    glyf: colr.GlyfContext,
};

/// Drive the COLR/CPAL parsers and the paint interpreter over (possibly
/// malformed) table bytes: parse errors are fine; whatever parses must
/// answer queries and render (or error) without crashing, hanging, or
/// leaking. `probe_gid`/`probe_index` add out-of-range lookups.
fn exerciseColrTables(
    ctx: FuzzColrContext,
    colr_data: []const u8,
    cpal_data: []const u8,
    probe_gid: u16,
    probe_index: u32,
) void {
    const allocator = std.testing.allocator;

    const fuzzed_cpal: ?colr.Cpal = colr.Cpal.parse(cpal_data) catch null;
    if (fuzzed_cpal) |p| {
        _ = p.color(0);
        _ = p.color(colr.Cpal.foreground_index);
        _ = p.color(probe_gid);
    }

    const c = colr.Colr.parse(colr_data) catch return;

    // Query paths (v0 records and v1 paint-graph lookups).
    var gid: u16 = 0;
    while (gid < 16) : (gid += 1) {
        _ = c.isColorGlyph(gid);
        if (c.v0BaseGlyph(gid)) |base| {
            _ = c.v0Layer(base.first);
        }
        _ = c.baseGlyphPaint(gid);
    }
    _ = c.isColorGlyph(probe_gid);
    _ = c.v0Layer(probe_index);
    _ = c.layerPaint(probe_index);

    // Paint-graph interpreter: malformed graphs (bad offsets, cycles, deep
    // nesting) must error or render garbage, never crash or hang.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var res = colr.ColorResources.init(allocator);
    defer res.deinit();
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var interp = colr.PaintInterp{
        .w = &aw.writer,
        .arena = arena_state.allocator(),
        .colr = c,
        .cpal = fuzzed_cpal orelse ctx.cpal,
        .glyf = ctx.glyf,
        .res = &res,
    };
    var rendered: usize = 0;
    gid = 0;
    while (gid < 512 and rendered < 4) : (gid += 1) {
        if (!c.isColorGlyph(gid)) continue;
        rendered += 1;
        interp.render(gid) catch {};
    }
    interp.render(probe_gid) catch {};
}

fn fuzzColrTables(ctx: FuzzColrContext, smith: *Smith) !void {
    const allocator = std.testing.allocator;
    const colr_buf = try allocator.alloc(u8, max_input_len);
    defer allocator.free(colr_buf);
    const colr_data = fuzzInput(smith, colr_buf);
    var cpal_buf: [4096]u8 = undefined;
    const cpal_data = cpal_buf[0..smith.slice(&cpal_buf)];

    exerciseColrTables(ctx, colr_data, cpal_data, smith.value(u16), smith.value(u32));
}

/// Load the fixture font backing FuzzColrContext. The returned font data
/// must outlive any use of the context.
const ColrFixture = struct {
    font_data: []u8,
    ctx: FuzzColrContext,

    fn deinit(self: *ColrFixture, allocator: std.mem.Allocator) void {
        allocator.free(self.font_data);
    }
};

fn loadColrFixture(allocator: std.mem.Allocator) !ColrFixture {
    // A real COLRv1 font's CPAL and glyf tables.
    const font_data = try readFontFile(allocator, "test/fonts/Bungee Color/BungeeSpice-Regular-COLRv1.ttf");
    errdefer allocator.free(font_data);
    const font = try ttf.Font.parse(font_data);
    const head = font.head.?;
    return .{
        .font_data = font_data,
        .ctx = .{
            .cpal = try colr.Cpal.parse(font.getTable("CPAL".*).?),
            .glyf = .{
                .glyf = font.getTable("glyf".*).?,
                .loca = font.getTable("loca".*).?,
                .loca_format = head.index_to_loc_format,
            },
        },
    };
}

/// COLR fixture fonts covering v0 layers, v1 paint graphs, and v1 sweep
/// gradients.
const colr_seed_fonts = [_][]const u8{
    "test/fonts/sweep/SweepTest.ttf",
    "test/fonts/Bungee Color/BungeeColor-Regular-COLRv0.ttf",
    "test/fonts/Bungee Color/BungeeSpice-Regular-COLRv1.ttf",
};

test "fuzz colr COLR/CPAL parse and render" {
    const allocator = std.testing.allocator;

    var fixture = try loadColrFixture(allocator);
    defer fixture.deinit(allocator);
    const ctx = fixture.ctx;
    const seed_fonts = colr_seed_fonts;
    var seeds: [seed_fonts.len][]const u8 = undefined;
    var n_seeds: usize = 0;
    defer for (seeds[0..n_seeds]) |s| allocator.free(s);
    for (seed_fonts) |path| {
        seeds[n_seeds] = try frameSeedFontTables(allocator, path, &.{ "COLR".*, "CPAL".* });
        n_seeds += 1;
    }
    try std.testing.fuzz(ctx, fuzzColrTables, .{ .corpus = seeds[0..n_seeds] });
}

// ---------------------------------------------------------------------------
// Bitmap glyph tables (CBDT/CBLC, EBDT/EBLC, sbix)
// ---------------------------------------------------------------------------

/// Mirror the production path for a looked-up glyph: probe PNG dimensions
/// for color strikes, repack rows for mono strikes (dims are u8-bounded, so
/// allocations stay small).
fn exerciseBitmapGlyph(allocator: std.mem.Allocator, maybe_bg: ?bitmap_glyphs.BitmapGlyph) void {
    const bg = maybe_bg orelse return;
    switch (bg.pixels) {
        .png => |png| _ = bitmap_glyphs.pngDimensions(png),
        .mono => |mono| {
            const rows = bitmap_glyphs.packMonoRows(allocator, mono, bg.width_px, bg.height_px) catch return;
            allocator.free(rows);
        },
    }
}

/// Drive the CBLC/CBDT (or EBLC/EBDT) parser and glyph lookups over
/// (possibly malformed) table bytes.
fn exerciseCbdtTables(cblc: []const u8, cbdt: []const u8, probe_gid: u16) void {
    const allocator = std.testing.allocator;
    const parsed = bitmap_glyphs.Cbdt.parse(cblc, cbdt) catch return;
    var gid: u16 = 0;
    while (gid < 16) : (gid += 1) {
        exerciseBitmapGlyph(allocator, parsed.glyphBitmap(gid));
    }
    exerciseBitmapGlyph(allocator, parsed.glyphBitmap(probe_gid));
}

fn fuzzCbdtParse(_: void, smith: *Smith) !void {
    const allocator = std.testing.allocator;
    const cblc_buf = try allocator.alloc(u8, max_input_len);
    defer allocator.free(cblc_buf);
    const cblc = fuzzInput(smith, cblc_buf);
    const cbdt_buf = try allocator.alloc(u8, max_input_len);
    defer allocator.free(cbdt_buf);
    const cbdt = fuzzInput(smith, cbdt_buf);

    exerciseCbdtTables(cblc, cbdt, smith.value(u16));
}

test "fuzz bitmap_glyphs.Cbdt.parse" {
    const allocator = std.testing.allocator;
    // CBLC/CBDT (PNG strikes) and EBLC/EBDT (1-bit pixel strikes) seeds;
    // EBLC shares CBLC's layout so one parser (and one target) covers both.
    const seed_specs = [_]struct { path: []const u8, tags: [2][4]u8 }{
        .{ .path = "test/fonts/bitmap/CbdtTest.ttf", .tags = .{ "CBLC".*, "CBDT".* } },
        .{ .path = "test/fonts/Noto_Color_Emoji/NotoColorEmoji-CBDT-subset.ttf", .tags = .{ "CBLC".*, "CBDT".* } },
        .{ .path = "test/fonts/Cozette/cozette.otb", .tags = .{ "EBLC".*, "EBDT".* } },
    };
    var seeds: [seed_specs.len][]const u8 = undefined;
    var n_seeds: usize = 0;
    defer for (seeds[0..n_seeds]) |s| allocator.free(s);
    for (seed_specs) |spec| {
        seeds[n_seeds] = try frameSeedFontTables(allocator, spec.path, &spec.tags);
        n_seeds += 1;
    }
    try std.testing.fuzz({}, fuzzCbdtParse, .{ .corpus = seeds[0..n_seeds] });
}

/// Drive the sbix parser and glyph lookups over (possibly malformed) table
/// bytes. num_glyphs comes from maxp in production, so it varies
/// independently of the table bytes; fixed values keep lookups exercised
/// even when `probe_gid` is 0.
fn exerciseSbixTable(data: []const u8, probe_gid: u16) void {
    const allocator = std.testing.allocator;
    for ([_]u16{ 4, 300, probe_gid }) |num_glyphs| {
        const parsed = bitmap_glyphs.Sbix.parse(data, num_glyphs) catch continue;
        var gid: u16 = 0;
        while (gid < 16) : (gid += 1) {
            exerciseBitmapGlyph(allocator, parsed.glyphBitmap(gid));
        }
        exerciseBitmapGlyph(allocator, parsed.glyphBitmap(probe_gid));
    }
}

fn fuzzSbixParse(_: void, smith: *Smith) !void {
    const allocator = std.testing.allocator;
    const buf = try allocator.alloc(u8, max_input_len);
    defer allocator.free(buf);
    const data = fuzzInput(smith, buf);

    exerciseSbixTable(data, smith.value(u16));
}

test "fuzz bitmap_glyphs.Sbix.parse" {
    const allocator = std.testing.allocator;
    const seed = try frameSeedFontTables(allocator, "test/fonts/bitmap/SbixTest.ttf", &.{"sbix".*});
    defer allocator.free(seed);
    try std.testing.fuzz({}, fuzzSbixParse, .{ .corpus = &.{seed} });
}

// ---------------------------------------------------------------------------
// OT-SVG table
// ---------------------------------------------------------------------------

/// Drive the OT-SVG table parser and per-glyph document rendering over
/// (possibly malformed) table bytes.
fn exerciseSvgTable(data: []const u8, probe_gid: u16) void {
    const allocator = std.testing.allocator;
    const table = svg_table.SvgTable.parse(data) catch return;
    var gid: u16 = 0;
    while (gid < 16) : (gid += 1) {
        exerciseSvgDoc(allocator, table.docForGlyph(gid));
    }
    exerciseSvgDoc(allocator, table.docForGlyph(probe_gid));
}

fn fuzzSvgTableParse(_: void, smith: *Smith) !void {
    const allocator = std.testing.allocator;
    const buf = try allocator.alloc(u8, max_input_len);
    defer allocator.free(buf);
    const data = fuzzInput(smith, buf);

    exerciseSvgTable(data, smith.value(u16));
}

/// Mirror the production path: parse and render a glyph's SVG document.
fn exerciseSvgDoc(allocator: std.mem.Allocator, maybe_doc: ?[]const u8) void {
    const doc = maybe_doc orelse return;
    const s = svg.Svg.fromMemory(allocator, doc) catch return;
    defer {
        s.deinit();
        allocator.destroy(s);
    }
    const content = s.toPdfContent(allocator) catch return;
    allocator.free(content);
}

test "fuzz svg_table.SvgTable.parse" {
    const allocator = std.testing.allocator;
    const seed_fonts = [_][]const u8{
        "test/fonts/svg/SvgTest.ttf",
        "test/fonts/Bungee Color/BungeeColor-Regular-SVG.ttf",
    };
    var seeds: [seed_fonts.len][]const u8 = undefined;
    var n_seeds: usize = 0;
    defer for (seeds[0..n_seeds]) |s| allocator.free(s);
    for (seed_fonts) |path| {
        seeds[n_seeds] = try frameSeedFontTables(allocator, path, &.{"SVG ".*});
        n_seeds += 1;
    }
    try std.testing.fuzz({}, fuzzSvgTableParse, .{ .corpus = seeds[0..n_seeds] });
}

// ---------------------------------------------------------------------------
// Deterministic mutation tests
//
// Unlike the coverage-guided `--fuzz` targets above, these run on every
// plain `zig build test`: each color-font parser is driven with a few
// hundred seeded random mutations (bit flips, byte stomps, truncations) of
// its real fixture tables, catching offset-validation regressions
// deterministically.
// ---------------------------------------------------------------------------

/// Owned copy of one font table, capped to max_input_len.
fn dupeFontTable(allocator: std.mem.Allocator, font_path: []const u8, tag: [4]u8) ![]u8 {
    const data = try readFontFile(allocator, font_path);
    defer allocator.free(data);
    const font = try ttf.Font.parse(data);
    const table = font.getTable(tag) orelse return error.MissingTable;
    return allocator.dupe(u8, table[0..@min(table.len, max_input_len)]);
}

/// A mutated copy of `original`: occasionally truncated, always with 1-8
/// random bit flips or byte stomps.
fn mutateCopy(allocator: std.mem.Allocator, random: std.Random, original: []const u8) ![]u8 {
    const keep = if (original.len > 0 and random.uintLessThan(u8, 8) == 0)
        random.uintAtMost(usize, original.len)
    else
        original.len;
    const buf = try allocator.dupe(u8, original[0..keep]);
    if (buf.len == 0) return buf;
    const n_edits = 1 + random.uintLessThan(usize, 8);
    for (0..n_edits) |_| {
        const off = random.uintLessThan(usize, buf.len);
        if (random.boolean()) {
            buf[off] ^= @as(u8, 1) << random.int(u3);
        } else {
            buf[off] = random.int(u8);
        }
    }
    return buf;
}

test "mutated fixture bytes: COLR/CPAL" {
    const allocator = std.testing.allocator;
    var fixture = try loadColrFixture(allocator);
    defer fixture.deinit(allocator);

    var prng = std.Random.DefaultPrng.init(0xc0102c0102);
    const random = prng.random();

    for (colr_seed_fonts) |path| {
        const colr_orig = try dupeFontTable(allocator, path, "COLR".*);
        defer allocator.free(colr_orig);
        const cpal_orig = try dupeFontTable(allocator, path, "CPAL".*);
        defer allocator.free(cpal_orig);
        for (0..256) |round| {
            // Mutate COLR, CPAL, or both, so intact graphs also meet broken
            // palettes and vice versa.
            const colr_mut = if (round % 4 != 1)
                try mutateCopy(allocator, random, colr_orig)
            else
                try allocator.dupe(u8, colr_orig);
            defer allocator.free(colr_mut);
            const cpal_mut = if (round % 4 != 2)
                try mutateCopy(allocator, random, cpal_orig)
            else
                try allocator.dupe(u8, cpal_orig);
            defer allocator.free(cpal_mut);
            exerciseColrTables(fixture.ctx, colr_mut, cpal_mut, random.int(u16), random.int(u32));
        }
    }
}

test "mutated fixture bytes: CBDT/CBLC and EBDT/EBLC" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xcbd7cbd7);
    const random = prng.random();

    const specs = [_]struct { path: []const u8, tags: [2][4]u8 }{
        .{ .path = "test/fonts/bitmap/CbdtTest.ttf", .tags = .{ "CBLC".*, "CBDT".* } },
        .{ .path = "test/fonts/Noto_Color_Emoji/NotoColorEmoji-CBDT-subset.ttf", .tags = .{ "CBLC".*, "CBDT".* } },
        .{ .path = "test/fonts/Cozette/cozette.otb", .tags = .{ "EBLC".*, "EBDT".* } },
    };
    for (specs) |spec| {
        const cblc_orig = try dupeFontTable(allocator, spec.path, spec.tags[0]);
        defer allocator.free(cblc_orig);
        const cbdt_orig = try dupeFontTable(allocator, spec.path, spec.tags[1]);
        defer allocator.free(cbdt_orig);
        for (0..256) |round| {
            const cblc_mut = if (round % 4 != 1)
                try mutateCopy(allocator, random, cblc_orig)
            else
                try allocator.dupe(u8, cblc_orig);
            defer allocator.free(cblc_mut);
            const cbdt_mut = if (round % 4 != 2)
                try mutateCopy(allocator, random, cbdt_orig)
            else
                try allocator.dupe(u8, cbdt_orig);
            defer allocator.free(cbdt_mut);
            exerciseCbdtTables(cblc_mut, cbdt_mut, random.int(u16));
        }
    }
}

test "mutated fixture bytes: sbix" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5b1c5b1c);
    const random = prng.random();

    const sbix_orig = try dupeFontTable(allocator, "test/fonts/bitmap/SbixTest.ttf", "sbix".*);
    defer allocator.free(sbix_orig);
    for (0..256) |_| {
        const mut = try mutateCopy(allocator, random, sbix_orig);
        defer allocator.free(mut);
        exerciseSbixTable(mut, random.int(u16));
    }
}

test "mutated fixture bytes: OT-SVG" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5f65f6);
    const random = prng.random();

    const seed_fonts = [_][]const u8{
        "test/fonts/svg/SvgTest.ttf",
        "test/fonts/Bungee Color/BungeeColor-Regular-SVG.ttf",
    };
    for (seed_fonts) |path| {
        const orig = try dupeFontTable(allocator, path, "SVG ".*);
        defer allocator.free(orig);
        // Fewer rounds: mildly-mutated tables still yield full XML parses.
        for (0..64) |_| {
            const mut = try mutateCopy(allocator, random, orig);
            defer allocator.free(mut);
            exerciseSvgTable(mut, random.int(u16));
        }
    }
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

fn fuzzPoint(smith: *Smith) platen.Point {
    return .{ .x = fuzzCoord(smith), .y = fuzzCoord(smith) };
}

fn fuzzRect(smith: *Smith) platen.Rect {
    return .{
        .x = fuzzCoord(smith),
        .y = fuzzCoord(smith),
        .width = fuzzCoord(smith),
        .height = fuzzCoord(smith),
    };
}

fn fuzzColor(smith: *Smith) platen.Color {
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

fn fuzzStrokeStyle(smith: *Smith) platen.StrokeStyle {
    return .{
        .color = fuzzColor(smith),
        .width = fuzzCoord(smith),
        .cap = smith.value(platen.LineCap),
        .join = smith.value(platen.LineJoin),
        .dash = .{
            .dash = fuzzCoord(smith),
            .gap = fuzzCoord(smith),
            .phase = fuzzCoord(smith),
        },
        .opacity = fuzzCoord(smith),
    };
}

fn fuzzShapeStyle(smith: *Smith) platen.ShapeStyle {
    return .{
        .stroke = if (smith.value(bool)) fuzzStrokeStyle(smith) else null,
        .fill = if (smith.value(bool)) .{
            .color = fuzzColor(smith),
            .opacity = fuzzCoord(smith),
        } else null,
    };
}

fn fuzzTextStyle(smith: *Smith, embedded_font: ?platen.Font) platen.TextStyle {
    const font: platen.Font = switch (smith.valueRangeAtMost(u8, 0, 5)) {
        0 => platen.Font.helvetica,
        1 => platen.Font.times,
        2 => platen.Font.courier,
        3 => .symbol,
        4 => .zapf_dingbats,
        else => embedded_font orelse platen.Font.helvetica,
    };
    return .{
        .font = font,
        .size = fuzzCoord(smith),
        .bold = smith.value(bool),
        .italic = smith.value(bool),
        .color = fuzzColor(smith),
        .decoration = smith.value(platen.TextDecoration),
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

    var doc = platen.Document.init(allocator, std.testing.io);
    defer doc.deinit();
    try doc.addPage(.{});

    var embedded_font: ?platen.Font = null;
    var text_buf: [48]u8 = undefined;

    var ops: usize = 0;
    while (ops < 64 and !smith.eos()) : (ops += 1) {
        switch (smith.value(DocOp)) {
            .add_page => doc.addPage(.{}) catch {},
            .select_page => doc.selectPage(smith.index(doc.getPageCount())),
            .load_embedded_font => {
                if (embedded_font == null) {
                    embedded_font = doc.loadFontFromMemory(ctx.font_data, .identity) catch null;
                }
            },
            .write_at => {
                const text = text_buf[0..smith.slice(&text_buf)];
                _ = doc.writeAt(fuzzPoint(smith), text, fuzzTextStyle(smith, embedded_font), .{}) catch {};
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
                var points: [6]platen.Point = undefined;
                const n = smith.valueRangeAtMost(u8, 0, points.len);
                for (points[0..n]) |*p| p.* = fuzzPoint(smith);
                doc.drawPolygon(points[0..n], fuzzShapeStyle(smith)) catch {};
            },
            .add_link => {
                const dest: platen.Destination = .{
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
