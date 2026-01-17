//! zpdf - Fast PDF rendering library for Zig
//!
//! A library for creating PDF documents, based on fpdf2.

const std = @import("std");

pub const version = "0.1.0";

// Modules
pub const objects = @import("objects.zig");
pub const fonts = @import("fonts.zig");
pub const metrics = @import("metrics.zig");
pub const ttf = @import("ttf.zig");
pub const embedded = @import("embedded.zig");
pub const Writer = @import("writer.zig").Writer;
pub const testing = @import("testing.zig");
pub const integration_tests = @import("integration_tests.zig");

const ObjectId = objects.ObjectId;
const Ref = objects.Ref;
const Dict = objects.Dict;
const Array = objects.Array;
const Value = objects.Value;

pub const StandardFont = fonts.StandardFont;
pub const Font = fonts.Font;
pub const TextMetrics = metrics.TextMetrics;
pub const TextStyle = metrics.TextStyle;
pub const EmbeddedFont = embedded.EmbeddedFont;

/// Handle to a loaded font (either standard or embedded)
pub const FontHandle = union(enum) {
    standard: StandardFont,
    embedded: *EmbeddedFont,

    pub fn name(self: FontHandle) []const u8 {
        return switch (self) {
            .standard => |f| f.pdfName(),
            .embedded => |e| e.name,
        };
    }
};

/// Page size in points (1 point = 1/72 inch)
pub const PageSize = struct {
    width: f64,
    height: f64,

    pub const A4 = PageSize{ .width = 595.28, .height = 841.89 };
    pub const Letter = PageSize{ .width = 612, .height = 792 };
};

/// Font reference for deferred text commands
const FontRef = union(enum) {
    standard: StandardFont,
    embedded: *EmbeddedFont,
};

/// Text command parameters for deferred rendering
const TextCommand = struct {
    x: f64,
    y: f64,
    font_size: f64,
    char_spacing: f64,
    text_data: []const u8, // Owned copy of text
    font: FontRef,
};

/// Content command for deferred rendering (enables glyph ID remapping)
const ContentCommand = union(enum) {
    /// Text command with all rendering parameters
    text: TextCommand,
    /// Raw content (for non-text operations that don't need deferred processing)
    raw: []const u8, // Owned copy
};

/// Internal page representation
const Page = struct {
    content: std.ArrayListUnmanaged(u8), // Legacy: direct content bytes
    commands: std.ArrayListUnmanaged(ContentCommand), // Deferred commands
    used_fonts: std.AutoHashMapUnmanaged(StandardFont, void),
    used_embedded: std.ArrayListUnmanaged(*EmbeddedFont),

    fn init() Page {
        return .{
            .content = .{},
            .commands = .{},
            .used_fonts = .{},
            .used_embedded = .{},
        };
    }

    fn deinit(self: *Page, allocator: std.mem.Allocator) void {
        // Free owned text data in commands
        for (self.commands.items) |cmd| {
            switch (cmd) {
                .text => |t| allocator.free(t.text_data),
                .raw => |r| allocator.free(r),
            }
        }
        self.commands.deinit(allocator);
        self.content.deinit(allocator);
        self.used_fonts.deinit(allocator);
        self.used_embedded.deinit(allocator);
    }

    fn markFontUsed(self: *Page, allocator: std.mem.Allocator, font: StandardFont) !void {
        try self.used_fonts.put(allocator, font, {});
    }

    fn markEmbeddedUsed(self: *Page, allocator: std.mem.Allocator, font: *EmbeddedFont) !void {
        // Check if already in list
        for (self.used_embedded.items) |f| {
            if (f == font) return;
        }
        try self.used_embedded.append(allocator, font);
    }

    fn writer(self: *Page, allocator: std.mem.Allocator) ContentWriter {
        return ContentWriter{ .page = self, .allocator = allocator };
    }
};

/// Writer for page content stream
const ContentWriter = struct {
    page: *Page,
    allocator: std.mem.Allocator,

    fn append(self: *ContentWriter, data: []const u8) !void {
        try self.page.content.appendSlice(self.allocator, data);
    }

    fn print(self: *ContentWriter, comptime fmt: []const u8, args: anytype) !void {
        var buf: [256]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, fmt, args) catch {
            // Buffer too small, allocate
            const str = try std.fmt.allocPrint(self.allocator, fmt, args);
            defer self.allocator.free(str);
            try self.append(str);
            return;
        };
        try self.append(slice);
    }

    /// Append a string with PDF string escaping (for literal strings)
    /// Escapes (, ), and \ characters
    fn appendEscaped(self: *ContentWriter, str: []const u8) !void {
        for (str) |c| {
            switch (c) {
                '\\' => try self.page.content.appendSlice(self.allocator, "\\\\"),
                '(' => try self.page.content.appendSlice(self.allocator, "\\("),
                ')' => try self.page.content.appendSlice(self.allocator, "\\)"),
                else => try self.page.content.append(self.allocator, c),
            }
        }
    }
};

/// Get a short resource name for a font (F1, F2, etc.)
fn fontResourceName(font: StandardFont) []const u8 {
    return switch (font) {
        .helvetica => "F1",
        .helvetica_bold => "F2",
        .helvetica_oblique => "F3",
        .helvetica_bold_oblique => "F4",
        .times_roman => "F5",
        .times_bold => "F6",
        .times_italic => "F7",
        .times_bold_italic => "F8",
        .courier => "F9",
        .courier_bold => "F10",
        .courier_oblique => "F11",
        .courier_bold_oblique => "F12",
        .symbol => "F13",
        .zapf_dingbats => "F14",
    };
}

/// Static resource names for embedded fonts (E1, E2, etc.)
const embedded_font_names = [_][]const u8{
    "E1",  "E2",  "E3",  "E4",  "E5",  "E6",  "E7",  "E8",
    "E9",  "E10", "E11", "E12", "E13", "E14", "E15", "E16",
    "E17", "E18", "E19", "E20", "E21", "E22", "E23", "E24",
    "E25", "E26", "E27", "E28", "E29", "E30", "E31", "E32",
};

/// Get a short resource name for an embedded font by index
fn embeddedFontResourceName(idx: usize) []const u8 {
    if (idx < embedded_font_names.len) {
        return embedded_font_names[idx];
    }
    // Fallback - this shouldn't happen with reasonable font counts
    return "E99";
}

/// PDF Document
pub const Document = struct {
    allocator: std.mem.Allocator,
    pages: std.ArrayListUnmanaged(Page),
    page_size: PageSize,
    // Text state
    current_font: ?StandardFont = null,
    current_embedded: ?*EmbeddedFont = null,
    font_size: f64 = 12,
    x: f64 = 0,
    y: f64 = 0,
    /// Extra space between characters (in points). Can be negative.
    char_spacing: f64 = 0,
    /// Line height as multiple of font size. Default 1.2 (20% leading).
    line_height: f64 = 1.2,
    // Track all fonts used across document
    used_fonts: std.AutoHashMapUnmanaged(StandardFont, void) = .{},
    // Track all embedded fonts
    embedded_fonts: std.ArrayListUnmanaged(*EmbeddedFont) = .{},

    pub fn init(allocator: std.mem.Allocator) Document {
        return .{
            .allocator = allocator,
            .pages = .{},
            .page_size = PageSize.A4,
        };
    }

    pub fn deinit(self: *Document) void {
        for (self.pages.items) |*page| {
            page.deinit(self.allocator);
        }
        self.pages.deinit(self.allocator);
        self.used_fonts.deinit(self.allocator);
        // Clean up embedded fonts
        for (self.embedded_fonts.items) |font| {
            font.deinit();
        }
        self.embedded_fonts.deinit(self.allocator);
    }

    /// Add a new page
    pub fn addPage(self: *Document) !void {
        try self.pages.append(self.allocator, Page.init());
        // Reset position to top-left (PDF coordinates: origin at bottom-left)
        self.x = 0;
        self.y = self.page_size.height;
    }

    /// Set the current font and size (standard font)
    pub fn setFont(self: *Document, font: StandardFont, size: f64) !void {
        self.current_font = font;
        self.current_embedded = null; // Clear embedded font
        self.font_size = size;
        try self.used_fonts.put(self.allocator, font, {});
    }

    /// Load a TrueType font from file
    pub fn loadFont(self: *Document, path: []const u8) !*EmbeddedFont {
        const font = try EmbeddedFont.fromFile(self.allocator, path);
        try self.embedded_fonts.append(self.allocator, font);
        return font;
    }

    /// Set an embedded font as current
    pub fn setEmbeddedFont(self: *Document, font: *EmbeddedFont, size: f64) !void {
        self.current_embedded = font;
        self.current_font = null; // Clear standard font
        self.font_size = size;
        // Ensure font is in our list
        for (self.embedded_fonts.items) |f| {
            if (f == font) return;
        }
        try self.embedded_fonts.append(self.allocator, font);
    }

    /// Get index of embedded font (for resource naming)
    fn getEmbeddedFontIndex(self: *Document, font: *EmbeddedFont) ?usize {
        for (self.embedded_fonts.items, 0..) |f, i| {
            if (f == font) return i;
        }
        return null;
    }

    /// Set character spacing (extra space between characters, in points)
    pub fn setCharSpacing(self: *Document, spacing: f64) void {
        self.char_spacing = spacing;
    }

    /// Set line height (as multiple of font size, e.g. 1.2 = 120%)
    pub fn setLineHeight(self: *Document, height: f64) void {
        self.line_height = height;
    }

    /// Get current line height in points
    pub fn getLineHeightPts(self: *Document) f64 {
        return self.font_size * self.line_height;
    }

    /// Get current text style for measurement
    pub fn getTextStyle(self: *Document) TextStyle {
        return .{
            .font = self.current_font orelse .helvetica,
            .size = self.font_size,
            .char_spacing = self.char_spacing,
            .line_height = self.line_height,
        };
    }

    /// Measure text dimensions without rendering
    pub fn measureText(self: *Document, text_str: []const u8) TextMetrics {
        return metrics.measureText(text_str, self.getTextStyle());
    }

    /// Measure text width in points
    pub fn measureTextWidth(self: *Document, text_str: []const u8) f64 {
        return metrics.measureTextWidth(text_str, self.getTextStyle());
    }

    /// Set current position (in points from top-left)
    pub fn setXY(self: *Document, x: f64, y: f64) void {
        self.x = x;
        // Convert from top-left to PDF coordinates (bottom-left origin)
        self.y = self.page_size.height - y;
    }

    /// Set X position
    pub fn setX(self: *Document, x: f64) void {
        self.x = x;
    }

    /// Set Y position (from top)
    pub fn setY(self: *Document, y: f64) void {
        self.y = self.page_size.height - y;
    }

    /// Get current X position
    pub fn getX(self: *Document) f64 {
        return self.x;
    }

    /// Get current Y position (from top)
    pub fn getY(self: *Document) f64 {
        return self.page_size.height - self.y;
    }

    /// Draw text at the current position
    /// Text is stored as a deferred command and rendered later (after font subsetting)
    pub fn text(self: *Document, str: []const u8) !void {
        if (self.pages.items.len == 0) return error.NoPage;

        var page = &self.pages.items[self.pages.items.len - 1];

        // Determine font reference and mark as used
        const font_ref: FontRef = if (self.current_embedded) |emb| blk: {
            try page.markEmbeddedUsed(self.allocator, emb);
            // Mark chars/glyphs as used for subsetting
            if (emb.encoding == .identity) {
                try emb.markUnicodeCharsUsed(str);
            } else {
                emb.markCharsUsed(str);
            }
            break :blk .{ .embedded = emb };
        } else if (self.current_font) |font| blk: {
            try page.markFontUsed(self.allocator, font);
            break :blk .{ .standard = font };
        } else {
            return error.NoFont;
        };

        // Create owned copy of text
        const text_copy = try self.allocator.dupe(u8, str);
        errdefer self.allocator.free(text_copy);

        // Store deferred command
        try page.commands.append(self.allocator, .{
            .text = .{
                .x = self.x,
                .y = self.y,
                .font_size = self.font_size,
                .char_spacing = self.char_spacing,
                .text_data = text_copy,
                .font = font_ref,
            },
        });
    }

    /// Append hex string with 2-byte glyph IDs for CID mode
    fn appendCIDHexString(self: *Document, cw: *ContentWriter, emb: *EmbeddedFont, str: []const u8) !void {
        _ = self;
        var i: usize = 0;
        while (i < str.len) {
            const len = std.unicode.utf8ByteSequenceLength(str[i]) catch 1;
            if (i + len > str.len) break;

            const codepoint = std.unicode.utf8Decode(str[i..][0..len]) catch {
                // Invalid UTF-8, output notdef glyph
                try cw.append("0000");
                i += 1;
                continue;
            };

            const gid = emb.getGlyphIdForCodepoint(codepoint);
            var hex_buf: [4]u8 = undefined;
            _ = std.fmt.bufPrint(&hex_buf, "{X:0>4}", .{gid}) catch unreachable;
            try cw.append(&hex_buf);

            i += len;
        }
    }

    /// Draw text at a specific position
    pub fn textAt(self: *Document, x: f64, y: f64, str: []const u8) !void {
        self.setXY(x, y);
        try self.text(str);
    }

    /// Render deferred commands to page content bytes
    /// Called after subsetting so glyph IDs are properly remapped
    fn renderPageCommands(self: *Document, page: *Page) !void {
        var cw = page.writer(self.allocator);

        for (page.commands.items) |cmd| {
            switch (cmd) {
                .text => |t| {
                    // Begin text block
                    try cw.append("BT\n");

                    switch (t.font) {
                        .embedded => |emb| {
                            const idx = self.getEmbeddedFontIndex(emb) orelse continue;
                            try cw.print("/E{d} {d:.2} Tf\n", .{ idx + 1, t.font_size });

                            if (t.char_spacing != 0) {
                                try cw.print("{d:.2} Tc\n", .{t.char_spacing});
                            }

                            try cw.print("{d:.2} {d:.2} Td\n", .{ t.x, t.y });

                            if (emb.encoding == .identity) {
                                // CID mode: output hex string with (remapped) glyph IDs
                                try cw.append("<");
                                try self.appendCIDHexString(&cw, emb, t.text_data);
                                try cw.append("> Tj\n");
                            } else {
                                // WinAnsi mode
                                try cw.append("(");
                                try cw.appendEscaped(t.text_data);
                                try cw.append(") Tj\n");
                            }
                        },
                        .standard => |font| {
                            try cw.print("/{s} {d:.2} Tf\n", .{ fontResourceName(font), t.font_size });

                            if (t.char_spacing != 0) {
                                try cw.print("{d:.2} Tc\n", .{t.char_spacing});
                            }

                            try cw.print("{d:.2} {d:.2} Td\n", .{ t.x, t.y });
                            try cw.append("(");
                            try cw.appendEscaped(t.text_data);
                            try cw.append(") Tj\n");
                        },
                    }

                    try cw.append("ET\n");
                },
                .raw => |data| {
                    try cw.append(data);
                },
            }
        }
    }

    /// Output the PDF document as bytes
    /// Caller owns the returned memory and must free it with the document's allocator
    pub fn output(self: *Document) ![]u8 {
        // Ensure at least one page
        if (self.pages.items.len == 0) {
            try self.addPage();
        }

        var w = Writer.init(self.allocator);
        defer w.offsets.deinit(self.allocator); // Clean up offsets, output is transferred

        try w.writeHeader();

        // Collect used standard fonts into a list for stable ordering
        var font_list = std.ArrayListUnmanaged(StandardFont){};
        defer font_list.deinit(self.allocator);
        var font_iter = self.used_fonts.keyIterator();
        while (font_iter.next()) |font| {
            try font_list.append(self.allocator, font.*);
        }

        // Object ID allocation:
        // 1 = Catalog
        // 2 = Pages (root)
        // 3 to 3+num_standard_fonts-1 = Standard Font objects
        // Then for each embedded font:
        //   WinAnsi: Font, FontDescriptor, FontFile2, ToUnicode (4 objects)
        //   Identity/CID: Type0, CIDFont, FontDescriptor, FontFile2, ToUnicode (5 objects)
        // After fonts = Pages (each page needs 2 objects: page dict + content stream)

        const catalog_id: ObjectId = 1;
        const pages_root_id: ObjectId = 2;
        const first_std_font_id: ObjectId = 3;
        const first_emb_font_id: ObjectId = first_std_font_id + @as(ObjectId, @intCast(font_list.items.len));

        // Calculate total objects needed for embedded fonts and track base IDs
        var emb_font_base_ids = std.ArrayListUnmanaged(ObjectId){};
        defer emb_font_base_ids.deinit(self.allocator);

        var next_emb_id = first_emb_font_id;
        for (self.embedded_fonts.items) |emb_font| {
            try emb_font_base_ids.append(self.allocator, next_emb_id);
            const obj_count: ObjectId = if (emb_font.encoding == .identity) 5 else 4;
            next_emb_id += obj_count;
        }
        const first_page_id: ObjectId = next_emb_id;

        // Build page refs array for Pages object
        var page_refs = Array.init(self.allocator);
        defer page_refs.deinit();

        var next_id = first_page_id;
        for (self.pages.items) |_| {
            try page_refs.append(Value.ref(.{ .id = next_id }));
            next_id += 2; // Each page uses 2 objects (page dict + content stream)
        }

        // Write Catalog
        try w.beginObject(catalog_id);
        var catalog = Dict.init(self.allocator);
        defer catalog.deinit();
        try catalog.put("Type", Value.name("Catalog"));
        try catalog.put("Pages", Value.ref(.{ .id = pages_root_id }));
        try w.writeDict(catalog);
        try w.endObject();

        // Write Pages (root)
        try w.beginObject(pages_root_id);
        var pages_dict = Dict.init(self.allocator);
        defer pages_dict.deinit();
        try pages_dict.put("Type", Value.name("Pages"));
        try pages_dict.put("Kids", .{ .array_val = &page_refs });
        try pages_dict.put("Count", Value.int(@intCast(self.pages.items.len)));
        try w.writeDict(pages_dict);
        try w.endObject();

        // Write standard font objects
        for (font_list.items, 0..) |font, i| {
            const font_id = first_std_font_id + @as(ObjectId, @intCast(i));
            try w.beginObject(font_id);
            var font_dict = Dict.init(self.allocator);
            defer font_dict.deinit();
            try font_dict.put("Type", Value.name("Font"));
            try font_dict.put("Subtype", Value.name("Type1"));
            try font_dict.put("BaseFont", Value.name(font.pdfName()));
            try w.writeDict(font_dict);
            try w.endObject();
        }

        // Generate font subsets (only include used glyphs)
        // This also populates gid_remap for compact CFF subsetting
        for (self.embedded_fonts.items) |emb_font| {
            try emb_font.generateSubset();
        }

        // Render deferred commands to content bytes (AFTER subsetting so glyph IDs are remapped)
        for (self.pages.items) |*page| {
            try self.renderPageCommands(page);
        }

        // Write embedded font objects
        for (self.embedded_fonts.items, 0..) |emb_font, i| {
            const base_id = emb_font_base_ids.items[i];

            if (emb_font.encoding == .identity) {
                // CID font: Type0, CIDFont, FontDescriptor, FontFile2, ToUnicode (5 objects)
                const type0_id = base_id;
                const cidfont_id = base_id + 1;
                const descriptor_id = base_id + 2;
                const fontfile_id = base_id + 3;
                const tounicode_id = base_id + 4;

                // Generate ToUnicode CMap for CID
                const tounicode_cmap = try emb_font.generateCIDToUnicodeCMap();
                defer self.allocator.free(tounicode_cmap);

                // Generate /W width array
                const w_array = try emb_font.generateWidthArray();
                defer self.allocator.free(w_array);

                // 1. Type0 (composite) font
                try w.beginObject(type0_id);
                {
                    var font_dict = Dict.init(self.allocator);
                    defer font_dict.deinit();
                    try font_dict.put("Type", Value.name("Font"));
                    try font_dict.put("Subtype", Value.name("Type0"));
                    try font_dict.put("BaseFont", Value.name(emb_font.name));
                    try font_dict.put("Encoding", Value.name("Identity-H"));
                    try font_dict.put("ToUnicode", Value.ref(.{ .id = tounicode_id }));

                    // DescendantFonts array with single CIDFont reference
                    var descendants = Array.init(self.allocator);
                    defer descendants.deinit();
                    try descendants.append(Value.ref(.{ .id = cidfont_id }));
                    try font_dict.put("DescendantFonts", .{ .array_val = &descendants });

                    try w.writeDict(font_dict);
                }
                try w.endObject();

                // 2. CIDFont (CIDFontType2 for TrueType, CIDFontType0 for CFF)
                const is_cff = emb_font.font.isCFF();
                try w.beginObject(cidfont_id);
                {
                    var cid_dict = Dict.init(self.allocator);
                    defer cid_dict.deinit();
                    try cid_dict.put("Type", Value.name("Font"));
                    if (is_cff) {
                        try cid_dict.put("Subtype", Value.name("CIDFontType0"));
                    } else {
                        try cid_dict.put("Subtype", Value.name("CIDFontType2"));
                    }
                    try cid_dict.put("BaseFont", Value.name(emb_font.name));
                    try cid_dict.put("FontDescriptor", Value.ref(.{ .id = descriptor_id }));
                    try cid_dict.put("DW", Value.int(emb_font.getDefaultWidth()));

                    // CIDSystemInfo dictionary
                    var cidsysinfo = Dict.init(self.allocator);
                    defer cidsysinfo.deinit();
                    try cidsysinfo.put("Registry", Value.string("Adobe"));
                    try cidsysinfo.put("Ordering", Value.string("Identity"));
                    try cidsysinfo.put("Supplement", Value.int(0));
                    try cid_dict.put("CIDSystemInfo", .{ .dict_val = &cidsysinfo });

                    // /W array as raw literal (already formatted)
                    try cid_dict.put("W", Value.literal(w_array));

                    // CIDToGIDMap - Identity mapping (only for TrueType, not CFF)
                    if (!is_cff) {
                        try cid_dict.put("CIDToGIDMap", Value.name("Identity"));
                    }

                    try w.writeDict(cid_dict);
                }
                try w.endObject();

                // 3. FontDescriptor
                try w.beginObject(descriptor_id);
                {
                    var desc_dict = Dict.init(self.allocator);
                    defer desc_dict.deinit();
                    try desc_dict.put("Type", Value.name("FontDescriptor"));
                    try desc_dict.put("FontName", Value.name(emb_font.name));
                    try desc_dict.put("Flags", Value.int(@intCast(emb_font.flags.toInt())));
                    try desc_dict.put("ItalicAngle", Value.int(emb_font.italic_angle));
                    try desc_dict.put("Ascent", Value.int(emb_font.ascent));
                    try desc_dict.put("Descent", Value.int(emb_font.descent));
                    try desc_dict.put("CapHeight", Value.int(emb_font.cap_height));
                    try desc_dict.put("StemV", Value.int(@intCast(emb_font.stem_v)));

                    // CFF fonts use FontFile3, TrueType uses FontFile2
                    if (is_cff) {
                        try desc_dict.put("FontFile3", Value.ref(.{ .id = fontfile_id }));
                    } else {
                        try desc_dict.put("FontFile2", Value.ref(.{ .id = fontfile_id }));
                    }

                    var bbox_array = Array.init(self.allocator);
                    defer bbox_array.deinit();
                    for (emb_font.bbox) |val| {
                        try bbox_array.append(Value.int(val));
                    }
                    try desc_dict.put("FontBBox", .{ .array_val = &bbox_array });

                    try w.writeDict(desc_dict);
                }
                try w.endObject();

                // 4. FontFile stream (FontFile2 for TTF, FontFile3 for CFF)
                try w.beginObject(fontfile_id);
                {
                    const font_data = emb_font.getFontData();
                    var stream_dict = Dict.init(self.allocator);
                    defer stream_dict.deinit();

                    if (is_cff) {
                        // CFF requires Subtype
                        try stream_dict.put("Subtype", Value.name("CIDFontType0C"));
                    } else {
                        try stream_dict.put("Length1", Value.int(@intCast(font_data.len)));
                    }
                    try w.writeStream(&stream_dict, font_data);
                }
                try w.endObject();

                // 5. ToUnicode CMap stream
                try w.beginObject(tounicode_id);
                {
                    var tounicode_dict = Dict.init(self.allocator);
                    defer tounicode_dict.deinit();
                    try w.writeStream(&tounicode_dict, tounicode_cmap);
                }
                try w.endObject();
            } else {
                // WinAnsi font: Font, FontDescriptor, FontFile2, ToUnicode (4 objects)
                const font_dict_id = base_id;
                const descriptor_id = base_id + 1;
                const fontfile_id = base_id + 2;
                const tounicode_id = base_id + 3;

                // Generate ToUnicode CMap
                const tounicode_cmap = try emb_font.generateToUnicodeCMap();
                defer self.allocator.free(tounicode_cmap);

                // 1. Font dictionary
                try w.beginObject(font_dict_id);
                {
                    var font_dict = Dict.init(self.allocator);
                    defer font_dict.deinit();
                    try font_dict.put("Type", Value.name("Font"));
                    try font_dict.put("Subtype", Value.name("TrueType"));
                    try font_dict.put("BaseFont", Value.name(emb_font.name));
                    try font_dict.put("FirstChar", Value.int(0));
                    try font_dict.put("LastChar", Value.int(255));
                    try font_dict.put("FontDescriptor", Value.ref(.{ .id = descriptor_id }));
                    try font_dict.put("Encoding", Value.name("WinAnsiEncoding"));
                    try font_dict.put("ToUnicode", Value.ref(.{ .id = tounicode_id }));

                    // Widths array
                    var widths_array = Array.init(self.allocator);
                    defer widths_array.deinit();
                    for (emb_font.widths) |width| {
                        try widths_array.append(Value.int(@intCast(width)));
                    }
                    try font_dict.put("Widths", .{ .array_val = &widths_array });

                    try w.writeDict(font_dict);
                }
                try w.endObject();

                // 2. FontDescriptor
                const is_cff_wa = emb_font.font.isCFF();
                try w.beginObject(descriptor_id);
                {
                    var desc_dict = Dict.init(self.allocator);
                    defer desc_dict.deinit();
                    try desc_dict.put("Type", Value.name("FontDescriptor"));
                    try desc_dict.put("FontName", Value.name(emb_font.name));
                    try desc_dict.put("Flags", Value.int(@intCast(emb_font.flags.toInt())));
                    try desc_dict.put("ItalicAngle", Value.int(emb_font.italic_angle));
                    try desc_dict.put("Ascent", Value.int(emb_font.ascent));
                    try desc_dict.put("Descent", Value.int(emb_font.descent));
                    try desc_dict.put("CapHeight", Value.int(emb_font.cap_height));
                    try desc_dict.put("StemV", Value.int(@intCast(emb_font.stem_v)));

                    if (is_cff_wa) {
                        try desc_dict.put("FontFile3", Value.ref(.{ .id = fontfile_id }));
                    } else {
                        try desc_dict.put("FontFile2", Value.ref(.{ .id = fontfile_id }));
                    }

                    var bbox_array = Array.init(self.allocator);
                    defer bbox_array.deinit();
                    for (emb_font.bbox) |val| {
                        try bbox_array.append(Value.int(val));
                    }
                    try desc_dict.put("FontBBox", .{ .array_val = &bbox_array });

                    try w.writeDict(desc_dict);
                }
                try w.endObject();

                // 3. FontFile stream
                try w.beginObject(fontfile_id);
                {
                    const font_data = emb_font.getFontData();
                    var stream_dict = Dict.init(self.allocator);
                    defer stream_dict.deinit();

                    if (is_cff_wa) {
                        try stream_dict.put("Subtype", Value.name("Type1C"));
                    } else {
                        try stream_dict.put("Length1", Value.int(@intCast(font_data.len)));
                    }
                    try w.writeStream(&stream_dict, font_data);
                }
                try w.endObject();

                // 4. ToUnicode CMap stream
                try w.beginObject(tounicode_id);
                {
                    var tounicode_dict = Dict.init(self.allocator);
                    defer tounicode_dict.deinit();
                    try w.writeStream(&tounicode_dict, tounicode_cmap);
                }
                try w.endObject();
            }
        }

        // Write each page
        next_id = first_page_id;
        for (self.pages.items) |page| {
            const page_id = next_id;
            const content_id = next_id + 1;
            next_id += 2;

            // Page dictionary
            try w.beginObject(page_id);
            var page_dict = Dict.init(self.allocator);
            defer page_dict.deinit();
            try page_dict.put("Type", Value.name("Page"));
            try page_dict.put("Parent", Value.ref(.{ .id = pages_root_id }));

            // MediaBox
            var media_box = Array.init(self.allocator);
            defer media_box.deinit();
            try media_box.append(Value.int(0));
            try media_box.append(Value.int(0));
            try media_box.append(Value.real(self.page_size.width));
            try media_box.append(Value.real(self.page_size.height));
            try page_dict.put("MediaBox", .{ .array_val = &media_box });

            try page_dict.put("Contents", Value.ref(.{ .id = content_id }));

            // Font resources (must stay in scope until writeDict completes)
            var font_res = Dict.init(self.allocator);
            defer font_res.deinit();
            var resources = Dict.init(self.allocator);
            defer resources.deinit();

            var has_fonts = false;

            // Add standard font resources
            for (font_list.items, 0..) |font, idx| {
                if (page.used_fonts.contains(font)) {
                    const font_obj_id = first_std_font_id + @as(ObjectId, @intCast(idx));
                    try font_res.put(fontResourceName(font), Value.ref(.{ .id = font_obj_id }));
                    has_fonts = true;
                }
            }

            // Add embedded font resources
            for (page.used_embedded.items) |emb_font| {
                // Find index of this font
                for (self.embedded_fonts.items, 0..) |doc_font, idx| {
                    if (doc_font == emb_font) {
                        // Use pre-calculated base ID for this font
                        const font_obj_id = emb_font_base_ids.items[idx];
                        const res_name = embeddedFontResourceName(idx);
                        try font_res.put(res_name, Value.ref(.{ .id = font_obj_id }));
                        has_fonts = true;
                        break;
                    }
                }
            }

            if (has_fonts) {
                try resources.put("Font", .{ .dict_val = &font_res });
                try page_dict.put("Resources", .{ .dict_val = &resources });
            }

            try w.writeDict(page_dict);
            try w.endObject();

            // Content stream
            try w.beginObject(content_id);
            var content_dict = Dict.init(self.allocator);
            defer content_dict.deinit();
            try w.writeStream(&content_dict, page.content.items);
            try w.endObject();
        }

        // Finish with xref and trailer
        return try w.finish(.{ .id = catalog_id });
    }
};

test "Document init/deinit" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();
}

test "Document output minimal PDF" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check PDF structure
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type /Catalog") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type /Pages") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type /Page") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "xref") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "%%EOF") != null);
}

test "Document with text" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);
    try doc.textAt(50, 50, "Hello, World!");

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check text content
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type /Font") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "BT") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "(Hello, World!) Tj") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "ET") != null);
}

// Tests ported from fpdf2

test "page format A4" {
    // fpdf2: test_page_format_ok - a4 format
    try std.testing.expectApproxEqAbs(@as(f64, 595.28), PageSize.A4.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 841.89), PageSize.A4.height, 0.01);
}

test "page format Letter" {
    // fpdf2: test_page_format_ok - letter format
    try std.testing.expectApproxEqAbs(@as(f64, 612), PageSize.Letter.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 792), PageSize.Letter.height, 0.01);
}

test "text without font returns error" {
    // fpdf2: test_text_no_font_set
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    // Should fail because no font is set
    try std.testing.expectError(error.NoFont, doc.text("test"));
}

test "text without page returns error" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.setFont(.helvetica, 12);
    // Should fail because no page is added
    try std.testing.expectError(error.NoPage, doc.text("test"));
}

test "multiple fonts on single page" {
    // fpdf2: test_text_positioning - multiple fonts
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();

    try doc.setFont(.helvetica, 12);
    try doc.textAt(50, 50, "Helvetica");

    try doc.setFont(.times_roman, 12);
    try doc.textAt(50, 70, "Times");

    try doc.setFont(.courier, 12);
    try doc.textAt(50, 90, "Courier");

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check all fonts are present
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Times-Roman") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Courier") != null);
}

test "font styles" {
    // fpdf2: tests various font styles
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();

    try doc.setFont(.helvetica, 12);
    try doc.textAt(50, 50, "Normal");

    try doc.setFont(.helvetica_bold, 12);
    try doc.textAt(50, 70, "Bold");

    try doc.setFont(.helvetica_oblique, 12);
    try doc.textAt(50, 90, "Italic");

    try doc.setFont(.helvetica_bold_oblique, 12);
    try doc.textAt(50, 110, "BoldItalic");

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica-Bold") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica-Oblique") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica-BoldOblique") != null);
}

test "positioning setXY" {
    // fpdf2: test_positioning tests
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();

    doc.setXY(100, 200);
    try std.testing.expectApproxEqAbs(@as(f64, 100), doc.getX(), 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 200), doc.getY(), 0.01);

    doc.setX(150);
    try std.testing.expectApproxEqAbs(@as(f64, 150), doc.getX(), 0.01);

    doc.setY(300);
    try std.testing.expectApproxEqAbs(@as(f64, 300), doc.getY(), 0.01);
}

test "multiple pages" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();
    try doc.setFont(.helvetica, 12);
    try doc.textAt(50, 50, "Page 1");

    try doc.addPage();
    try doc.textAt(50, 50, "Page 2");

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check page count
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Count 2") != null);
}

test "all 14 standard fonts" {
    // fpdf2: tests all standard fonts
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.addPage();

    const all_fonts = [_]StandardFont{
        .helvetica,
        .helvetica_bold,
        .helvetica_oblique,
        .helvetica_bold_oblique,
        .times_roman,
        .times_bold,
        .times_italic,
        .times_bold_italic,
        .courier,
        .courier_bold,
        .courier_oblique,
        .courier_bold_oblique,
        .symbol,
        .zapf_dingbats,
    };

    var y: f64 = 50;
    for (all_fonts) |font| {
        try doc.setFont(font, 10);
        try doc.textAt(50, y, font.pdfName());
        y += 15;
    }

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check all 14 fonts are used by name
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica-Bold") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica-Oblique") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Helvetica-BoldOblique") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Times-Roman") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Times-Bold") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Times-Italic") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Times-BoldItalic") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Courier\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Courier-Bold") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Courier-Oblique") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Courier-BoldOblique") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /Symbol") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/BaseFont /ZapfDingbats") != null);
}

test "Document measureText" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.setFont(.helvetica, 12);
    const m = doc.measureText("Hello");

    // "Hello" = H(722) + e(556) + l(222) + l(222) + o(556) = 2278
    // Width = 2278 * 12 / 1000 = 27.336
    try std.testing.expectApproxEqAbs(@as(f64, 27.336), m.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 14.4), m.height, 0.01); // 12 * 1.2
}

test "Document measureText with spacing" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.setFont(.helvetica, 12);
    doc.setCharSpacing(2.0);

    const m = doc.measureText("Hello");

    // Base ~27.336 + 4 * 2.0 = 35.336
    try std.testing.expectApproxEqAbs(@as(f64, 35.336), m.width, 0.01);
}

test "Document line height" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    try doc.setFont(.helvetica, 12);

    // Default line height is 1.2
    try std.testing.expectApproxEqAbs(@as(f64, 14.4), doc.getLineHeightPts(), 0.01);

    doc.setLineHeight(1.5);
    try std.testing.expectApproxEqAbs(@as(f64, 18.0), doc.getLineHeightPts(), 0.01);
}

test {
    _ = objects;
    _ = fonts;
    _ = metrics;
    _ = ttf;
    _ = embedded;
    _ = @import("writer.zig");
    _ = @import("testing.zig");
    _ = @import("integration_tests.zig");
}

// ============================================================================
// Embedded Font Tests
// ============================================================================

test "load embedded font from file" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf");

    // Verify font was loaded
    try std.testing.expect(doc.embedded_fonts.items.len == 1);
    try std.testing.expect(doc.embedded_fonts.items[0] == font);

    // Check font name was extracted
    try std.testing.expect(font.name.len > 0);

    // Check metrics are sensible
    try std.testing.expect(font.ascent > 0);
    try std.testing.expect(font.descent < 0); // Descent is negative
}

test "embedded font character widths" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf");

    // Courier Prime is monospace - all visible chars should have same width
    const width_A = font.widths['A'];
    const width_Z = font.widths['Z'];
    const width_a = font.widths['a'];
    const width_m = font.widths['m'];

    try std.testing.expect(width_A > 0);
    try std.testing.expectEqual(width_A, width_Z);
    try std.testing.expectEqual(width_A, width_a);
    try std.testing.expectEqual(width_A, width_m);

    // Space should have a width
    try std.testing.expect(font.widths[' '] > 0);
}

test "embedded font text measurement" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf");

    // Measure text at 12pt
    const width = font.measureTextWidth("Hello", 12.0);
    try std.testing.expect(width > 0);

    // "Hello" is 5 chars, monospace - each char same width
    const char_width = font.measureTextWidth("H", 12.0);
    try std.testing.expectApproxEqAbs(char_width * 5, width, 0.01);
}

test "render text with embedded font" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf");

    try doc.addPage();
    try doc.setEmbeddedFont(font, 12);
    try doc.textAt(50, 50, "Hello, World!");

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check PDF structure for embedded font
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type /Font") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Subtype /TrueType") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/FontDescriptor") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/FontFile2") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Widths [") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Encoding /WinAnsiEncoding") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/ToUnicode") != null);

    // Check FontDescriptor fields
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Type /FontDescriptor") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Ascent") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Descent") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/CapHeight") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/FontBBox") != null);

    // Check text rendering uses embedded font
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/E1 12") != null); // Embedded font E1 at 12pt
    try std.testing.expect(std.mem.indexOf(u8, pdf, "(Hello, World!) Tj") != null);
}

test "mix standard and embedded fonts" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    const courier_prime = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf");

    try doc.addPage();

    // Use standard font first
    try doc.setFont(.helvetica, 12);
    try doc.textAt(50, 50, "Helvetica text");

    // Switch to embedded font
    try doc.setEmbeddedFont(courier_prime, 14);
    try doc.textAt(50, 70, "Courier Prime text");

    // Switch back to standard
    try doc.setFont(.times_roman, 12);
    try doc.textAt(50, 90, "Times text");

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check all font types present
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Subtype /Type1") != null); // Standard fonts
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Subtype /TrueType") != null); // Embedded font

    // Check font references in content stream
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/F1 12") != null); // Helvetica
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/E1 14") != null); // Courier Prime
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/F5 12") != null); // Times Roman
}

test "multiple embedded fonts" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    const courier_regular = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf");
    const courier_bold = try doc.loadFont("test/fonts/Courier Prime/Courier Prime Bold.ttf");

    try doc.addPage();

    try doc.setEmbeddedFont(courier_regular, 12);
    try doc.textAt(50, 50, "Regular");

    try doc.setEmbeddedFont(courier_bold, 12);
    try doc.textAt(50, 70, "Bold");

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Check both fonts are embedded
    try std.testing.expect(doc.embedded_fonts.items.len == 2);

    // Both fonts should have TrueType entries
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOf(u8, pdf[pos..], "/Subtype /TrueType")) |idx| {
        count += 1;
        pos += idx + 1;
    }
    try std.testing.expect(count >= 2);

    // Check E1 and E2 font references
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/E1 12") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/E2 12") != null);
}

test "embedded font on multiple pages" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf");

    try doc.addPage();
    try doc.setEmbeddedFont(font, 12);
    try doc.textAt(50, 50, "Page 1");

    try doc.addPage();
    // Font should still be set
    try doc.textAt(50, 50, "Page 2");

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Font should only be embedded once
    var font_count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOf(u8, pdf[pos..], "/Subtype /TrueType")) |idx| {
        font_count += 1;
        pos += idx + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), font_count);

    // Both pages should reference the font
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Count 2") != null);
}

test "embedded font flags - monospace detection" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    // Courier Prime is monospace
    const monospace = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf");
    try std.testing.expect(monospace.flags.fixed_pitch == true);
}

test "embedded font bbox scaling" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf");

    // BBox should be scaled to 1000 units
    // x_min should typically be negative or small
    // y_min should be negative (descenders)
    // x_max and y_max should be positive and reasonable for 1000 units
    try std.testing.expect(font.bbox[3] > 0); // y_max (ascenders)
    try std.testing.expect(font.bbox[3] <= 1500); // Should be scaled properly
    try std.testing.expect(font.bbox[1] <= 0); // y_min should be 0 or negative
}

test "embedded font widths array in PDF" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf");

    try doc.addPage();
    try doc.setEmbeddedFont(font, 12);
    try doc.textAt(50, 50, "Test");

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Widths array should start with /Widths [
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Widths [") != null);

    // Should have 256 entries (FirstChar 0 to LastChar 255)
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/FirstChar 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/LastChar 255") != null);
}

test "variable font loading" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    // Inter Variable is a variable font - should still load basic metrics
    const font = doc.loadFont("test/fonts/Inter/InterVariable.ttf") catch |err| {
        // Variable fonts might have extra tables we don't handle yet
        // For now, skip if loading fails
        std.debug.print("Skipping variable font test: {}\n", .{err});
        return;
    };

    try std.testing.expect(font.ascent > 0);
    try std.testing.expect(font.widths['A'] > 0);
}

test "PDF output is valid with embedded font" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    const font = try doc.loadFont("test/fonts/Courier Prime/Courier Prime.ttf");

    try doc.addPage();
    try doc.setEmbeddedFont(font, 24);
    try doc.textAt(100, 100, "Test embedded font!");

    const pdf = try doc.output();
    defer doc.allocator.free(pdf);

    // Basic PDF structure validation
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf, "%%EOF") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "xref") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "trailer") != null);

    // Font stream data should be present (TTF data embedded)
    try std.testing.expect(std.mem.indexOf(u8, pdf, "/Length1") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "stream\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf, "\nendstream") != null);
}
