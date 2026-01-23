//! Document struct for zpdf - PDF document creation and management.
//!
//! This module contains the core Document type that handles page management,
//! text rendering, font handling, and PDF output generation.

const std = @import("std");

// Module imports
pub const objects = @import("objects.zig");
pub const fonts = @import("fonts.zig");
pub const metrics = @import("metrics.zig");
pub const ttf = @import("ttf.zig");
pub const embedded = @import("embedded.zig");
pub const color = @import("color.zig");
pub const layout = @import("layout.zig");
pub const Writer = @import("writer.zig").Writer;
pub const zlib = @import("zlib.zig");
pub const images = @import("images.zig");
pub const svg = @import("svg.zig");
pub const pathmod = @import("path.zig");
pub const gradient = @import("gradient.zig");
pub const styled_text = @import("styled_text.zig");

const ObjectId = objects.ObjectId;
const Ref = objects.Ref;
const Dict = objects.Dict;
const Array = objects.Array;
const Value = objects.Value;

// Type aliases
pub const StandardFont = fonts.StandardFont;
pub const Font = fonts.Font;
pub const TextMetrics = metrics.TextMetrics;
pub const FontStyle = metrics.FontStyle;
pub const FontMetrics = metrics.FontMetrics;
pub const EmbeddedFont = embedded.EmbeddedFont;
pub const Color = color.Color;
pub const Image = images.Image;
pub const Svg = svg.Svg;
pub const Path = pathmod.Path;
pub const StyledText = styled_text.StyledText;
pub const Span = styled_text.Span;
pub const BreakPoint = styled_text.BreakPoint;
pub const LinearGradient = gradient.LinearGradient;
pub const RadialGradient = gradient.RadialGradient;
pub const ColorStop = gradient.ColorStop;

// Layout types
pub const Border = layout.Border;
pub const Align = layout.Align;
pub const VAlign = layout.VAlign;
pub const LineBreaking = layout.LineBreaking;
pub const TextDecoration = layout.TextDecoration;
pub const TextStyleOptions = layout.TextStyleOptions;
pub const Margins = layout.Margins;
pub const Padding = layout.Padding;
pub const Point = layout.Point;
pub const Rect = layout.Rect;
pub const Region = layout.Region;
pub const Destination = layout.Destination;
pub const Outline = layout.Outline;
pub const PageLabelStyle = layout.PageLabelStyle;
pub const PageLabel = layout.PageLabel;
pub const WriteResult = layout.WriteResult;
pub const WrappedTextMetrics = layout.WrappedTextMetrics;
pub const WriteOptions = layout.WriteOptions;
pub const ParagraphOptions = layout.ParagraphOptions;
pub const MeasureOptions = layout.MeasureOptions;
pub const PageSize = layout.PageSize;

// Graphics types
pub const DrawStyle = layout.DrawStyle;
pub const LineCap = layout.LineCap;
pub const LineJoin = layout.LineJoin;
pub const DashPattern = layout.DashPattern;
pub const DrawStyleOptions = layout.DrawStyleOptions;

pub const opentype = embedded.opentype;

// ============================================================================
// Document Metadata
// ============================================================================

/// PDF document metadata (Info dictionary fields).
/// All fields are optional - only non-null values are written to the PDF.
pub const DocumentMetadata = struct {
    /// Document title.
    title: ?[]const u8 = null,
    /// Document author.
    author: ?[]const u8 = null,
    /// Subject/description of the document.
    subject: ?[]const u8 = null,
    /// Keywords associated with the document (comma-separated).
    keywords: ?[]const u8 = null,
    /// Application that created the original document content.
    creator: ?[]const u8 = null,
    /// Application that produced the PDF (defaults to "zpdf").
    producer: ?[]const u8 = "zpdf",
    /// Creation date in PDF format (D:YYYYMMDDHHmmSS).
    /// If null, current time is used automatically.
    creation_date: ?[]const u8 = null,
    /// Modification date in PDF format (D:YYYYMMDDHHmmSS).
    /// If null, same as creation_date.
    mod_date: ?[]const u8 = null,

    /// Check if any metadata field is set.
    pub fn hasAnyField(self: DocumentMetadata) bool {
        return self.title != null or
            self.author != null or
            self.subject != null or
            self.keywords != null or
            self.creator != null or
            self.producer != null or
            self.creation_date != null or
            self.mod_date != null;
    }
};

// ============================================================================
// Internal Types
// ============================================================================

// Fast hex conversion lookup table
const hex_chars = "0123456789ABCDEF";

/// Fast conversion of u16 to 4-character hex string
fn writeHex4(buf: *[4]u8, val: u16) void {
    buf[0] = hex_chars[(val >> 12) & 0xF];
    buf[1] = hex_chars[(val >> 8) & 0xF];
    buf[2] = hex_chars[(val >> 4) & 0xF];
    buf[3] = hex_chars[val & 0xF];
}

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
    word_spacing: f64, // Extra space added between words for justification
    text_data: []const u8, // Owned copy of text
    font: FontRef,
    /// Text color
    text_color: Color,
    /// Cached glyph IDs for CID fonts (avoids duplicate OpenType shaping)
    cached_glyphs: ?[]const u16 = null,
    /// Text width (for decoration drawing)
    text_width: f64 = 0,
    /// Draw underline
    underline: bool = false,
    /// Draw strikethrough
    strikethrough: bool = false,
};

/// Content command for deferred rendering (enables glyph ID remapping)
const ContentCommand = union(enum) {
    /// Text command with all rendering parameters
    text: TextCommand,
    /// Raw content (for non-text operations that don't need deferred processing)
    raw: []const u8, // Owned copy
};

/// Entry in the page labels number tree
const PageLabelEntry = struct {
    page_index: usize,
    label: PageLabel,
};

/// Link annotation for internal or external links
const LinkAnnotation = union(enum) {
    /// Internal link to page position
    internal: struct {
        rect: Rect,
        dest: Destination,
    },
    /// External link to URL
    external: struct {
        rect: Rect,
        url: []const u8, // Owned by page arena
    },
};

/// Internal page representation
const Page = struct {
    content: std.ArrayListUnmanaged(u8), // Legacy: direct content bytes
    commands: std.ArrayListUnmanaged(ContentCommand), // Deferred commands
    used_fonts: std.AutoHashMapUnmanaged(StandardFont, void),
    used_embedded: std.ArrayListUnmanaged(*EmbeddedFont),
    used_images: std.ArrayListUnmanaged(*Image),
    used_svgs: std.ArrayListUnmanaged(*Svg),
    used_gradients: std.AutoHashMapUnmanaged(usize, void),
    annotations: std.ArrayListUnmanaged(LinkAnnotation), // Link annotations
    size: PageSize, // Page dimensions

    // Arena allocator for page-local allocations (text_data, cached_glyphs, etc.)
    // All page allocations freed at once in deinit - no individual free() calls
    arena: std.heap.ArenaAllocator,

    fn init(backing_allocator: std.mem.Allocator, size: PageSize) Page {
        return .{
            .content = .{},
            .commands = .{},
            .used_fonts = .{},
            .used_embedded = .{},
            .used_images = .{},
            .used_svgs = .{},
            .used_gradients = .{},
            .annotations = .{},
            .size = size,
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
        };
    }

    /// Get the arena allocator for page-local allocations
    fn pageAllocator(self: *Page) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn deinit(self: *Page, backing_allocator: std.mem.Allocator) void {
        // Arena frees all text_data, cached_glyphs, etc. in one operation
        self.arena.deinit();

        // These use the backing allocator, not the arena
        self.commands.deinit(backing_allocator);
        self.content.deinit(backing_allocator);
        self.used_fonts.deinit(backing_allocator);
        self.used_embedded.deinit(backing_allocator);
        self.used_images.deinit(backing_allocator);
        self.used_svgs.deinit(backing_allocator);
        self.used_gradients.deinit(backing_allocator);
        self.annotations.deinit(backing_allocator);
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

    fn markImageUsed(self: *Page, allocator: std.mem.Allocator, image: *Image) !void {
        // Check if already in list
        for (self.used_images.items) |img| {
            if (img == image) return;
        }
        try self.used_images.append(allocator, image);
    }

    fn markSvgUsed(self: *Page, allocator: std.mem.Allocator, s: *Svg) !void {
        // Check if already in list
        for (self.used_svgs.items) |existing| {
            if (existing == s) return;
        }
        try self.used_svgs.append(allocator, s);
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

    pub fn print(self: *ContentWriter, comptime fmt: []const u8, args: anytype) !void {
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

    /// Return std.io.Writer interface for this ContentWriter
    fn writer(self: *ContentWriter) std.io.GenericWriter(*ContentWriter, error{OutOfMemory}, writeBytes) {
        return .{ .context = self };
    }

    fn writeBytes(self: *ContentWriter, bytes: []const u8) error{OutOfMemory}!usize {
        self.page.content.appendSlice(self.allocator, bytes) catch return error.OutOfMemory;
        return bytes.len;
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

// Static image resource names to avoid dangling pointer issues
const image_names = [_][]const u8{
    "Im1",  "Im2",  "Im3",  "Im4",  "Im5",  "Im6",  "Im7",  "Im8",
    "Im9",  "Im10", "Im11", "Im12", "Im13", "Im14", "Im15", "Im16",
    "Im17", "Im18", "Im19", "Im20", "Im21", "Im22", "Im23", "Im24",
    "Im25", "Im26", "Im27", "Im28", "Im29", "Im30", "Im31", "Im32",
};

fn imageResourceName(idx: usize) []const u8 {
    if (idx < image_names.len) {
        return image_names[idx];
    }
    return "Im99";
}

// Static SVG resource names (Form XObjects)
const svg_names = [_][]const u8{
    "Sv1",  "Sv2",  "Sv3",  "Sv4",  "Sv5",  "Sv6",  "Sv7",  "Sv8",
    "Sv9",  "Sv10", "Sv11", "Sv12", "Sv13", "Sv14", "Sv15", "Sv16",
    "Sv17", "Sv18", "Sv19", "Sv20", "Sv21", "Sv22", "Sv23", "Sv24",
    "Sv25", "Sv26", "Sv27", "Sv28", "Sv29", "Sv30", "Sv31", "Sv32",
};

fn svgResourceName(idx: usize) []const u8 {
    if (idx < svg_names.len) {
        return svg_names[idx];
    }
    return "Sv99";
}

// Static ExtGState names for SVG transparency
const extgstate_names = [_][]const u8{
    "GS1",  "GS2",  "GS3",  "GS4",  "GS5",  "GS6",  "GS7",  "GS8",
    "GS9",  "GS10", "GS11", "GS12", "GS13", "GS14", "GS15", "GS16",
    "GS17", "GS18", "GS19", "GS20", "GS21", "GS22", "GS23", "GS24",
    "GS25", "GS26", "GS27", "GS28", "GS29", "GS30", "GS31", "GS32",
};

fn extgstateResourceName(idx: usize) []const u8 {
    if (idx < extgstate_names.len) {
        return extgstate_names[idx];
    }
    return "GS99";
}

// Static shading names for gradients
const shading_names = [_][]const u8{
    "Sh1",  "Sh2",  "Sh3",  "Sh4",  "Sh5",  "Sh6",  "Sh7",  "Sh8",
    "Sh9",  "Sh10", "Sh11", "Sh12", "Sh13", "Sh14", "Sh15", "Sh16",
};

fn shadingResourceName(idx: usize) []const u8 {
    if (idx < shading_names.len) {
        return shading_names[idx];
    }
    return "Sh99";
}

/// Stored gradient definition
pub const GradientDef = union(enum) {
    linear: LinearGradient,
    radial: RadialGradient,
};

// ============================================================================
// Document
// ============================================================================

/// PDF Document
pub const Document = struct {
    allocator: std.mem.Allocator,
    pages: std.ArrayListUnmanaged(Page),
    page_size: PageSize,
    /// Document margins.
    margins: Margins = .{},
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
    /// Text color (default black).
    text_color: Color = Color.black,
    /// Text decoration (underline, strikethrough).
    text_decoration: TextDecoration = .none,
    /// Fill color for shapes (default black).
    fill_color: Color = Color.black,
    /// Stroke/draw color for lines and borders (default black).
    draw_color: Color = Color.black,
    /// Line width for strokes in points (default 0.567pt = 0.2mm, fpdf2 default).
    line_width: f64 = 0.567,
    /// Dash pattern for stroked lines.
    dash_pattern: layout.DashPattern = .{},
    /// Line cap style (fpdf2 default is square/projecting).
    line_cap: layout.LineCap = .square,
    /// Line join style.
    line_join: layout.LineJoin = .miter,
    // Track all fonts used across document
    used_fonts: std.AutoHashMapUnmanaged(StandardFont, void) = .{},
    // Track all embedded fonts
    embedded_fonts: std.ArrayListUnmanaged(*EmbeddedFont) = .{},
    // Track all loaded images
    loaded_images: std.ArrayListUnmanaged(*Image) = .{},
    // Track all loaded SVGs
    loaded_svgs: std.ArrayListUnmanaged(*Svg) = .{},
    // Track gradients used in document
    gradients: std.ArrayListUnmanaged(GradientDef) = .{},
    // Document outline items
    outlines: std.ArrayListUnmanaged(*Outline) = .{},
    // Last top-level outline item (for building sibling chain)
    last_top_level_outline: ?*Outline = null,
    // Page label ranges
    page_labels: std.ArrayListUnmanaged(PageLabelEntry) = .{},
    /// Document metadata (title, author, etc.)
    metadata: DocumentMetadata = .{},

    /// Create a new PDF document.
    pub fn init(allocator: std.mem.Allocator) Document {
        return .{
            .allocator = allocator,
            .pages = .{},
            .page_size = PageSize.A4,
        };
    }

    /// Free all document resources.
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
        // Clean up loaded images
        for (self.loaded_images.items) |image| {
            image.deinit();
            self.allocator.destroy(image);
        }
        self.loaded_images.deinit(self.allocator);
        // Clean up loaded SVGs
        for (self.loaded_svgs.items) |s| {
            s.deinit();
            self.allocator.destroy(s);
        }
        self.loaded_svgs.deinit(self.allocator);
        // Clean up gradients
        self.gradients.deinit(self.allocator);
        // Clean up outline items
        for (self.outlines.items) |outline| {
            self.allocator.destroy(outline);
        }
        self.outlines.deinit(self.allocator);
        // Clean up page labels
        self.page_labels.deinit(self.allocator);
    }

    /// Set document metadata (title, author, subject, etc.).
    /// Only non-null fields are written to the PDF Info dictionary.
    pub fn setMetadata(self: *Document, meta: DocumentMetadata) void {
        self.metadata = meta;
    }

    /// Set the page size for subsequent addPage() calls.
    pub fn setPageSize(self: *Document, size: PageSize) void {
        self.page_size = size;
    }

    /// Add a new page using the current page size (set via setPageSize, default A4).
    pub fn addPage(self: *Document) !void {
        try self.pages.append(self.allocator, Page.init(self.allocator, self.page_size));
        // Reset position to top-left
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

    /// Load an image from file (JPEG or PNG).
    /// Returns a handle that can be used with drawImage().
    pub fn loadImage(self: *Document, path: []const u8) !*Image {
        const image = try Image.fromFile(self.allocator, path);
        try self.loaded_images.append(self.allocator, image);
        return image;
    }

    /// Get index of image (for resource naming)
    fn getImageIndex(self: *Document, image: *Image) ?usize {
        for (self.loaded_images.items, 0..) |img, i| {
            if (img == image) return i;
        }
        return null;
    }

    /// Draw an image at the specified position.
    /// If w or h is 0, the original dimension is used (maintaining aspect ratio if one is specified).
    /// Coordinates are from top-left origin.
    pub fn drawImage(self: *Document, image: *Image, x: f64, y: f64, w: f64, h: f64) !void {
        if (self.pages.items.len == 0) return error.NoPage;

        var page = &self.pages.items[self.pages.items.len - 1];
        const page_height = self.page_size.height;

        // Calculate display dimensions
        var display_w = w;
        var display_h = h;

        if (display_w == 0 and display_h == 0) {
            // Use original dimensions (1 pixel = 1 point)
            display_w = @floatFromInt(image.width);
            display_h = @floatFromInt(image.height);
        } else if (display_w == 0) {
            // Calculate width from height, maintaining aspect ratio
            const aspect = @as(f64, @floatFromInt(image.width)) / @as(f64, @floatFromInt(image.height));
            display_w = display_h * aspect;
        } else if (display_h == 0) {
            // Calculate height from width, maintaining aspect ratio
            const aspect = @as(f64, @floatFromInt(image.height)) / @as(f64, @floatFromInt(image.width));
            display_h = display_w * aspect;
        }

        // Convert from top-left to PDF coordinates (bottom-left origin)
        // y is the top of the image, PDF needs the bottom
        const pdf_y = page_height - y - display_h;

        // Get image resource name
        const img_idx = self.getImageIndex(image) orelse {
            // Image not in document, add it
            try self.loaded_images.append(self.allocator, image);
            return self.drawImage(image, x, y, w, h);
        };

        // Mark image as used on this page
        try page.markImageUsed(self.allocator, image);

        // Generate PDF content: q cm /Im Do Q
        // The cm operator sets a transformation matrix for scaling and positioning
        var buf: [256]u8 = undefined;
        const content = std.fmt.bufPrint(&buf, "q\n{d:.2} 0 0 {d:.2} {d:.2} {d:.2} cm\n/Im{d} Do\nQ\n", .{
            display_w,
            display_h,
            x,
            pdf_y,
            img_idx + 1, // 1-indexed resource names
        }) catch unreachable;

        const raw_copy = try page.pageAllocator().dupe(u8, content);
        try page.commands.append(self.allocator, .{ .raw = raw_copy });
    }

    /// Load an SVG from file.
    /// Returns a handle that can be used with drawSvg().
    pub fn loadSvg(self: *Document, path: []const u8) !*Svg {
        const s = try Svg.fromFile(self.allocator, path);
        try self.loaded_svgs.append(self.allocator, s);
        return s;
    }

    /// Get index of SVG (for resource naming)
    fn getSvgIndex(self: *Document, s: *Svg) ?usize {
        for (self.loaded_svgs.items, 0..) |existing, i| {
            if (existing == s) return i;
        }
        return null;
    }

    /// Draw an SVG at the specified position.
    /// If w or h is 0, the original dimension is used (maintaining aspect ratio if one is specified).
    /// Coordinates are from top-left origin.
    pub fn drawSvg(self: *Document, s: *Svg, x: f64, y: f64, w: f64, h: f64) !void {
        if (self.pages.items.len == 0) return error.NoPage;

        var page = &self.pages.items[self.pages.items.len - 1];
        const page_height = self.page_size.height;

        // Calculate display dimensions
        var display_w = w;
        var display_h = h;

        if (display_w == 0 and display_h == 0) {
            // Use original dimensions
            display_w = s.width;
            display_h = s.height;
        } else if (display_w == 0) {
            // Calculate width from height, maintaining aspect ratio
            const aspect = s.width / s.height;
            display_w = display_h * aspect;
        } else if (display_h == 0) {
            // Calculate height from width, maintaining aspect ratio
            const aspect = s.height / s.width;
            display_h = display_w * aspect;
        }

        // Convert from top-left to PDF coordinates (bottom-left origin)
        const pdf_y = page_height - y - display_h;

        // Get SVG resource name
        const svg_idx = self.getSvgIndex(s) orelse {
            // SVG not in document, add it
            try self.loaded_svgs.append(self.allocator, s);
            return self.drawSvg(s, x, y, w, h);
        };

        // Mark SVG as used on this page
        try page.markSvgUsed(self.allocator, s);

        // Generate PDF content: q cm /SvN Do Q
        // Scale from SVG dimensions to display dimensions
        const scale_x = display_w / s.width;
        const scale_y = display_h / s.height;

        var buf: [256]u8 = undefined;
        const content = std.fmt.bufPrint(&buf, "q\n{d:.4} 0 0 {d:.4} {d:.2} {d:.2} cm\n/{s} Do\nQ\n", .{
            scale_x,
            scale_y,
            x,
            pdf_y,
            svgResourceName(svg_idx),
        }) catch unreachable;

        const raw_copy = try page.pageAllocator().dupe(u8, content);
        try page.commands.append(self.allocator, .{ .raw = raw_copy });
    }

    /// Set character spacing (extra space between characters, in points)
    pub fn setCharSpacing(self: *Document, spacing: f64) void {
        self.char_spacing = spacing;
    }

    /// Set line height (as multiple of font size, e.g. 1.2 = 120%)
    pub fn setLineHeight(self: *Document, height: f64) void {
        self.line_height = height;
    }

    /// Set text color.
    pub fn setTextColor(self: *Document, c: Color) void {
        self.text_color = c;
    }

    /// Set text style (color and decoration).
    pub fn setTextStyle(self: *Document, opts: TextStyleOptions) void {
        self.text_color = opts.color;
        self.text_decoration = opts.decoration;
    }

    /// Set drawing style (stroke/fill colors, line width, cap, join, dash pattern).
    pub fn setDrawStyle(self: *Document, opts: layout.DrawStyleOptions) void {
        self.line_width = opts.line_width;
        self.line_cap = opts.line_cap;
        self.line_join = opts.line_join;
        self.dash_pattern = opts.dash_pattern;
        self.draw_color = opts.stroke_color;
        self.fill_color = opts.fill_color;
    }

    /// Set document margins.
    pub fn setMargins(self: *Document, m: Margins) void {
        self.margins = m;
    }

    /// Returns a region for the current page respecting document margins.
    pub fn getPageRegion(self: *Document) Region {
        return .{
            .x = self.margins.left,
            .y = self.margins.top,
            .width = self.page_size.width - self.margins.left - self.margins.right,
            .height = self.page_size.height - self.margins.top - self.margins.bottom,
        };
    }

    /// Set OpenType feature for all embedded fonts
    /// Example: doc.setFeature(.liga, false) to disable ligatures
    pub fn setFeature(self: *Document, feature: opentype.Feature, enabled: bool) void {
        for (self.embedded_fonts.items) |font| {
            font.setFeature(feature, enabled);
        }
    }

    /// Set OpenType feature for a specific embedded font
    pub fn setFontFeature(self: *Document, font: *EmbeddedFont, feature: opentype.Feature, enabled: bool) void {
        _ = self;
        font.setFeature(feature, enabled);
    }

    /// Get current line height in points
    pub fn getLineHeightPts(self: *Document) f64 {
        return self.font_size * self.line_height;
    }

    /// Get current font style for measurement (standard fonts only).
    pub fn getFontStyle(self: *Document) FontStyle {
        return .{
            .font = self.current_font orelse .helvetica,
            .size = self.font_size,
            .char_spacing = self.char_spacing,
            .line_height = self.line_height,
        };
    }

    /// Get font metrics for the current font, scaled to the current font size.
    /// Returns metrics in points at the current font size.
    pub fn getFontMetrics(self: *Document) FontMetrics {
        const size = self.font_size;

        if (self.current_embedded) |emb| {
            // Embedded font: use actual metrics from the font
            // Metrics are stored in 1000 units, scale to points
            const scale = size / 1000.0;
            return .{
                .ascender = @as(f64, @floatFromInt(emb.ascent)) * scale,
                .descender = @as(f64, @floatFromInt(emb.descent)) * scale,
                .cap_height = @as(f64, @floatFromInt(emb.cap_height)) * scale,
                // x_height estimated as 70% of cap_height if not available
                .x_height = @as(f64, @floatFromInt(emb.cap_height)) * scale * 0.7,
                .font_size = size,
                .units_per_em = emb.font.head.?.units_per_em,
            };
        } else if (self.current_font) |font| {
            // Standard font: use predefined metrics
            const m = metrics.getStandardFontMetrics(font);
            const scale = size / 1000.0;
            return .{
                .ascender = @as(f64, @floatFromInt(m.ascender)) * scale,
                .descender = @as(f64, @floatFromInt(m.descender)) * scale,
                .cap_height = @as(f64, @floatFromInt(m.cap_height)) * scale,
                .x_height = @as(f64, @floatFromInt(m.x_height)) * scale,
                .font_size = size,
                .units_per_em = 1000, // Standard fonts use 1000 units per em
            };
        } else {
            // No font set, return Helvetica defaults
            const m = metrics.getStandardFontMetrics(.helvetica);
            const scale = size / 1000.0;
            return .{
                .ascender = @as(f64, @floatFromInt(m.ascender)) * scale,
                .descender = @as(f64, @floatFromInt(m.descender)) * scale,
                .cap_height = @as(f64, @floatFromInt(m.cap_height)) * scale,
                .x_height = @as(f64, @floatFromInt(m.x_height)) * scale,
                .font_size = size,
                .units_per_em = 1000,
            };
        }
    }

    /// Measure text dimensions without rendering
    pub fn measureText(self: *Document, text_str: []const u8) TextMetrics {
        return metrics.measureText(text_str, self.getFontStyle());
    }

    /// Measure text width in points
    pub fn measureTextWidth(self: *Document, text_str: []const u8) f64 {
        return metrics.measureTextWidth(text_str, self.getFontStyle());
    }

    /// Set cursor position (in points from top-left).
    pub fn setPosition(self: *Document, pos: Point) void {
        self.x = pos.x;
        self.y = self.page_size.height - pos.y;
    }

    /// Get cursor position (in points from top-left).
    pub fn getPosition(self: *Document) Point {
        return .{
            .x = self.x,
            .y = self.page_size.height - self.y,
        };
    }

    /// Get current page number (1-based).
    /// Returns 0 if no pages have been added.
    pub fn pageNo(self: *Document) usize {
        return self.pages.items.len;
    }

    /// Get a destination for the current cursor position.
    /// Used as target for internal links (e.g., TOC entries).
    /// Returns null if no pages have been added.
    pub fn currentDestination(self: *const Document) ?Destination {
        if (self.pages.items.len == 0) return null;
        // Convert from internal PDF coords (bottom-up) to user coords (top-down)
        return .{ .page_index = self.pages.items.len - 1, .y = self.page_size.height - self.y };
    }

    /// Add an internal link (clickable area that jumps to another page position).
    /// The rect specifies the clickable area on the current page.
    /// The dest specifies the target page and y position.
    pub fn addLink(self: *Document, rect: Rect, dest: Destination) !void {
        if (self.pages.items.len == 0) return error.NoPage;
        var page = &self.pages.items[self.pages.items.len - 1];
        try page.annotations.append(self.allocator, .{
            .internal = .{ .rect = rect, .dest = dest },
        });
    }

    /// Add an external link (clickable area that opens a URL).
    /// The rect specifies the clickable area on the current page.
    /// The url is copied to page-local storage.
    pub fn addExternalLink(self: *Document, rect: Rect, url: []const u8) !void {
        if (self.pages.items.len == 0) return error.NoPage;
        var page = &self.pages.items[self.pages.items.len - 1];
        const page_alloc = page.pageAllocator();
        // Copy URL to page arena (freed when page is destroyed)
        const url_copy = try page_alloc.dupe(u8, url);
        try page.annotations.append(self.allocator, .{
            .external = .{ .rect = rect, .url = url_copy },
        });
    }

    /// Adds an outline item to the document (shown in PDF viewer's table of contents).
    /// Returns a pointer to the outline item, which can be used as a parent for nested items.
    pub fn addOutlineItem(self: *Document, title: []const u8, dest: Destination, parent: ?*Outline) !*Outline {
        const outline = try self.allocator.create(Outline);
        outline.* = .{
            .title = title,
            .dest = dest,
            .parent = parent,
        };

        // Update sibling chain
        if (parent) |p| {
            // Child: link to parent's children
            if (p.last_child) |last| {
                last.next = outline;
                outline.prev = last;
            } else {
                p.first_child = outline;
            }
            p.last_child = outline;
            p.count += 1;
        } else {
            // Top-level: link to other top-level items
            if (self.last_top_level_outline) |last| {
                last.next = outline;
                outline.prev = last;
            }
            self.last_top_level_outline = outline;
        }

        try self.outlines.append(self.allocator, outline);
        return outline;
    }

    /// Sets a page label range starting at the specified page index.
    /// Labels apply from page_index until the next setPageLabel call or end of document.
    pub fn setPageLabel(self: *Document, page_index: usize, label: PageLabel) !void {
        try self.page_labels.append(self.allocator, .{
            .page_index = page_index,
            .label = label,
        });
    }

    /// Internal: Writes text at the current cursor position.
    fn writeAtCursor(self: *Document, str: []const u8) !void {
        if (self.pages.items.len == 0) return error.NoPage;

        var page = &self.pages.items[self.pages.items.len - 1];
        const page_alloc = page.pageAllocator();

        // Create owned copy of text, stripping soft-hyphens (U+00AD)
        // Soft-hyphens are invisible unless used as break points
        // Allocated on page arena - freed when page is destroyed
        const text_copy = try stripSoftHyphens(page_alloc, str);

        // Determine font reference, mark as used, and cache glyphs
        var cached_glyphs: ?[]const u16 = null;

        const font_ref: FontRef = if (self.current_embedded) |emb| blk: {
            try page.markEmbeddedUsed(self.allocator, emb);
            // Mark chars/glyphs as used for subsetting and cache glyphs
            if (emb.encoding == .identity) {
                cached_glyphs = try emb.markUnicodeCharsUsed(text_copy, page_alloc);
            } else {
                emb.markCharsUsed(text_copy);
            }
            break :blk .{ .embedded = emb };
        } else if (self.current_font) |font| blk: {
            try page.markFontUsed(self.allocator, font);
            break :blk .{ .standard = font };
        } else {
            return error.NoFont;
        };

        // Calculate text width for decorations (only if decoration enabled)
        const text_width = if (self.text_decoration.underline or self.text_decoration.strikethrough)
            self.getTextWidth(text_copy)
        else
            0;

        // Store deferred command with cached glyphs
        try page.commands.append(self.allocator, .{
            .text = .{
                .x = self.x,
                .y = self.y,
                .font_size = self.font_size,
                .char_spacing = self.char_spacing,
                .word_spacing = 0,
                .text_data = text_copy,
                .font = font_ref,
                .text_color = self.text_color,
                .cached_glyphs = cached_glyphs,
                .text_width = text_width,
                .underline = self.text_decoration.underline,
                .strikethrough = self.text_decoration.strikethrough,
            },
        });
    }

    /// Internal: Write text at position with specified word spacing (for justification).
    fn writeWithWordSpacing(self: *Document, x: f64, y: f64, str: []const u8, word_spacing: f64) !void {
        if (self.pages.items.len == 0) return error.NoPage;

        var page = &self.pages.items[self.pages.items.len - 1];
        const page_alloc = page.pageAllocator();

        // Create owned copy of text, stripping soft-hyphens
        // Allocated on page arena - freed when page is destroyed
        const text_copy = try stripSoftHyphens(page_alloc, str);

        // Determine font reference, mark as used, and cache glyphs
        var cached_glyphs: ?[]const u16 = null;

        const font_ref: FontRef = if (self.current_embedded) |emb| blk: {
            try page.markEmbeddedUsed(self.allocator, emb);
            if (emb.encoding == .identity) {
                cached_glyphs = try emb.markUnicodeCharsUsed(text_copy, page_alloc);
            } else {
                emb.markCharsUsed(text_copy);
            }
            break :blk .{ .embedded = emb };
        } else if (self.current_font) |font| blk: {
            try page.markFontUsed(self.allocator, font);
            break :blk .{ .standard = font };
        } else {
            return error.NoFont;
        };

        // Calculate text width for decorations (only if decoration enabled)
        const text_width = if (self.text_decoration.underline or self.text_decoration.strikethrough)
            self.getTextWidth(text_copy)
        else
            0;

        // Store deferred command with word spacing and cached glyphs
        // Convert Y from top-left to PDF coordinates (bottom-left origin)
        try page.commands.append(self.allocator, .{
            .text = .{
                .x = x,
                .y = self.page_size.height - y,
                .font_size = self.font_size,
                .char_spacing = self.char_spacing,
                .word_spacing = word_spacing,
                .text_data = text_copy,
                .font = font_ref,
                .text_color = self.text_color,
                .cached_glyphs = cached_glyphs,
                .text_width = text_width,
                .underline = self.text_decoration.underline,
                .strikethrough = self.text_decoration.strikethrough,
            },
        });
    }

    /// Render CID text with ligatures, kerning, and mark positioning
    /// Returns true if advanced positioning was used (kerning or marks)
    /// start_x, start_y are absolute page coordinates for Tm-based mark positioning
    /// If cached_glyphs is provided, uses those instead of computing from str
    fn renderCIDTextWithKerning(self: *Document, cw: *ContentWriter, emb: *EmbeddedFont, str: []const u8, cached_glyphs: ?[]const u16, font_size: f64, start_x: f64, start_y: f64) !bool {
        _ = self;
        // Use cached glyphs if available, otherwise compute
        const glyphs_to_free: ?[]u16 = if (cached_glyphs == null) try emb.getGlyphsForText(str) else null;
        defer if (glyphs_to_free) |g| emb.allocator.free(g);
        const glyphs = cached_glyphs orelse glyphs_to_free.?;

        if (glyphs.len == 0) return false;

        const has_remap = emb.gid_remap.count() > 0;
        const units_per_em = emb.font.head.?.units_per_em;

        // Check if we have any kerning or mark positioning
        // Fast path: skip check loop if font has no kerning/mark data at all
        var has_kerning = false;
        var has_marks = false;
        const check_kern = emb.feature_flags.kern and emb.has_kern_data;
        const check_marks = (emb.feature_flags.mark or emb.feature_flags.mkmk) and emb.has_mark_data;
        if (check_kern or check_marks) {
            // Early exit once both are found (or we know we won't find the other)
            for (0..glyphs.len -| 1) |i| {
                if (!has_kerning and check_kern and emb.getKerning(glyphs[i], glyphs[i + 1]) != 0) {
                    has_kerning = true;
                    if (!check_marks or has_marks) break;
                }
                if (!has_marks and check_marks and emb.getMarkOffset(glyphs[i], glyphs[i + 1]) != null) {
                    has_marks = true;
                    if (!check_kern or has_kerning) break;
                }
            }
        }

        // If we have marks with y-offsets, use Tm-based absolute positioning (like LibreOffice)
        if (has_marks) {
            return try renderWithMarkPositioning(cw, emb, glyphs, font_size, units_per_em, has_remap, start_x, start_y);
        }

        // No marks - use Td for initial position
        try cw.print("{d:.2} {d:.2} Td\n", .{ start_x, start_y });

        if (!has_kerning) {
            // No kerning - use simple hex string
            try cw.append("<");
            var hex_buf: [4]u8 = undefined;
            for (glyphs) |gid| {
                const final_gid = if (has_remap) emb.gid_remap.get(gid) orelse 0 else gid;
                writeHex4(&hex_buf, final_gid);
                try cw.append(&hex_buf);
            }
            try cw.append("> Tj\n");
            return false;
        }

        // Use TJ operator with kerning adjustments
        // Format: [<HexGlyphs> kern <HexGlyphs> kern ...] TJ
        try cw.append("[<");
        var hex_buf: [4]u8 = undefined;

        for (glyphs, 0..) |gid, i| {
            const final_gid = if (has_remap) emb.gid_remap.get(gid) orelse 0 else gid;
            writeHex4(&hex_buf, final_gid);
            try cw.append(&hex_buf);

            // Add kerning adjustment before next glyph
            if (i + 1 < glyphs.len) {
                const kern = emb.getKerning(gid, glyphs[i + 1]);
                if (kern != 0) {
                    // Convert from font units to 1/1000 em, negate for TJ
                    // TJ uses positive values to move left (reduce spacing)
                    const kern_1000: i32 = @divTrunc(@as(i32, kern) * 1000, @as(i32, units_per_em));
                    try cw.print("> {d} <", .{-kern_1000});
                }
            }
        }

        try cw.append(">] TJ\n");
        return true;
    }

    /// Render glyphs with mark positioning using absolute Tm positioning (like LibreOffice).
    /// Each glyph gets positioned with "1 0 0 1 x y Tm" followed by glyph Tj.
    /// This avoids relying on PDF auto-advance behavior.
    fn renderWithMarkPositioning(cw: *ContentWriter, emb: *EmbeddedFont, glyphs: []const u16, font_size: f64, units_per_em: u16, has_remap: bool, start_x: f64, start_y: f64) !bool {
        // Track absolute position for each glyph
        var abs_x = start_x;
        const abs_y = start_y; // Baseline doesn't change for horizontal text

        var i: usize = 0;
        while (i < glyphs.len) {
            const gid = glyphs[i];
            const final_gid = if (has_remap) emb.gid_remap.get(gid) orelse 0 else gid;
            const glyph_width = emb.getGlyphWidth(gid); // in 1/1000 em
            const glyph_width_pts = @as(f64, @floatFromInt(glyph_width)) * font_size / 1000.0;

            // Check if next glyphs are marks that attach to this base (or to other marks)
            // A mark can attach to:
            // 1. The previous glyph (mark-to-mark for stacked diacritics)
            // 2. The base glyph directly (multiple marks on same base, e.g., cedilla below + acute above)
            var mark_count: usize = 0;
            var j = i + 1;
            while (j < glyphs.len) {
                const potential_mark = glyphs[j];
                // Check mark-to-mark (attaches to previous glyph)
                if (emb.getMarkOffset(glyphs[j - 1], potential_mark) != null) {
                    mark_count += 1;
                    j += 1;
                }
                // Check mark-to-base (attaches directly to base, e.g., acute on 's' when cedilla is also present)
                else if (emb.getMarkOffset(gid, potential_mark) != null) {
                    mark_count += 1;
                    j += 1;
                } else {
                    break;
                }
            }

            // Save base glyph origin for mark positioning
            const base_x = abs_x;
            const base_y = abs_y;

            // Position and output base glyph using Tm (absolute positioning)
            try cw.print("1 0 0 1 {d:.2} {d:.2} Tm ", .{ abs_x, abs_y });
            try cw.print("<{X:0>4}> Tj\n", .{final_gid});

            // Advance position for next base glyph
            abs_x += glyph_width_pts;

            if (mark_count > 0) {
                // Render marks with absolute positioning
                // Track previous glyph for mark-to-mark positioning
                var prev_gid = gid;
                var prev_x = base_x;
                var prev_y = base_y;

                for (0..mark_count) |m| {
                    const mark_gid = glyphs[i + 1 + m];
                    const mark_final_gid = if (has_remap) emb.gid_remap.get(mark_gid) orelse 0 else mark_gid;

                    // Try mark-to-mark first (attaches to previous mark)
                    // Then try mark-to-base (attaches directly to base)
                    var ref_x = base_x;
                    var ref_y = base_y;
                    var offset: ?opentype.MarkOffset = emb.getMarkOffset(prev_gid, mark_gid);
                    if (offset != null) {
                        // Mark-to-mark: position relative to previous mark
                        ref_x = prev_x;
                        ref_y = prev_y;
                    } else {
                        // Try mark-to-base: position relative to base glyph
                        offset = emb.getMarkOffset(gid, mark_gid);
                    }

                    if (offset) |off| {
                        // Convert mark offset from design units to points
                        const dx_pts = @as(f64, @floatFromInt(off.dx)) * font_size / @as(f64, @floatFromInt(units_per_em));
                        const dy_pts = @as(f64, @floatFromInt(off.dy)) * font_size / @as(f64, @floatFromInt(units_per_em));

                        // Mark position is relative to reference glyph (base or previous mark)
                        const mark_x = ref_x + dx_pts;
                        const mark_y = ref_y + dy_pts;

                        // Position and output mark using Tm (absolute positioning)
                        try cw.print("1 0 0 1 {d:.2} {d:.2} Tm ", .{ mark_x, mark_y });
                        try cw.print("<{X:0>4}> Tj\n", .{mark_final_gid});

                        // Update prev position for potential mark-to-mark stacking
                        prev_gid = mark_gid;
                        prev_x = mark_x;
                        prev_y = mark_y;
                    }
                }

                i += 1 + mark_count;
            } else {
                i += 1;
            }

            // Add kerning if next glyph exists
            const next_idx = i;
            if (next_idx < glyphs.len) {
                const kern = emb.getKerning(gid, glyphs[next_idx]);
                if (kern != 0) {
                    const kern_pts = @as(f64, @floatFromInt(kern)) * font_size / @as(f64, @floatFromInt(units_per_em));
                    abs_x += kern_pts;
                }
            }
        }

        return true;
    }

    /// Writes text at the specified position.
    /// Returns the bounding rectangle of the rendered text.
    pub fn writeAt(self: *Document, x: f64, y: f64, str: []const u8) !Rect {
        self.setPosition(.{ .x = x, .y = y });
        try self.writeAtCursor(str);
        const width = self.getTextWidth(str);
        // Y is baseline, so rect top is y - font_size (approximate ascender)
        return .{
            .x = x,
            .y = y - self.font_size,
            .width = width,
            .height = self.font_size,
        };
    }

    /// Measures text width using current font (standard or embedded).
    /// Soft-hyphens (U+00AD) are excluded from measurement as they're invisible.
    pub fn getTextWidth(self: *Document, str: []const u8) f64 {
        // Fast path: no soft-hyphens
        if (!containsSoftHyphens(str)) {
            if (self.current_embedded) |emb| {
                return emb.measureTextWidth(str, self.font_size);
            }
            return metrics.measureTextWidth(str, self.getFontStyle());
        }

        // Slow path: filter out soft-hyphens using stack buffer
        var buf: [4096]u8 = undefined;
        var j: usize = 0;
        var i: usize = 0;
        while (i < str.len and j < buf.len) {
            if (i + 1 < str.len and str[i] == 0xC2 and str[i + 1] == 0xAD) {
                i += 2; // Skip soft-hyphen
            } else {
                buf[j] = str[i];
                j += 1;
                i += 1;
            }
        }
        const filtered = buf[0..j];

        if (self.current_embedded) |emb| {
            return emb.measureTextWidth(filtered, self.font_size);
        }
        return metrics.measureTextWidth(filtered, self.getFontStyle());
    }

    /// Internal line writer with indent and valign support.
    fn writeLineInternal(self: *Document, area: *Region, str: []const u8, alignment: Align, valign: VAlign, indent: f64) !WriteResult {
        const line_height = self.getLineHeightPts();

        // Rect calculation values
        const rect_x = area.x + area.padding.left;
        const rect_y = area.y + area.padding.top + area.cursor_y;
        const rect_width = area.contentWidth();

        // Check if we have room for a line
        if (area.remainingHeight() < line_height) {
            return .{
                .lines_written = 0,
                .overflow = str,
                .rect = .{ .x = rect_x, .y = rect_y, .width = rect_width, .height = 0 },
            };
        }

        const text_width = self.getTextWidth(str);
        const content_width = area.contentWidth();
        const available_width = content_width - indent;

        // Count spaces for justification calculation
        var space_count: usize = 0;
        for (str) |c| {
            if (c == ' ') space_count += 1;
        }

        // Calculate word spacing for justified text
        // Only justify if there are spaces and text doesn't fill line
        const extra_space = available_width - text_width;
        const word_spacing: f64 = if (alignment == .justify and space_count > 0 and extra_space > 0)
            extra_space / @as(f64, @floatFromInt(space_count))
        else
            0;

        // Calculate x position based on alignment (content starts at x + padding.left)
        const content_x = area.x + area.padding.left;
        const x = switch (alignment) {
            .left => content_x + indent,
            .center => content_x + indent + (available_width - text_width) / 2,
            .right => content_x + content_width - text_width,
            .justify => content_x + indent,
        };

        // Calculate y position based on vertical alignment (uses ascender for visible text alignment)
        const content_y = area.y + area.padding.top;
        const ascender = self.getFontMetrics().ascender;
        const y = switch (valign) {
            // Baseline at content_y + cursor_y + ascender (visible text top aligns)
            .top => content_y + area.cursor_y + ascender,
            // Baseline centered in line height
            .middle => content_y + area.cursor_y + line_height / 2 + ascender / 2,
            // Baseline at bottom of line height
            .bottom => content_y + area.cursor_y + line_height,
        };

        // Render text (with word spacing if justified)
        if (word_spacing > 0) {
            try self.writeWithWordSpacing(x, y, str, word_spacing);
        } else {
            _ = try self.writeAt(x, y, str);
        }

        // Advance cursor
        area.cursor_y += line_height;

        return .{
            .lines_written = 1,
            .overflow = null,
            .rect = .{ .x = rect_x, .y = rect_y, .width = rect_width, .height = line_height },
        };
    }

    /// Writes flowing text into a region with word wrapping.
    /// Text continues from the current cursor position (cursor_x, cursor_y).
    /// Words wrap to the next line when they don't fit. Cursor is updated to
    /// the end of the written text, allowing subsequent write() calls to continue
    /// the flow with different styles.
    ///
    /// Options:
    /// - measure_only: Track cursor position without rendering (for calculating dimensions)
    /// - wrap: If false, text stays on one line without wrapping
    pub fn write(self: *Document, region: *Region, str: []const u8, opts: WriteOptions) !WriteResult {
        const line_height = self.getLineHeightPts();
        const ascender = self.getFontMetrics().ascender;
        const space_width = self.getTextWidth(" ");

        // Helper to compute y position based on valign
        // Uses ascender for .top so visible text top aligns with cursor position
        const getYPos = struct {
            fn call(reg: *Region, lh: f64, asc: f64, valign: VAlign) f64 {
                return switch (valign) {
                    .top => reg.y + reg.padding.top + reg.cursor_y + asc,
                    .middle => reg.y + reg.padding.top + reg.cursor_y + lh / 2 + asc / 2,
                    .bottom => reg.y + reg.padding.top + reg.cursor_y + lh,
                };
            }
        }.call;

        // Track for rect calculation
        const start_cursor_x = region.cursor_x;
        const start_cursor_y = region.cursor_y;
        const rect_x = region.x + region.padding.left + start_cursor_x;
        const rect_y = region.y + region.padding.top + start_cursor_y;
        var max_x: f64 = start_cursor_x;

        var lines_written: usize = 0;
        var remaining = str;

        // Skip leading whitespace only at start of line
        if (region.cursor_x == 0) {
            while (remaining.len > 0 and (remaining[0] == ' ' or remaining[0] == '\t')) {
                remaining = remaining[1..];
            }
        }

        while (remaining.len > 0) {
            // Check if we have room for a line (only check at start of new line)
            // Use small epsilon for floating point comparison
            if (region.cursor_x == 0 and region.remainingHeight() < line_height - 0.01) {
                return .{
                    .lines_written = lines_written,
                    .overflow = remaining,
                    .rect = .{ .x = rect_x, .y = rect_y, .width = max_x - start_cursor_x, .height = @as(f64, @floatFromInt(lines_written)) * line_height },
                };
            }

            // Find the next word
            var word_end: usize = 0;
            var is_newline = false;
            for (remaining, 0..) |c, i| {
                if (c == ' ' or c == '\t' or c == '\n') {
                    word_end = i;
                    is_newline = (c == '\n');
                    break;
                }
            } else {
                word_end = remaining.len;
            }

            if (word_end == 0) {
                // Whitespace at start - handle newline or skip space
                if (is_newline) {
                    region.newLine(line_height);
                    lines_written += 1;
                }
                remaining = remaining[1..];
                continue;
            }

            const word = remaining[0..word_end];
            const word_width = self.getTextWidth(word);
            const available_width = region.remainingWidth();

            // Check if word fits on current line
            if (word_width <= available_width + 0.01) {
                // Word fits - write it
                if (!opts.measure_only) {
                    const abs_x = region.x + region.padding.left + region.cursor_x;
                    const abs_y = getYPos(region, line_height, ascender, opts.valign);
                    self.setPosition(.{ .x = abs_x, .y = abs_y });
                    try self.writeAtCursor(word);
                }

                region.cursor_x += word_width;
                if (region.cursor_x > max_x) max_x = region.cursor_x;

                // Handle what comes after the word
                remaining = remaining[word_end..];
                if (remaining.len > 0) {
                    const next_char = remaining[0];
                    if (next_char == '\n') {
                        // Explicit newline (always respected, even with wrap=false)
                        region.newLine(line_height);
                        lines_written += 1;
                        remaining = remaining[1..];
                        // Skip whitespace at start of new line
                        while (remaining.len > 0 and (remaining[0] == ' ' or remaining[0] == '\t')) {
                            remaining = remaining[1..];
                        }
                    } else if (next_char == ' ' or next_char == '\t') {
                        // Add space after word
                        region.cursor_x += space_width;
                        remaining = remaining[1..];
                    }
                }
            } else if (!opts.wrap) {
                // No wrapping - write word at current position even if it overflows
                if (!opts.measure_only) {
                    const abs_x = region.x + region.padding.left + region.cursor_x;
                    const abs_y = getYPos(region, line_height, ascender, opts.valign);
                    self.setPosition(.{ .x = abs_x, .y = abs_y });
                    try self.writeAtCursor(word);
                }
                region.cursor_x += word_width;
                if (region.cursor_x > max_x) max_x = region.cursor_x;
                remaining = remaining[word_end..];
                if (remaining.len > 0 and (remaining[0] == ' ' or remaining[0] == '\t')) {
                    region.cursor_x += space_width;
                    remaining = remaining[1..];
                }
            } else if (region.cursor_x == 0) {
                // Word doesn't fit and we're at start of line - must write it anyway
                // Try soft-hyphen break first
                if (self.findSoftHyphenBreak(word, available_width)) |break_pos| {
                    const prefix = word[0..break_pos];
                    if (!opts.measure_only) {
                        const abs_x = region.x + region.padding.left;
                        const abs_y = getYPos(region, line_height, ascender, opts.valign);
                        self.setPosition(.{ .x = abs_x, .y = abs_y });
                        try self.writeAtCursor(prefix);
                        try self.writeAtCursor("-");
                    }
                    region.cursor_x = self.getTextWidth(prefix) + self.getTextWidth("-");
                    if (region.cursor_x > max_x) max_x = region.cursor_x;
                    region.newLine(line_height);
                    lines_written += 1;
                    remaining = remaining[break_pos + 2 ..]; // Skip soft-hyphen (2 bytes)
                } else if (opts.break_on_hyphens and self.findHyphenBreak(word, available_width) != null) {
                    const break_pos = self.findHyphenBreak(word, available_width).?;
                    const prefix = word[0..break_pos];
                    if (!opts.measure_only) {
                        const abs_x = region.x + region.padding.left;
                        const abs_y = getYPos(region, line_height, ascender, opts.valign);
                        self.setPosition(.{ .x = abs_x, .y = abs_y });
                        try self.writeAtCursor(prefix);
                    }
                    region.cursor_x = self.getTextWidth(prefix);
                    if (region.cursor_x > max_x) max_x = region.cursor_x;
                    region.newLine(line_height);
                    lines_written += 1;
                    remaining = remaining[break_pos..];
                } else if (self.findCharacterBreak(word, available_width)) |break_pos| {
                    const prefix = word[0..break_pos];
                    if (!opts.measure_only) {
                        const abs_x = region.x + region.padding.left;
                        const abs_y = getYPos(region, line_height, ascender, opts.valign);
                        self.setPosition(.{ .x = abs_x, .y = abs_y });
                        try self.writeAtCursor(prefix);
                    }
                    region.cursor_x = self.getTextWidth(prefix);
                    if (region.cursor_x > max_x) max_x = region.cursor_x;
                    region.newLine(line_height);
                    lines_written += 1;
                    remaining = remaining[break_pos..];
                } else {
                    // Nothing fits, write word anyway (will overflow)
                    if (!opts.measure_only) {
                        const abs_x = region.x + region.padding.left;
                        const abs_y = getYPos(region, line_height, ascender, opts.valign);
                        self.setPosition(.{ .x = abs_x, .y = abs_y });
                        try self.writeAtCursor(word);
                    }
                    region.cursor_x = word_width;
                    if (region.cursor_x > max_x) max_x = region.cursor_x;
                    remaining = remaining[word_end..];
                    if (remaining.len > 0 and (remaining[0] == ' ' or remaining[0] == '\t' or remaining[0] == '\n')) {
                        remaining = remaining[1..];
                    }
                }
            } else {
                // Word doesn't fit - wrap to next line
                region.newLine(line_height);
                lines_written += 1;
                // Don't consume the word, let next iteration handle it
            }
        }

        // Calculate actual lines - if cursor moved vertically, that's our line count
        const final_lines: usize = if (region.cursor_y > start_cursor_y)
            @as(usize, @intFromFloat((region.cursor_y - start_cursor_y) / line_height)) + 1
        else if (region.cursor_x > start_cursor_x)
            1
        else
            0;

        return .{
            .lines_written = final_lines,
            .overflow = null,
            .rect = .{
                .x = rect_x,
                .y = rect_y,
                .width = max_x - start_cursor_x,
                .height = if (final_lines > 0) @as(f64, @floatFromInt(final_lines)) * line_height else 0,
            },
        };
    }

    /// Find a soft-hyphen break point in a word that fits within max_width.
    /// Soft-hyphen (U+00AD, 0xC2 0xAD in UTF-8) marks optional break points.
    /// Returns the byte position where to break (soft-hyphen will be replaced with visible hyphen).
    pub fn findSoftHyphenBreak(self: *Document, word: []const u8, max_width: f64) ?usize {
        var best_break: ?usize = null;
        var i: usize = 0;
        while (i + 1 < word.len) {
            // Soft-hyphen in UTF-8 is 0xC2 0xAD
            if (word[i] == 0xC2 and word[i + 1] == 0xAD) {
                // Found a soft-hyphen - measure prefix with a visible hyphen substituted
                const prefix = word[0..i];
                const prefix_width = self.getTextWidth(prefix) + self.getTextWidth("-");
                if (prefix_width <= max_width) {
                    best_break = i; // Position of the soft-hyphen
                } else {
                    break; // Prefix too wide, no point checking further
                }
                i += 2; // Skip the 2-byte soft-hyphen
            } else {
                i += 1;
            }
        }
        return best_break;
    }

    /// Find a regular hyphen break point in a word that fits within max_width.
    /// Regular hyphens stay visible; we break AFTER the hyphen (e.g., "state-" / "of-the-art").
    /// Returns the byte position after the hyphen where to split.
    pub fn findHyphenBreak(self: *Document, word: []const u8, max_width: f64) ?usize {
        var best_break: ?usize = null;
        for (word, 0..) |c, i| {
            if (c == '-' and i > 0 and i + 1 < word.len) {
                // Found a hyphen - measure prefix including the hyphen
                const prefix = word[0 .. i + 1];
                const prefix_width = self.getTextWidth(prefix);
                if (prefix_width <= max_width) {
                    best_break = i + 1; // Position after the hyphen
                } else {
                    break; // Prefix too wide, no point checking further
                }
            }
        }
        return best_break;
    }

    /// Find a character break point in a word that fits within max_width.
    /// This is a last resort when no hyphen or soft-hyphen breaks are available.
    /// Returns the byte position where to break (respecting UTF-8 boundaries).
    fn findCharacterBreak(self: *Document, word: []const u8, max_width: f64) ?usize {
        var best_break: ?usize = null;
        var current_width: f64 = 0;
        var i: usize = 0;

        while (i < word.len) {
            // Find the end of the current UTF-8 character
            const char_len = std.unicode.utf8ByteSequenceLength(word[i]) catch 1;
            const char_end = @min(i + char_len, word.len);

            // Measure width including this character
            const prefix_width = self.getTextWidth(word[0..char_end]);

            if (prefix_width <= max_width) {
                best_break = char_end;
                current_width = prefix_width;
                i = char_end;
            } else {
                break;
            }
        }

        // Only return if we found at least one character that fits
        if (best_break) |pos| {
            if (pos > 0 and pos < word.len) {
                return pos;
            }
        }
        return null;
    }

    /// Word info for optimal line breaking.
    const WordInfo = struct {
        start: usize, // Byte offset in original text
        end: usize, // Byte offset (exclusive)
        width: f64, // Width in points
        force_break: bool, // Must break after this word (newline follows)
    };

    fn computeOptimalBreaks(
        self: *Document,
        text: []const u8,
        line_width: f64,
        first_line_width: f64,
    ) ![]usize {
        const allocator = self.allocator;
        const space_width = self.getTextWidth(" ");

        // Parse text into words, tracking forced breaks (newlines)
        var words = std.ArrayListUnmanaged(WordInfo){};
        defer words.deinit(allocator);

        var i: usize = 0;
        while (i < text.len) {
            // Skip whitespace (but track if we see a newline)
            while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n')) {
                i += 1;
            }
            if (i >= text.len) break;

            // Find word end
            const word_start = i;
            while (i < text.len and text[i] != ' ' and text[i] != '\t' and text[i] != '\n') {
                i += 1;
            }
            const word_end = i;

            // Check if a newline follows this word (forced break)
            var force_break = false;
            var j = i;
            while (j < text.len and (text[j] == ' ' or text[j] == '\t')) {
                j += 1;
            }
            if (j < text.len and text[j] == '\n') {
                force_break = true;
            }

            try words.append(allocator, .{
                .start = word_start,
                .end = word_end,
                .width = self.getTextWidth(text[word_start..word_end]),
                .force_break = force_break,
            });
        }

        if (words.items.len == 0) {
            return allocator.alloc(usize, 0);
        }

        const n = words.items.len;
        const INFINITY: f64 = 1e18;

        // dp[i] = minimum total badness to typeset words 0..i-1 (i words)
        // prev[i] = which word index starts the line ending at word i-1
        var dp = try allocator.alloc(f64, n + 1);
        defer allocator.free(dp);
        var prev = try allocator.alloc(usize, n + 1);
        defer allocator.free(prev);

        dp[0] = 0;
        prev[0] = 0;

        // For each ending position
        for (1..n + 1) |j| {
            dp[j] = INFINITY;
            prev[j] = 0;

            // Try each starting position for this line
            var line_w: f64 = 0;
            var start_i = j;
            while (start_i > 0) {
                start_i -= 1;
                const word = words.items[start_i];

                // If this word has force_break but isn't the last word of the line,
                // this configuration is invalid (word must be at line end)
                if (word.force_break and start_i + 1 < j) {
                    break;
                }

                // Add word width (and space if not first word on line)
                if (start_i + 1 < j) {
                    line_w += space_width;
                }
                line_w += word.width;

                // Get the line width for this line (first line may be different)
                const this_line_width = if (start_i == 0) first_line_width else line_width;

                // Line too wide - no point trying earlier start positions
                if (line_w > this_line_width + 0.01) break;

                // Compute badness for this line configuration
                const slack = this_line_width - line_w;
                const is_last_line = (j == n);

                // Lines ending with forced break: no penalty (will be left-aligned)
                // Last line: no penalty for short lines (left-aligned)
                // Other lines: penalize based on slack squared
                const is_forced = words.items[j - 1].force_break;
                const badness = if (is_last_line or is_forced) 0.0 else slack * slack;

                const total = dp[start_i] + badness;
                if (total < dp[j]) {
                    dp[j] = total;
                    prev[j] = start_i;
                }
            }
        }

        // Backtrack to find break points
        var breaks = std.ArrayListUnmanaged(usize){};
        errdefer breaks.deinit(allocator);

        var pos = n;
        while (pos > 0) {
            const line_start = prev[pos];
            // Line contains words[line_start..pos], ends at word pos-1
            const last_word = words.items[pos - 1];
            try breaks.append(allocator, last_word.end);
            pos = line_start;
        }

        // Reverse to get breaks in order
        std.mem.reverse(usize, breaks.items);

        return breaks.toOwnedSlice(allocator);
    }

    /// Measures how wrapped text would be laid out without rendering.
    /// Returns total height, line count, and max line width.
    /// Useful for calculating layout before rendering, checking if text fits, etc.
    pub fn measureWrappedText(self: *Document, str: []const u8, opts: MeasureOptions) WrappedTextMetrics {
        const line_height = self.getLineHeightPts();
        const space_width = self.getTextWidth(" ");
        var line_count: usize = 0;
        var max_line_width: f64 = 0;
        var is_first_line = true;

        // Handle empty text
        if (str.len == 0) {
            return .{ .height = 0, .line_count = 0, .max_line_width = 0 };
        }

        // Greedy algorithm: process text word by word (same as writeParagraph)
        var remaining = str;
        while (remaining.len > 0) {
            // Calculate available width for this line
            const indent = if (is_first_line) opts.first_indent else 0;
            const line_width = opts.width - indent;

            // Build a line by collecting words
            var line_end: usize = 0;
            var current_width: f64 = 0;
            var word_start: usize = 0;
            var in_word = false;
            var actual_line_width: f64 = 0;

            for (remaining, 0..) |c, i| {
                const is_space = c == ' ' or c == '\t' or c == '\n';

                if (is_space and in_word) {
                    // End of word - check if it fits
                    const word = remaining[word_start..i];
                    const word_width = self.getTextWidth(word);

                    if (current_width + word_width <= line_width + 0.01) {
                        // Word fits
                        actual_line_width = current_width + word_width;
                        current_width += word_width + space_width;
                        line_end = i;
                    } else if (line_end == 0) {
                        // First word doesn't fit - try breaking
                        if (opts.break_on_hyphens) {
                            if (self.findHyphenBreak(word, line_width)) |break_pos| {
                                const broken = remaining[word_start .. word_start + break_pos];
                                actual_line_width = self.getTextWidth(broken);
                                line_end = word_start + break_pos;
                                break;
                            }
                        }
                        if (self.findSoftHyphenBreak(word, line_width)) |break_pos| {
                            const broken = remaining[word_start .. word_start + break_pos];
                            actual_line_width = self.getTextWidth(broken) + self.getTextWidth("-");
                            line_end = word_start + break_pos;
                        } else if (self.findCharacterBreak(word, line_width)) |break_pos| {
                            const broken = remaining[word_start .. word_start + break_pos];
                            actual_line_width = self.getTextWidth(broken);
                            line_end = word_start + break_pos;
                        } else {
                            actual_line_width = word_width;
                            line_end = i;
                        }
                        break;
                    } else {
                        // Word doesn't fit, wrap to next line
                        break;
                    }
                    in_word = false;

                    if (c == '\n') {
                        line_end = i;
                        break;
                    }
                } else if (!is_space and !in_word) {
                    word_start = i;
                    in_word = true;
                }
            }

            // Handle last word if still in one
            if (in_word) {
                const word = remaining[word_start..];
                const word_width = self.getTextWidth(word);

                if (current_width + word_width <= line_width + 0.01) {
                    actual_line_width = current_width + word_width;
                    line_end = remaining.len;
                } else if (line_end == 0) {
                    if (opts.break_on_hyphens) {
                        if (self.findHyphenBreak(word, line_width)) |break_pos| {
                            const broken = remaining[word_start .. word_start + break_pos];
                            actual_line_width = self.getTextWidth(broken);
                            line_end = word_start + break_pos;
                        }
                    }
                    if (line_end == 0) {
                        if (self.findSoftHyphenBreak(word, line_width)) |break_pos| {
                            const broken = remaining[word_start .. word_start + break_pos];
                            actual_line_width = self.getTextWidth(broken) + self.getTextWidth("-");
                            line_end = word_start + break_pos;
                        } else if (self.findCharacterBreak(word, line_width)) |break_pos| {
                            const broken = remaining[word_start .. word_start + break_pos];
                            actual_line_width = self.getTextWidth(broken);
                            line_end = word_start + break_pos;
                        } else {
                            actual_line_width = word_width;
                            line_end = remaining.len;
                        }
                    }
                }
            }

            if (line_end == 0) break;

            // Count this line
            line_count += 1;
            if (actual_line_width > max_line_width) {
                max_line_width = actual_line_width;
            }

            // Check for soft-hyphen break (0xC2 0xAD in UTF-8)
            const soft_hyphen_break = line_end >= 2 and
                remaining[line_end - 2] == 0xC2 and remaining[line_end - 1] == 0xAD;

            // Advance past the line
            if (soft_hyphen_break) {
                remaining = remaining[@min(line_end + 2, remaining.len)..];
            } else {
                remaining = remaining[line_end..];
            }

            // Skip leading whitespace for next line
            while (remaining.len > 0 and (remaining[0] == ' ' or remaining[0] == '\t' or remaining[0] == '\n')) {
                remaining = remaining[1..];
            }

            is_first_line = false;
        }

        return .{
            .height = @as(f64, @floatFromInt(line_count)) * line_height,
            .line_count = line_count,
            .max_line_width = max_line_width,
        };
    }

    /// Writes wrapped text into a region.
    /// Supports word wrapping, soft-hyphen breaking, and optional hyphenated word breaking.
    pub fn writeParagraph(self: *Document, region: *Region, str: []const u8, opts: ParagraphOptions) !WriteResult {
        const line_height = self.getLineHeightPts();
        const space_width = self.getTextWidth(" ");
        var lines_written: usize = 0;

        // Track starting position for rect calculation
        const start_cursor_y = region.cursor_y;
        const rect_x = region.x + region.padding.left;
        const rect_y = region.y + region.padding.top + start_cursor_y;
        const rect_width = region.contentWidth();

        // Use optimal (Knuth-Plass) line breaking if requested
        if (opts.line_breaking == .optimal) {
            return self.writeParagraphOptimal(region, str, opts, start_cursor_y);
        }

        // Greedy algorithm: process text word by word
        var remaining = str;
        while (remaining.len > 0) {
            // Check if we have room for another line
            if (region.remainingHeight() < line_height) {
                return .{
                    .lines_written = lines_written,
                    .overflow = remaining,
                    .rect = .{ .x = rect_x, .y = rect_y, .width = rect_width, .height = @as(f64, @floatFromInt(lines_written)) * line_height },
                };
            }

            // Calculate available width for this line (respects padding)
            const line_width = region.contentWidth();

            // Build a line by collecting words
            var line_end: usize = 0;
            var current_width: f64 = 0;
            var word_start: usize = 0;
            var in_word = false;
            var soft_hyphen_break = false;
            var forced_break = false; // Line ended due to explicit newline

            for (remaining, 0..) |c, i| {
                const is_space = c == ' ' or c == '\t' or c == '\n';

                if (is_space and in_word) {
                    // End of word - check if it fits (with small tolerance for floating point)
                    const word = remaining[word_start..i];
                    const word_width = self.getTextWidth(word);

                    if (current_width + word_width <= line_width + 0.01) {
                        // Word fits
                        current_width += word_width + space_width;
                        line_end = i;
                    } else if (line_end == 0) {
                        // First word doesn't fit on empty line - try breaking at hyphens
                        if (opts.break_on_hyphens) {
                            if (self.findHyphenBreak(word, line_width)) |break_pos| {
                                line_end = word_start + break_pos;
                                break;
                            }
                        }
                        // Try soft-hyphen break as fallback
                        if (self.findSoftHyphenBreak(word, line_width)) |break_pos| {
                            line_end = word_start + break_pos;
                            soft_hyphen_break = true;
                        } else if (self.findCharacterBreak(word, line_width)) |break_pos| {
                            // Last resort: character-level break
                            line_end = word_start + break_pos;
                        } else {
                            // Nothing fits, include word anyway (will overflow)
                            line_end = i;
                        }
                        break;
                    } else {
                        // Word doesn't fit, wrap to next line (keep word intact)
                        break;
                    }
                    in_word = false;

                    // Handle newline as line break
                    if (c == '\n') {
                        line_end = i;
                        forced_break = true;
                        break;
                    }
                } else if (!is_space and !in_word) {
                    // Start of word
                    word_start = i;
                    in_word = true;
                }
            }

            // Handle last word if we're still in one
            if (in_word) {
                const word = remaining[word_start..];
                const word_width = self.getTextWidth(word);

                if (current_width + word_width <= line_width + 0.01) {
                    line_end = remaining.len;
                } else if (line_end == 0) {
                    // First word doesn't fit - try breaking at hyphens
                    if (opts.break_on_hyphens) {
                        if (self.findHyphenBreak(word, line_width)) |break_pos| {
                            line_end = word_start + break_pos;
                        }
                    }
                    // Try soft-hyphen break as fallback
                    if (line_end == 0) {
                        if (self.findSoftHyphenBreak(word, line_width)) |break_pos| {
                            line_end = word_start + break_pos;
                            soft_hyphen_break = true;
                        } else if (self.findCharacterBreak(word, line_width)) |break_pos| {
                            // Last resort: character-level break
                            line_end = word_start + break_pos;
                        } else {
                            line_end = remaining.len; // Nothing fits, include anyway
                        }
                    }
                }
                // else: word doesn't fit, leave line_end as is (wrap word to next line)
            }

            // Handle empty remaining (shouldn't happen but safety)
            if (line_end == 0) {
                break;
            }

            // Get the line text and trim trailing spaces
            var line = remaining[0..line_end];
            while (line.len > 0 and (line[line.len - 1] == ' ' or line[line.len - 1] == '\t')) {
                line = line[0 .. line.len - 1];
            }

            // Determine if this is the last line (for justify: don't justify last line)
            const is_last_line = blk: {
                // Calculate what remaining would be after this line
                var next_remaining = if (soft_hyphen_break)
                    remaining[line_end + 2 ..]
                else
                    remaining[line_end..];
                // Skip whitespace
                while (next_remaining.len > 0 and (next_remaining[0] == ' ' or next_remaining[0] == '\t' or next_remaining[0] == '\n')) {
                    next_remaining = next_remaining[1..];
                }
                break :blk next_remaining.len == 0;
            };

            // For justify alignment, use left alignment on last line or forced breaks (standard typography)
            const line_alignment = if (opts.alignment == .justify and (is_last_line or forced_break))
                Align.left
            else
                opts.alignment;

            // Render the line (with visible hyphen if breaking at soft-hyphen)
            if (soft_hyphen_break) {
                // Append visible hyphen for soft-hyphen break
                var buf: [4096]u8 = undefined;
                if (line.len < buf.len - 1) {
                    @memcpy(buf[0..line.len], line);
                    buf[line.len] = '-';
                    _ = try self.writeLineInternal(region, buf[0 .. line.len + 1], line_alignment, opts.valign, 0);
                } else {
                    // Line too long for buffer, render without hyphen (fallback)
                    _ = try self.writeLineInternal(region, line, line_alignment, opts.valign, 0);
                }
            } else {
                _ = try self.writeLineInternal(region, line, line_alignment, opts.valign, 0);
            }
            lines_written += 1;

            // Skip past rendered text
            if (soft_hyphen_break) {
                // Skip the 2-byte soft-hyphen (0xC2 0xAD)
                remaining = remaining[line_end + 2 ..];
            } else {
                remaining = remaining[line_end..];
            }
            // Skip any following whitespace
            while (remaining.len > 0 and (remaining[0] == ' ' or remaining[0] == '\t' or remaining[0] == '\n')) {
                remaining = remaining[1..];
            }
        }

        return .{
            .lines_written = lines_written,
            .overflow = null,
            .rect = .{ .x = rect_x, .y = rect_y, .width = rect_width, .height = @as(f64, @floatFromInt(lines_written)) * line_height },
        };
    }

    /// Write paragraph using pre-computed optimal line breaks.
    fn writeParagraphOptimal(self: *Document, region: *Region, str: []const u8, opts: ParagraphOptions, start_cursor_y: f64) !WriteResult {
        const line_height = self.getLineHeightPts();
        const line_width = region.contentWidth();

        // Rect calculation values
        const rect_x = region.x + region.padding.left;
        const rect_y = region.y + region.padding.top + start_cursor_y;
        const rect_width = region.contentWidth();

        // Compute optimal break points
        const breaks = try self.computeOptimalBreaks(str, line_width, line_width);
        defer self.allocator.free(breaks);

        if (breaks.len == 0) {
            return .{ .lines_written = 0, .overflow = null, .rect = .{ .x = rect_x, .y = rect_y, .width = rect_width, .height = 0 } };
        }

        var lines_written: usize = 0;
        var line_start: usize = 0;

        for (breaks, 0..) |break_pos, line_idx| {
            // Check if we have room for another line
            if (region.remainingHeight() < line_height) {
                // Find the byte position of overflow (skip leading whitespace)
                var overflow_start = line_start;
                while (overflow_start < str.len and
                    (str[overflow_start] == ' ' or str[overflow_start] == '\t' or str[overflow_start] == '\n'))
                {
                    overflow_start += 1;
                }
                return .{
                    .lines_written = lines_written,
                    .overflow = if (overflow_start < str.len) str[overflow_start..] else null,
                    .rect = .{ .x = rect_x, .y = rect_y, .width = rect_width, .height = @as(f64, @floatFromInt(lines_written)) * line_height },
                };
            }

            // Get line text and trim whitespace
            var line = str[line_start..break_pos];
            // Trim leading whitespace
            while (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) {
                line = line[1..];
            }
            // Trim trailing whitespace
            while (line.len > 0 and (line[line.len - 1] == ' ' or line[line.len - 1] == '\t')) {
                line = line[0 .. line.len - 1];
            }

            // Determine if this is the last line or ends at a paragraph break
            const is_last_line = (line_idx == breaks.len - 1);
            // Check if this line ends at a newline (forced paragraph break)
            // Need to scan past spaces to find if there's a newline
            var forced_break = false;
            {
                var scan = break_pos;
                while (scan < str.len and (str[scan] == ' ' or str[scan] == '\t')) {
                    scan += 1;
                }
                if (scan < str.len and str[scan] == '\n') {
                    forced_break = true;
                }
            }

            // For justify alignment, use left alignment on last line or forced breaks
            const line_alignment = if (opts.alignment == .justify and (is_last_line or forced_break))
                Align.left
            else
                opts.alignment;

            // Render the line
            _ = try self.writeLineInternal(region, line, line_alignment, opts.valign, 0);
            lines_written += 1;

            // Move past break point and any whitespace
            line_start = break_pos;
            while (line_start < str.len and
                (str[line_start] == ' ' or str[line_start] == '\t' or str[line_start] == '\n'))
            {
                line_start += 1;
            }
        }

        return .{ .lines_written = lines_written, .overflow = null, .rect = .{ .x = rect_x, .y = rect_y, .width = rect_width, .height = @as(f64, @floatFromInt(lines_written)) * line_height } };
    }

    /// Draws a region's border and fill (without text).
    pub fn drawRegion(self: *Document, region: Region) !void {
        if (self.pages.items.len == 0) return error.NoPage;

        var page = &self.pages.items[self.pages.items.len - 1];

        // Convert from top-left coordinates to PDF coordinates (bottom-left origin)
        const pdf_y = self.page_size.height - region.y - region.height;

        // Build raw PDF commands for the region
        // Use q/Q (save/restore) to isolate graphics state changes (colors, etc.)
        var buf: [512]u8 = undefined;
        var len: usize = 0;

        // Save graphics state
        len += (std.fmt.bufPrint(buf[len..], "q\n", .{}) catch unreachable).len;

        // Fill if specified
        if (region.fill) |fill_color| {
            // Write fill color command
            var color_buf: [64]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&color_buf);
            fill_color.writeFill(fbs.writer()) catch unreachable;
            const color_str = fbs.getWritten();
            @memcpy(buf[len .. len + color_str.len], color_str);
            len += color_str.len;

            len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} {d:.2} {d:.2} re f\n", .{ region.x, pdf_y, region.width, region.height }) catch unreachable).len;
        }

        // Draw border if specified
        if (region.border.top or region.border.bottom or region.border.left or region.border.right) {
            // Set line width to 0.567pt (fpdf2 default: 0.2mm)
            len += (std.fmt.bufPrint(buf[len..], "0.567 w\n", .{}) catch unreachable).len;
            // Set stroke color to black
            len += (std.fmt.bufPrint(buf[len..], "0 0 0 RG\n", .{}) catch unreachable).len;

            if (region.border.top) {
                const y_top = pdf_y + region.height;
                len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} m {d:.2} {d:.2} l S\n", .{ region.x, y_top, region.x + region.width, y_top }) catch unreachable).len;
            }
            if (region.border.bottom) {
                len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} m {d:.2} {d:.2} l S\n", .{ region.x, pdf_y, region.x + region.width, pdf_y }) catch unreachable).len;
            }
            if (region.border.left) {
                len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} m {d:.2} {d:.2} l S\n", .{ region.x, pdf_y, region.x, pdf_y + region.height }) catch unreachable).len;
            }
            if (region.border.right) {
                const x_right = region.x + region.width;
                len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} m {d:.2} {d:.2} l S\n", .{ x_right, pdf_y, x_right, pdf_y + region.height }) catch unreachable).len;
            }
        }

        // Restore graphics state
        len += (std.fmt.bufPrint(buf[len..], "Q\n", .{}) catch unreachable).len;

        if (len > 0) {
            // Allocated on page arena - freed when page is destroyed
            const raw_copy = try page.pageAllocator().dupe(u8, buf[0..len]);
            try page.commands.append(self.allocator, .{ .raw = raw_copy });
        }
    }

    // ========================================================================
    // Graphics Primitives
    // ========================================================================

    /// Write graphics state operators (line width, dash pattern, colors).
    /// Used internally by shape drawing methods.
    fn writeGraphicsState(self: *Document, buf: []u8, style: DrawStyle) usize {
        var len: usize = 0;

        // Line width
        len += (std.fmt.bufPrint(buf[len..], "{d:.3} w\n", .{self.line_width}) catch unreachable).len;

        // Dash pattern
        if (self.dash_pattern.dash > 0) {
            len += (std.fmt.bufPrint(buf[len..], "[{d:.3} {d:.3}] {d:.3} d\n", .{ self.dash_pattern.dash, self.dash_pattern.gap, self.dash_pattern.phase }) catch unreachable).len;
        } else {
            len += (std.fmt.bufPrint(buf[len..], "[] 0 d\n", .{}) catch unreachable).len;
        }

        // Line cap and join
        len += (std.fmt.bufPrint(buf[len..], "{d} J {d} j\n", .{ @intFromEnum(self.line_cap), @intFromEnum(self.line_join) }) catch unreachable).len;

        // Stroke color (for stroke and fill_stroke)
        if (style == .stroke or style == .fill_stroke) {
            var color_buf: [64]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&color_buf);
            self.draw_color.writeStroke(fbs.writer()) catch unreachable;
            const color_str = fbs.getWritten();
            @memcpy(buf[len .. len + color_str.len], color_str);
            len += color_str.len;
        }

        // Fill color (for fill and fill_stroke)
        if (style == .fill or style == .fill_stroke) {
            var color_buf: [64]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&color_buf);
            self.fill_color.writeFill(fbs.writer()) catch unreachable;
            const color_str = fbs.getWritten();
            @memcpy(buf[len .. len + color_str.len], color_str);
            len += color_str.len;
        }

        return len;
    }

    /// Get PDF path operator for the given draw style.
    fn getPathOperator(style: DrawStyle) []const u8 {
        return switch (style) {
            .stroke => "S\n",
            .fill => "f\n",
            .fill_stroke => "B\n",
        };
    }

    /// Draw a line between two points.
    /// Coordinates are from top-left origin.
    pub fn drawLine(self: *Document, x1: f64, y1: f64, x2: f64, y2: f64) !void {
        if (self.pages.items.len == 0) return error.NoPage;

        var page = &self.pages.items[self.pages.items.len - 1];
        const page_height = self.page_size.height;

        // Convert from top-left to PDF coordinates (bottom-left origin)
        const pdf_y1 = page_height - y1;
        const pdf_y2 = page_height - y2;

        var buf: [512]u8 = undefined;
        var len: usize = 0;

        // Save graphics state
        len += (std.fmt.bufPrint(buf[len..], "q\n", .{}) catch unreachable).len;

        // Graphics state (line width, dash, colors)
        len += self.writeGraphicsState(buf[len..], .stroke);

        // Move to start, line to end, stroke
        len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} m {d:.2} {d:.2} l S\n", .{ x1, pdf_y1, x2, pdf_y2 }) catch unreachable).len;

        // Restore graphics state
        len += (std.fmt.bufPrint(buf[len..], "Q\n", .{}) catch unreachable).len;

        const raw_copy = try page.pageAllocator().dupe(u8, buf[0..len]);
        try page.commands.append(self.allocator, .{ .raw = raw_copy });
    }

    /// Draw a rectangle.
    /// Coordinates are from top-left origin.
    pub fn drawRect(self: *Document, x: f64, y: f64, w: f64, h: f64, style: DrawStyle) !void {
        if (self.pages.items.len == 0) return error.NoPage;

        var page = &self.pages.items[self.pages.items.len - 1];
        const page_height = self.page_size.height;

        // Convert from top-left to PDF coordinates (bottom-left origin)
        const pdf_y = page_height - y - h;

        var buf: [512]u8 = undefined;
        var len: usize = 0;

        // Save graphics state
        len += (std.fmt.bufPrint(buf[len..], "q\n", .{}) catch unreachable).len;

        // Graphics state
        len += self.writeGraphicsState(buf[len..], style);

        // Rectangle path and operator
        len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} {d:.2} {d:.2} re ", .{ x, pdf_y, w, h }) catch unreachable).len;
        const op = getPathOperator(style);
        @memcpy(buf[len .. len + op.len], op);
        len += op.len;

        // Restore graphics state
        len += (std.fmt.bufPrint(buf[len..], "Q\n", .{}) catch unreachable).len;

        const raw_copy = try page.pageAllocator().dupe(u8, buf[0..len]);
        try page.commands.append(self.allocator, .{ .raw = raw_copy });
    }

    /// Draw a rectangle with rounded corners.
    /// Parameters: (x, y) is upper-left corner, (w, h) is width/height, r is corner radius.
    /// If radius is 0 or larger than half the smallest dimension, falls back to regular rect.
    /// Coordinates are from top-left origin.
    pub fn drawRoundedRect(self: *Document, x: f64, y: f64, w: f64, h: f64, r: f64, style: DrawStyle) !void {
        // Clamp radius to half of smallest dimension
        const max_r = @min(w, h) / 2.0;
        const radius = @min(r, max_r);

        // If radius is effectively 0, use regular rectangle
        if (radius < 0.01) {
            return self.drawRect(x, y, w, h, style);
        }

        if (self.pages.items.len == 0) return error.NoPage;

        var page = &self.pages.items[self.pages.items.len - 1];
        const page_height = self.page_size.height;

        // Convert from top-left to PDF coordinates (bottom-left origin)
        const pdf_y = page_height - y - h;

        // Kappa constant for approximating quarter circles with cubic Bezier curves
        const KAPPA: f64 = 0.5522847498307936;
        const k = radius * KAPPA;

        var buf: [1024]u8 = undefined;
        var len: usize = 0;

        // Save graphics state
        len += (std.fmt.bufPrint(buf[len..], "q\n", .{}) catch unreachable).len;

        // Graphics state
        len += self.writeGraphicsState(buf[len..], style);

        // Build path: start at top-left corner, after the rounded part
        // Move to start point (top edge, after top-left corner)
        len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} m\n", .{ x + radius, pdf_y + h }) catch unreachable).len;

        // Top edge (left to right)
        len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} l\n", .{ x + w - radius, pdf_y + h }) catch unreachable).len;

        // Top-right corner (curve)
        len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
            x + w - radius + k, pdf_y + h,
            x + w,              pdf_y + h - radius + k,
            x + w,              pdf_y + h - radius,
        }) catch unreachable).len;

        // Right edge (top to bottom)
        len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} l\n", .{ x + w, pdf_y + radius }) catch unreachable).len;

        // Bottom-right corner (curve)
        len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
            x + w,              pdf_y + radius - k,
            x + w - radius + k, pdf_y,
            x + w - radius,     pdf_y,
        }) catch unreachable).len;

        // Bottom edge (right to left)
        len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} l\n", .{ x + radius, pdf_y }) catch unreachable).len;

        // Bottom-left corner (curve)
        len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
            x + radius - k, pdf_y,
            x,              pdf_y + radius - k,
            x,              pdf_y + radius,
        }) catch unreachable).len;

        // Left edge (bottom to top)
        len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} l\n", .{ x, pdf_y + h - radius }) catch unreachable).len;

        // Top-left corner (curve)
        len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
            x,              pdf_y + h - radius + k,
            x + radius - k, pdf_y + h,
            x + radius,     pdf_y + h,
        }) catch unreachable).len;

        // Close path and apply style
        const op = getPathOperator(style);
        len += (std.fmt.bufPrint(buf[len..], "h {s}", .{op}) catch unreachable).len;

        // Restore graphics state
        len += (std.fmt.bufPrint(buf[len..], "Q\n", .{}) catch unreachable).len;

        const raw_copy = try page.pageAllocator().dupe(u8, buf[0..len]);
        try page.commands.append(self.allocator, .{ .raw = raw_copy });
    }

    /// Draw an ellipse using 4 cubic Bezier curves.
    /// Parameters match fpdf2: (x, y) is upper-left of bounding box, (w, h) is full width/height.
    /// Coordinates are from top-left origin.
    pub fn drawEllipse(self: *Document, x: f64, y: f64, w: f64, h: f64, style: DrawStyle) !void {
        if (self.pages.items.len == 0) return error.NoPage;

        var page = &self.pages.items[self.pages.items.len - 1];
        const page_height = self.page_size.height;

        // Calculate center and radii from bounding box
        const rx = w / 2.0;
        const ry = h / 2.0;
        const cx = x + rx; // center x
        const cy = y + ry; // center y (in top-origin coords)

        // Convert center from top-left to PDF coordinates (bottom-left origin)
        const pdf_cy = page_height - cy;

        // Kappa constant for approximating circles with cubic Bezier curves
        // This is (4/3)*tan(pi/8) ≈ 0.5522847498
        const KAPPA: f64 = 0.5522847498307936;

        const kx = rx * KAPPA;
        const ky = ry * KAPPA;

        var buf: [1024]u8 = undefined;
        var len: usize = 0;

        // Save graphics state
        len += (std.fmt.bufPrint(buf[len..], "q\n", .{}) catch unreachable).len;

        // Graphics state
        len += self.writeGraphicsState(buf[len..], style);

        // Start at right-most point (cx + rx, cy)
        len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} m\n", .{ cx + rx, pdf_cy }) catch unreachable).len;

        // Top-right quadrant: from (cx+rx, cy) to (cx, cy+ry)
        len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
            cx + rx,
            pdf_cy + ky,
            cx + kx,
            pdf_cy + ry,
            cx,
            pdf_cy + ry,
        }) catch unreachable).len;

        // Top-left quadrant: from (cx, cy+ry) to (cx-rx, cy)
        len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
            cx - kx,
            pdf_cy + ry,
            cx - rx,
            pdf_cy + ky,
            cx - rx,
            pdf_cy,
        }) catch unreachable).len;

        // Bottom-left quadrant: from (cx-rx, cy) to (cx, cy-ry)
        len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
            cx - rx,
            pdf_cy - ky,
            cx - kx,
            pdf_cy - ry,
            cx,
            pdf_cy - ry,
        }) catch unreachable).len;

        // Bottom-right quadrant: from (cx, cy-ry) to (cx+rx, cy)
        len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c\n", .{
            cx + kx,
            pdf_cy - ry,
            cx + rx,
            pdf_cy - ky,
            cx + rx,
            pdf_cy,
        }) catch unreachable).len;

        // Close path and apply style
        const op = getPathOperator(style);
        @memcpy(buf[len .. len + op.len], op);
        len += op.len;

        // Restore graphics state
        len += (std.fmt.bufPrint(buf[len..], "Q\n", .{}) catch unreachable).len;

        const raw_copy = try page.pageAllocator().dupe(u8, buf[0..len]);
        try page.commands.append(self.allocator, .{ .raw = raw_copy });
    }

    /// Draw a circle (special case of ellipse).
    /// Parameters match fpdf2: (x, y) is the CENTER of the circle, radius is the circle radius.
    /// Coordinates are from top-left origin.
    pub fn drawCircle(self: *Document, x: f64, y: f64, radius: f64, style: DrawStyle) !void {
        // fpdf2 circle(x, y, r) takes center coordinates
        // Convert to bounding box for drawEllipse
        const diameter = radius * 2.0;
        return self.drawEllipse(x - radius, y - radius, diameter, diameter, style);
    }

    /// Draw a closed polygon.
    /// Coordinates are from top-left origin.
    pub fn drawPolygon(self: *Document, points: []const Point, style: DrawStyle) !void {
        if (self.pages.items.len == 0) return error.NoPage;
        if (points.len < 3) return; // Need at least 3 points for a polygon

        var page = &self.pages.items[self.pages.items.len - 1];
        const page_height = self.page_size.height;

        // Calculate required buffer size: ~50 bytes per point + overhead
        const buf_size = 256 + points.len * 64;
        const buf = try page.pageAllocator().alloc(u8, buf_size);
        var len: usize = 0;

        // Save graphics state
        len += (std.fmt.bufPrint(buf[len..], "q\n", .{}) catch unreachable).len;

        // Graphics state
        len += self.writeGraphicsState(buf[len..], style);

        // Move to first point
        const pdf_y0 = page_height - points[0].y;
        len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} m\n", .{ points[0].x, pdf_y0 }) catch unreachable).len;

        // Line to remaining points
        for (points[1..]) |pt| {
            const pdf_y = page_height - pt.y;
            len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} l\n", .{ pt.x, pdf_y }) catch unreachable).len;
        }

        // Close path
        len += (std.fmt.bufPrint(buf[len..], "h ", .{}) catch unreachable).len;

        // Apply style
        const op = getPathOperator(style);
        @memcpy(buf[len .. len + op.len], op);
        len += op.len;

        // Restore graphics state
        len += (std.fmt.bufPrint(buf[len..], "Q\n", .{}) catch unreachable).len;

        // Shrink buffer to actual size (arena allocator)
        const raw_copy = buf[0..len];
        try page.commands.append(self.allocator, .{ .raw = raw_copy });
    }

    /// Create a new path builder.
    pub fn createPath(self: *Document) Path {
        return Path.init(self.allocator);
    }

    /// Create a new styled text builder.
    pub fn createStyledText(self: *Document) StyledText {
        return StyledText.init(self.allocator);
    }

    /// Measure function adapter for StyledText.prepare()
    pub fn styledTextMeasure(text: []const u8, style: TextStyleOptions, ctx: *anyopaque) f64 {
        const doc: *Document = @ptrCast(@alignCast(ctx));
        // Text width doesn't depend on color/decoration, just the font
        _ = style;
        return doc.getTextWidth(text);
    }

    /// Write styled text into a region with alignment support.
    /// Uses Knuth-Plass optimal line breaking when requested.
    pub fn writeStyled(self: *Document, region: *Region, text: *StyledText, opts: ParagraphOptions) !WriteResult {
        if (self.pages.items.len == 0) return error.NoPage;

        const line_height = self.getLineHeightPts();
        const start_cursor_y = region.cursor_y;
        const rect_x = region.x + region.padding.left;
        const rect_y = region.y + region.padding.top + start_cursor_y;
        const rect_width = region.contentWidth();
        const line_width = region.contentWidth();

        // Fast path: single-span, greedy mode, left-aligned - skip preprocessing
        if (opts.line_breaking == .greedy and opts.alignment == .left and text.spans.items.len == 1) {
            const span = text.spans.items[0];
            // Check for soft-hyphens (need preprocessing if present)
            if (std.mem.indexOf(u8, span.text, "\xC2\xAD") == null) {
                return self.writeStyledGreedyFast(region, span.text, span.style, opts, line_height, line_width, start_cursor_y);
            }
        }

        // Prepare text (preprocesses words with width measurement)
        try text.prepare(styledTextMeasure, @ptrCast(self));

        const space_width = self.getTextWidth(" ");
        var lines_written: usize = 0;

        if (text.words.items.len == 0) {
            return .{ .lines_written = 0, .overflow = null, .rect = .{ .x = rect_x, .y = rect_y, .width = rect_width, .height = 0 } };
        }

        // Use optimal or greedy line breaking based on options
        if (opts.line_breaking == .optimal) {
            return self.writeStyledOptimal(region, text, opts, line_height, space_width, line_width, start_cursor_y);
        }

        // Greedy algorithm
        const n = text.words.items.len;
        var word_idx: usize = 0;

        while (word_idx < n) {
            // Check if we have room for another line
            if (region.remainingHeight() < line_height) {
                // Return overflow - remaining words
                return .{
                    .lines_written = lines_written,
                    .overflow = self.getStyledTextFromWord(text, word_idx),
                    .rect = .{ .x = rect_x, .y = rect_y, .width = rect_width, .height = @as(f64, @floatFromInt(lines_written)) * line_height },
                };
            }

            // Collect words that fit on this line
            var current_width: f64 = 0;
            const line_start = word_idx;
            var line_end = word_idx;

            while (line_end < n) {
                const word = text.words.items[line_end];
                const word_with_space = if (line_end > line_start) word.width + space_width else word.width;

                if (current_width + word_with_space > line_width + 0.01) break;

                current_width += word_with_space;
                line_end += 1;

                if (word.force_break) break;
            }

            // Handle case where first word doesn't fit
            if (line_end == line_start and line_start < n) {
                const big_word = text.words.items[line_start];

                // Try to break at soft-hyphen if available
                if (big_word.break_points) |break_points| {
                    const hyphen_width = self.getTextWidth("-");

                    // Find best break point that fits
                    var best_bp: ?styled_text.BreakPoint = null;
                    for (break_points) |bp| {
                        if (bp.width + hyphen_width <= line_width + 0.01) {
                            best_bp = bp;
                        } else {
                            break; // Break points are ordered by position
                        }
                    }

                    if (best_bp) |bp| {
                        // Render prefix + hyphen on this line
                        const span = text.spans.items[big_word.start_span];
                        const prefix_end = bp.offset;
                        const prefix = span.text[big_word.start_offset..prefix_end];

                        // Strip soft-hyphens from prefix for rendering
                        var prefix_buf: [512]u8 = undefined;
                        const clean_prefix = stripSoftHyphensTo(prefix, &prefix_buf);

                        const ascender = self.getFontMetrics().ascender;
                        const y_pos = switch (opts.valign) {
                            .top => region.y + region.padding.top + region.cursor_y + ascender,
                            .middle => region.y + region.padding.top + region.cursor_y + line_height / 2 + ascender / 2,
                            .bottom => region.y + region.padding.top + region.cursor_y + line_height,
                        };

                        const x_pos = region.x + region.padding.left;
                        _ = try self.writeAt(x_pos, y_pos, clean_prefix);
                        _ = try self.writeAt(x_pos + bp.width, y_pos, "-");

                        region.newLine(line_height);
                        lines_written += 1;

                        // Now render the suffix on the next line
                        // Skip the soft-hyphen bytes (2 bytes for UTF-8 soft-hyphen)
                        const suffix_start = prefix_end + 2;
                        if (suffix_start < big_word.end_offset) {
                            const suffix = span.text[suffix_start..big_word.end_offset];
                            var suffix_buf: [512]u8 = undefined;
                            const clean_suffix = stripSoftHyphensTo(suffix, &suffix_buf);

                            if (region.remainingHeight() >= line_height) {
                                const y_pos2 = switch (opts.valign) {
                                    .top => region.y + region.padding.top + region.cursor_y + ascender,
                                    .middle => region.y + region.padding.top + region.cursor_y + line_height / 2 + ascender / 2,
                                    .bottom => region.y + region.padding.top + region.cursor_y + line_height,
                                };
                                _ = try self.writeAt(region.x + region.padding.left, y_pos2, clean_suffix);
                                region.newLine(line_height);
                                lines_written += 1;
                            }
                        }

                        word_idx = line_start + 1;
                        continue;
                    }
                }

                // Try regular hyphen breaking if enabled (only for single-span words)
                if (opts.break_on_hyphens and big_word.start_span == big_word.end_span) {
                    const span = text.spans.items[big_word.start_span];
                    const word_text = span.text[big_word.start_offset..big_word.end_offset];

                    if (self.findHyphenBreak(word_text, line_width)) |break_pos| {
                        // break_pos is position after the hyphen
                        const prefix = word_text[0..break_pos];
                        const suffix = word_text[break_pos..];

                        const ascender = self.getFontMetrics().ascender;
                        const y_pos = switch (opts.valign) {
                            .top => region.y + region.padding.top + region.cursor_y + ascender,
                            .middle => region.y + region.padding.top + region.cursor_y + line_height / 2 + ascender / 2,
                            .bottom => region.y + region.padding.top + region.cursor_y + line_height,
                        };

                        const x_pos = region.x + region.padding.left;
                        _ = try self.writeAt(x_pos, y_pos, prefix);

                        region.newLine(line_height);
                        lines_written += 1;

                        // Render suffix on next line
                        if (suffix.len > 0 and region.remainingHeight() >= line_height) {
                            const y_pos2 = switch (opts.valign) {
                                .top => region.y + region.padding.top + region.cursor_y + ascender,
                                .middle => region.y + region.padding.top + region.cursor_y + line_height / 2 + ascender / 2,
                                .bottom => region.y + region.padding.top + region.cursor_y + line_height,
                            };
                            _ = try self.writeAt(region.x + region.padding.left, y_pos2, suffix);
                            region.newLine(line_height);
                            lines_written += 1;
                        }

                        word_idx = line_start + 1;
                        continue;
                    }
                }

                // Last resort: character-level breaking (only for single-span words)
                // Loop until entire word is consumed
                if (big_word.start_span == big_word.end_span) {
                    const span = text.spans.items[big_word.start_span];
                    var remaining_text = span.text[big_word.start_offset..big_word.end_offset];
                    const ascender = self.getFontMetrics().ascender;
                    var did_break = false;

                    while (remaining_text.len > 0 and region.remainingHeight() >= line_height) {
                        const y_pos = switch (opts.valign) {
                            .top => region.y + region.padding.top + region.cursor_y + ascender,
                            .middle => region.y + region.padding.top + region.cursor_y + line_height / 2 + ascender / 2,
                            .bottom => region.y + region.padding.top + region.cursor_y + line_height,
                        };
                        const x_pos = region.x + region.padding.left;

                        // Check if remaining text fits on line
                        const remaining_width = self.getTextWidth(remaining_text);
                        if (remaining_width <= line_width + 0.01) {
                            // Fits - render it and we're done
                            _ = try self.writeAt(x_pos, y_pos, remaining_text);
                            region.newLine(line_height);
                            lines_written += 1;
                            did_break = true;
                            break;
                        }

                        // Doesn't fit - find break point
                        if (self.findCharacterBreak(remaining_text, line_width)) |break_pos| {
                            const prefix = remaining_text[0..break_pos];
                            _ = try self.writeAt(x_pos, y_pos, prefix);
                            region.newLine(line_height);
                            lines_written += 1;
                            remaining_text = remaining_text[break_pos..];
                            did_break = true;
                        } else {
                            // Can't break (shouldn't happen) - render what we can
                            _ = try self.writeAt(x_pos, y_pos, remaining_text);
                            region.newLine(line_height);
                            lines_written += 1;
                            did_break = true;
                            break;
                        }
                    }

                    if (did_break) {
                        word_idx = line_start + 1;
                        continue;
                    }
                }

                // No break point found - include oversized word as-is
                line_end = line_start + 1;
                current_width = big_word.width;
            }

            // Determine alignment
            const is_last_line = (line_end >= n);
            const has_force_break = line_end > 0 and text.words.items[line_end - 1].force_break;
            const line_alignment = if (opts.alignment == .justify and (is_last_line or has_force_break))
                Align.left
            else
                opts.alignment;

            // Render the line
            try self.renderStyledLine(region, text, line_start, line_end, line_alignment, opts.valign, line_width, space_width, current_width);
            lines_written += 1;

            word_idx = line_end;
        }

        return .{
            .lines_written = lines_written,
            .overflow = null,
            .rect = .{ .x = rect_x, .y = rect_y, .width = rect_width, .height = @as(f64, @floatFromInt(lines_written)) * line_height },
        };
    }

    /// Get remaining text from a word index (for overflow).
    fn getStyledTextFromWord(self: *Document, text: *const StyledText, word_idx: usize) ?[]const u8 {
        _ = self;
        if (word_idx >= text.words.items.len) return null;

        const word = text.words.items[word_idx];
        const span = text.spans.items[word.start_span];
        return span.text[word.start_offset..];
    }

    /// Render a single line of styled text.
    fn renderStyledLine(
        self: *Document,
        region: *Region,
        text: *const StyledText,
        line_start: usize,
        line_end: usize,
        alignment: Align,
        valign: VAlign,
        line_width: f64,
        space_width: f64,
        content_width: f64,
    ) !void {
        const line_height = self.getLineHeightPts();
        const ascender = self.getFontMetrics().ascender;
        const font_size = self.font_size; // needed for decoration scaling

        // Calculate x offset based on alignment
        const slack = line_width - content_width;
        const x_offset: f64 = switch (alignment) {
            .left => 0,
            .center => slack / 2,
            .right => slack,
            .justify => 0,
        };

        // Calculate word spacing for justify
        const word_count = line_end - line_start;
        const actual_space_width = if (alignment == .justify and word_count > 1)
            space_width + slack / @as(f64, @floatFromInt(word_count - 1))
        else
            space_width;

        // Calculate y position based on valign (uses ascender for visible text alignment)
        const y_pos = switch (valign) {
            .top => region.y + region.padding.top + region.cursor_y + ascender,
            .middle => region.y + region.padding.top + region.cursor_y + line_height / 2 + ascender / 2,
            .bottom => region.y + region.padding.top + region.cursor_y + line_height,
        };

        const x_start = region.x + region.padding.left + x_offset;
        var current_x = x_start;

        // Track decoration runs for continuous underlines/strikethroughs
        const DecoRun = struct {
            start_x: f64,
            end_x: f64,
            color: ?Color,
            underline: bool,
            strikethrough: bool,
        };
        var deco_runs: [64]DecoRun = undefined;
        var deco_count: usize = 0;

        // Current decoration state
        var in_underline = false;
        var in_strikethrough = false;
        var deco_start_x: f64 = 0;
        var deco_color: ?Color = null;

        // Helper to end current decoration run
        const endDecoRun = struct {
            fn call(runs: *[64]DecoRun, count: *usize, start_x: f64, end_x: f64, run_color: ?Color, underline: bool, strikethrough: bool) void {
                if (count.* < 64 and (underline or strikethrough)) {
                    runs[count.*] = .{
                        .start_x = start_x,
                        .end_x = end_x,
                        .color = run_color,
                        .underline = underline,
                        .strikethrough = strikethrough,
                    };
                    count.* += 1;
                }
            }
        }.call;

        // Render each word
        for (line_start..line_end) |word_idx| {
            const word = text.words.items[word_idx];

            // Add space before word (except first)
            if (word_idx > line_start) {
                // If we're in a decoration, include the space
                if (!in_underline and !in_strikethrough) {
                    current_x += actual_space_width;
                } else {
                    current_x += actual_space_width;
                }
            }

            // Render word segments (may span multiple styles)
            var span_idx = word.start_span;
            while (span_idx <= word.end_span) : (span_idx += 1) {
                const span = text.spans.items[span_idx];
                const seg_start: usize = if (span_idx == word.start_span) word.start_offset else 0;
                const seg_end: usize = if (span_idx == word.end_span) word.end_offset else span.text.len;

                if (seg_end > seg_start) {
                    const segment = span.text[seg_start..seg_end];
                    const seg_underline = span.style.decoration.underline;
                    const seg_strike = span.style.decoration.strikethrough;

                    // Check if decoration state changed
                    if (seg_underline != in_underline or seg_strike != in_strikethrough) {
                        // End previous run if any
                        if (in_underline or in_strikethrough) {
                            endDecoRun(&deco_runs, &deco_count, deco_start_x, current_x, deco_color, in_underline, in_strikethrough);
                        }
                        // Start new run if needed
                        if (seg_underline or seg_strike) {
                            deco_start_x = current_x;
                            deco_color = span.style.color;
                        }
                        in_underline = seg_underline;
                        in_strikethrough = seg_strike;
                    }

                    // Save and apply color only (decoration handled separately)
                    const saved_color = self.text_color;
                    const saved_decoration = self.text_decoration;
                    self.text_color = span.style.color;
                    self.text_decoration = .none; // Don't draw per-segment

                    // Get segment width and render using writeAt
                    const seg_width = self.getTextWidth(segment);
                    _ = try self.writeAt(current_x, y_pos, segment);
                    current_x += seg_width;

                    // Restore style
                    self.text_color = saved_color;
                    self.text_decoration = saved_decoration;
                }
            }
        }

        // End any remaining decoration run
        if (in_underline or in_strikethrough) {
            endDecoRun(&deco_runs, &deco_count, deco_start_x, current_x, deco_color, in_underline, in_strikethrough);
        }

        // Draw all decoration runs as raw commands
        if (deco_count > 0) {
            var page = &self.pages.items[self.pages.items.len - 1];
            const page_alloc = page.pageAllocator();

            // Get decoration metrics (scale from 1000 units)
            const scale = font_size / 1000.0;
            var underline_pos: f64 = -100;
            var underline_thick: f64 = 50;
            var strikeout_pos: f64 = 250;
            var strikeout_thick: f64 = 50;

            if (self.current_embedded) |emb| {
                underline_pos = @floatFromInt(emb.underline_position);
                underline_thick = @floatFromInt(emb.underline_thickness);
                strikeout_pos = @floatFromInt(emb.strikeout_position);
                strikeout_thick = @floatFromInt(emb.strikeout_size);
            }

            for (deco_runs[0..deco_count]) |run| {
                const width = run.end_x - run.start_x;
                if (width > 0) {
                    var buf: [512]u8 = undefined;
                    var len: usize = 0;

                    // Save graphics state and set color
                    const q_str = "q\n";
                    @memcpy(buf[len..][0..q_str.len], q_str);
                    len += q_str.len;

                    if (run.color) |c| {
                        const rgb = c.toRgb();
                        len += (std.fmt.bufPrint(buf[len..], "{d:.3} {d:.3} {d:.3} rg\n", .{ rgb.r, rgb.g, rgb.b }) catch unreachable).len;
                    } else {
                        const g_str = "0.000 g\n";
                        @memcpy(buf[len..][0..g_str.len], g_str);
                        len += g_str.len;
                    }

                    // Draw underline
                    if (run.underline) {
                        const ul_y = self.page_size.height - y_pos + underline_pos * scale;
                        const h = underline_thick * scale;
                        len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} {d:.2} {d:.2} re f\n", .{ run.start_x, ul_y, width, -h }) catch unreachable).len;
                    }

                    // Draw strikethrough
                    if (run.strikethrough) {
                        const st_y = self.page_size.height - y_pos + strikeout_pos * scale;
                        const h = strikeout_thick * scale;
                        len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} {d:.2} {d:.2} re f\n", .{ run.start_x, st_y, width, -h }) catch unreachable).len;
                    }

                    // Restore graphics state
                    const Q_str = "Q\n";
                    @memcpy(buf[len..][0..Q_str.len], Q_str);
                    len += Q_str.len;

                    const raw_copy = try page_alloc.dupe(u8, buf[0..len]);
                    try page.commands.append(self.allocator, .{ .raw = raw_copy });
                }
            }
        }

        // Advance cursor
        region.cursor_y += line_height;
    }

    /// Fast path for single-span greedy left-aligned text.
    /// Processes inline without preprocessing - similar to writeParagraph.
    fn writeStyledGreedyFast(
        self: *Document,
        region: *Region,
        text: []const u8,
        style: TextStyleOptions,
        opts: ParagraphOptions,
        line_height: f64,
        line_width: f64,
        start_cursor_y: f64,
    ) !WriteResult {
        const space_width = self.getTextWidth(" ");
        const ascender = self.getFontMetrics().ascender;
        var lines_written: usize = 0;
        const rect_x = region.x + region.padding.left;
        const rect_y = region.y + region.padding.top + start_cursor_y;
        const rect_width = region.contentWidth();

        // Apply style
        self.setTextColor(style.color);

        var remaining = text;
        while (remaining.len > 0) {
            if (region.remainingHeight() < line_height) {
                return .{
                    .lines_written = lines_written,
                    .overflow = remaining,
                    .rect = .{ .x = rect_x, .y = rect_y, .width = rect_width, .height = @as(f64, @floatFromInt(lines_written)) * line_height },
                };
            }

            // Build line by collecting words
            var line_end: usize = 0;
            var current_width: f64 = 0;
            var word_start: usize = 0;
            var in_word = false;
            var forced_break = false;

            for (remaining, 0..) |c, i| {
                const is_space = c == ' ' or c == '\t' or c == '\n';

                if (is_space and in_word) {
                    const word = remaining[word_start..i];
                    const word_width = self.getTextWidth(word);

                    if (current_width + word_width <= line_width + 0.01) {
                        current_width += word_width + space_width;
                        line_end = i;
                    } else if (line_end == 0) {
                        // First word doesn't fit - try hyphen break
                        if (opts.break_on_hyphens) {
                            if (self.findHyphenBreak(word, line_width)) |break_pos| {
                                line_end = word_start + break_pos;
                                break;
                            }
                        }
                        // Character-level break as fallback
                        if (self.findCharacterBreak(word, line_width - current_width)) |break_pos| {
                            line_end = word_start + break_pos;
                            break;
                        }
                        line_end = i;
                    } else {
                        break;
                    }

                    in_word = false;

                    if (c == '\n') {
                        forced_break = true;
                        break;
                    }
                } else if (!is_space and !in_word) {
                    word_start = i;
                    in_word = true;
                }
            }

            // Handle final word
            if (in_word and !forced_break) {
                const word = remaining[word_start..];
                const word_width = self.getTextWidth(word);

                if (current_width + word_width <= line_width + 0.01) {
                    line_end = remaining.len;
                } else if (line_end == 0) {
                    if (opts.break_on_hyphens) {
                        if (self.findHyphenBreak(word, line_width)) |break_pos| {
                            line_end = word_start + break_pos;
                        }
                    }
                    if (line_end == 0) {
                        if (self.findCharacterBreak(word, line_width - current_width)) |break_pos| {
                            line_end = word_start + break_pos;
                        }
                    }
                    if (line_end == 0) {
                        line_end = remaining.len;
                    }
                }
            }

            if (line_end == 0) break;

            // Get line text
            var line = remaining[0..line_end];
            while (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) line = line[1..];
            while (line.len > 0 and (line[line.len - 1] == ' ' or line[line.len - 1] == '\t' or line[line.len - 1] == '\n'))
                line = line[0 .. line.len - 1];

            // Render line
            if (line.len > 0) {
                const y_pos = switch (opts.valign) {
                    .top => region.y + region.padding.top + region.cursor_y + ascender,
                    .middle => region.y + region.padding.top + region.cursor_y + line_height / 2 + ascender / 2,
                    .bottom => region.y + region.padding.top + region.cursor_y + line_height,
                };

                _ = try self.writeAt(region.x + region.padding.left, y_pos, line);
                region.newLine(line_height);
                lines_written += 1;
            }

            // Advance past rendered content + whitespace
            remaining = remaining[line_end..];
            while (remaining.len > 0 and (remaining[0] == ' ' or remaining[0] == '\t' or remaining[0] == '\n')) {
                remaining = remaining[1..];
            }
        }

        return .{
            .lines_written = lines_written,
            .overflow = null,
            .rect = .{ .x = rect_x, .y = rect_y, .width = rect_width, .height = @as(f64, @floatFromInt(lines_written)) * line_height },
        };
    }

    /// Write styled text using optimal (Knuth-Plass) line breaking.
    fn writeStyledOptimal(
        self: *Document,
        region: *Region,
        text: *StyledText,
        opts: ParagraphOptions,
        line_height: f64,
        space_width: f64,
        line_width: f64,
        start_cursor_y: f64,
    ) !WriteResult {
        const rect_x = region.x + region.padding.left;
        const rect_y = region.y + region.padding.top + start_cursor_y;
        const rect_width = region.contentWidth();

        // Compute optimal break points using preprocessed word data
        const breaks = try self.computeStyledOptimalBreaks(text, line_width, space_width);
        defer self.allocator.free(breaks);

        if (breaks.len == 0) {
            return .{ .lines_written = 0, .overflow = null, .rect = .{ .x = rect_x, .y = rect_y, .width = rect_width, .height = 0 } };
        }

        var lines_written: usize = 0;
        var line_start: usize = 0;

        for (breaks, 0..) |line_end, line_idx| {
            // Check if we have room
            if (region.remainingHeight() < line_height) {
                return .{
                    .lines_written = lines_written,
                    .overflow = self.getStyledTextFromWord(text, line_start),
                    .rect = .{ .x = rect_x, .y = rect_y, .width = rect_width, .height = @as(f64, @floatFromInt(lines_written)) * line_height },
                };
            }

            // Calculate line content width
            var content_width: f64 = 0;
            for (line_start..line_end) |w| {
                if (w > line_start) content_width += space_width;
                content_width += text.words.items[w].width;
            }

            // Determine alignment
            const is_last_line = (line_idx == breaks.len - 1);
            const has_force_break = line_end > 0 and text.words.items[line_end - 1].force_break;
            const line_alignment = if (opts.alignment == .justify and (is_last_line or has_force_break))
                Align.left
            else
                opts.alignment;

            try self.renderStyledLine(region, text, line_start, line_end, line_alignment, opts.valign, line_width, space_width, content_width);
            lines_written += 1;
            line_start = line_end;
        }

        return .{
            .lines_written = lines_written,
            .overflow = null,
            .rect = .{ .x = rect_x, .y = rect_y, .width = rect_width, .height = @as(f64, @floatFromInt(lines_written)) * line_height },
        };
    }

    /// Compute optimal breaks for styled text using Knuth-Plass.
    fn computeStyledOptimalBreaks(self: *Document, text: *const StyledText, line_width: f64, space_width: f64) ![]usize {
        const n = text.words.items.len;
        if (n == 0) return self.allocator.alloc(usize, 0);

        const INFINITY: f64 = 1e18;

        var dp = try self.allocator.alloc(f64, n + 1);
        defer self.allocator.free(dp);
        var prev = try self.allocator.alloc(usize, n + 1);
        defer self.allocator.free(prev);

        dp[0] = 0;
        prev[0] = 0;

        // For each ending position
        for (1..n + 1) |j| {
            dp[j] = INFINITY;
            prev[j] = 0;

            // Try each starting position
            var line_w: f64 = 0;
            var start_i = j;
            while (start_i > 0) {
                start_i -= 1;
                const word = text.words.items[start_i];

                // Check force break constraint
                if (word.force_break and start_i + 1 < j) break;

                // Add word width
                if (start_i + 1 < j) line_w += space_width;
                line_w += word.width;

                // Line too wide
                if (line_w > line_width + 0.01) break;

                // Compute badness
                const slack = line_width - line_w;
                const is_last_line = (j == n);
                const is_forced = text.words.items[j - 1].force_break;
                const badness = if (is_last_line or is_forced) 0.0 else slack * slack;

                const total = dp[start_i] + badness;
                if (total < dp[j]) {
                    dp[j] = total;
                    prev[j] = start_i;
                }
            }
        }

        // Backtrack
        var breaks = std.ArrayListUnmanaged(usize){};
        errdefer breaks.deinit(self.allocator);

        var pos = n;
        while (pos > 0) {
            try breaks.append(self.allocator, pos);
            pos = prev[pos];
        }

        std.mem.reverse(usize, breaks.items);
        return breaks.toOwnedSlice(self.allocator);
    }

    /// Draw a path with the specified style.
    /// Coordinates are from top-left origin.
    pub fn drawPath(self: *Document, p: *const Path, style: DrawStyle) !void {
        if (self.pages.items.len == 0) return error.NoPage;
        if (p.isEmpty()) return;

        var page = &self.pages.items[self.pages.items.len - 1];
        const page_height = self.page_size.height;

        // Estimate buffer size: ~60 bytes per command + overhead
        const buf_size = 256 + p.commands.items.len * 64;
        const buf = try page.pageAllocator().alloc(u8, buf_size);
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();

        // Save graphics state
        try writer.writeAll("q\n");

        // Graphics state
        var gs_buf: [256]u8 = undefined;
        const gs_len = self.writeGraphicsState(&gs_buf, style);
        try writer.writeAll(gs_buf[0..gs_len]);

        // Path commands
        try p.toPdfContent(page_height, writer);

        // Apply style
        const op = getPathOperator(style);
        try writer.writeAll(op);

        // Restore graphics state
        try writer.writeAll("Q\n");

        const len = fbs.pos;
        try page.commands.append(self.allocator, .{ .raw = buf[0..len] });
    }

    /// Add a linear gradient to the document and return its index.
    pub fn addLinearGradient(self: *Document, grad: LinearGradient) !usize {
        const idx = self.gradients.items.len;
        try self.gradients.append(self.allocator, .{ .linear = grad });
        return idx;
    }

    /// Add a radial gradient to the document and return its index.
    pub fn addRadialGradient(self: *Document, grad: RadialGradient) !usize {
        const idx = self.gradients.items.len;
        try self.gradients.append(self.allocator, .{ .radial = grad });
        return idx;
    }

    /// Fill a rectangle with a gradient.
    /// The gradient index must have been obtained from addLinearGradient or addRadialGradient.
    pub fn fillRectGradient(self: *Document, x: f64, y: f64, w: f64, h: f64, gradient_idx: usize) !void {
        if (self.pages.items.len == 0) return error.NoPage;
        if (gradient_idx >= self.gradients.items.len) return error.InvalidGradient;

        var page = &self.pages.items[self.pages.items.len - 1];
        const page_height = self.page_size.height;

        // Track that this page uses gradients
        try page.used_gradients.put(self.allocator, gradient_idx, {});

        // Convert from top-left to PDF coordinates
        const pdf_y = page_height - y - h;

        var buf: [256]u8 = undefined;
        var len: usize = 0;

        // Save graphics state, set clip path, paint shading, restore
        len += (std.fmt.bufPrint(buf[len..], "q\n", .{}) catch unreachable).len;
        len += (std.fmt.bufPrint(buf[len..], "{d:.2} {d:.2} {d:.2} {d:.2} re W n\n", .{ x, pdf_y, w, h }) catch unreachable).len;
        len += (std.fmt.bufPrint(buf[len..], "/{s} sh\n", .{shadingResourceName(gradient_idx)}) catch unreachable).len;
        len += (std.fmt.bufPrint(buf[len..], "Q\n", .{}) catch unreachable).len;

        const raw_copy = try page.pageAllocator().dupe(u8, buf[0..len]);
        try page.commands.append(self.allocator, .{ .raw = raw_copy });
    }

    /// Render deferred commands to page content bytes
    /// Called after subsetting so glyph IDs are properly remapped
    pub fn renderPageCommands(self: *Document, page: *Page) !void {
        var cw = page.writer(self.allocator);

        for (page.commands.items) |cmd| {
            switch (cmd) {
                .text => |t| {
                    // Begin text block
                    try cw.append("BT\n");
                    // Set text color
                    try t.text_color.writeFill(&cw);

                    switch (t.font) {
                        .embedded => |emb| {
                            const idx = self.getEmbeddedFontIndex(emb) orelse continue;
                            try cw.print("/E{d} {d:.2} Tf\n", .{ idx + 1, t.font_size });

                            if (t.char_spacing != 0) {
                                try cw.print("{d:.2} Tc\n", .{t.char_spacing});
                            }
                            // Always emit Tw to ensure correct word spacing (state persists across text blocks)
                            try cw.print("{d:.2} Tw\n", .{t.word_spacing});

                            if (emb.encoding == .identity) {
                                // CID mode: output with ligatures, kerning, and mark positioning
                                // Pass absolute position for Tm-based mark positioning
                                // Use cached glyphs if available (avoids duplicate OpenType shaping)
                                _ = try self.renderCIDTextWithKerning(&cw, emb, t.text_data, t.cached_glyphs, t.font_size, t.x, t.y);
                            } else {
                                try cw.print("{d:.2} {d:.2} Td\n", .{ t.x, t.y });
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
                            // Always emit Tw to ensure correct word spacing (state persists across text blocks)
                            try cw.print("{d:.2} Tw\n", .{t.word_spacing});

                            try cw.print("{d:.2} {d:.2} Td\n", .{ t.x, t.y });
                            try cw.append("(");
                            try cw.appendEscaped(t.text_data);
                            try cw.append(") Tj\n");
                        },
                    }

                    try cw.append("ET\n");

                    // Draw text decorations (underline/strikethrough)
                    // These must be outside the text block (BT/ET)
                    if (t.underline or t.strikethrough) {
                        try self.drawTextDecorations(&cw, &t);
                    }
                },
                .raw => |data| {
                    try cw.append(data);
                },
            }
        }
    }

    /// Draw underline and/or strikethrough decorations for text.
    /// Called after text is rendered, outside the BT/ET block.
    fn drawTextDecorations(self: *Document, cw: *ContentWriter, t: *const TextCommand) !void {
        _ = self;
        // Get decoration metrics based on font type
        var underline_pos: f64 = -100; // Default in 1000 units
        var underline_thick: f64 = 50;
        var strikeout_pos: f64 = 250;
        var strikeout_thick: f64 = 50;

        switch (t.font) {
            .embedded => |emb| {
                underline_pos = @floatFromInt(emb.underline_position);
                underline_thick = @floatFromInt(emb.underline_thickness);
                strikeout_pos = @floatFromInt(emb.strikeout_position);
                strikeout_thick = @floatFromInt(emb.strikeout_size);
            },
            .standard => {
                // Standard fonts use fixed decoration metrics (from fpdf2)
                underline_pos = -100;
                underline_thick = 50;
                strikeout_pos = 250;
                strikeout_thick = 50;
            },
        }

        // Scale from 1000 units to points
        const scale = t.font_size / 1000.0;
        const x = t.x;
        const w = t.text_width;

        // Save graphics state, set stroke color to text color
        try cw.append("q\n");
        try t.text_color.writeFill(cw);

        if (t.underline) {
            // Position: baseline + underline_position (negative = below)
            const y = t.y + underline_pos * scale;
            const h = underline_thick * scale;
            // PDF rectangle: x y width height re f (filled)
            try cw.print("{d:.2} {d:.2} {d:.2} {d:.2} re f\n", .{ x, y, w, -h });
        }

        if (t.strikethrough) {
            // Position: baseline + strikeout_position (positive = above)
            const y = t.y + strikeout_pos * scale;
            const h = strikeout_thick * scale;
            // PDF rectangle with negative height extends downward
            try cw.print("{d:.2} {d:.2} {d:.2} {d:.2} re f\n", .{ x, y, w, -h });
        }

        // Restore graphics state
        try cw.append("Q\n");
    }

    /// Output timing information for performance analysis.
    pub const OutputTiming = struct {
        subset_ms: i64 = 0,
        render_ms: i64 = 0,
        font_write_ms: i64 = 0,
        page_write_ms: i64 = 0,
        finish_ms: i64 = 0,
    };

    /// Last output timing (for performance debugging).
    pub var last_output_timing: OutputTiming = .{};

    /// Generate PDF output
    pub fn output(self: *Document) ![]u8 {
        last_output_timing = .{};

        var w = Writer.init(self.allocator);
        defer w.deinit();

        // Reserve object IDs:
        // 1: Catalog
        // 2: Pages root
        // 3+: Standard fonts (one per used font)
        // Then: Embedded fonts (4-5 objects each)
        // Then: Pages (2 objects each: page dict + content stream)
        const catalog_id: ObjectId = 1;
        const pages_root_id: ObjectId = 2;

        // Build list of used standard fonts
        var font_list = std.ArrayListUnmanaged(StandardFont){};
        defer font_list.deinit(self.allocator);
        var font_iter = self.used_fonts.keyIterator();
        while (font_iter.next()) |font| {
            try font_list.append(self.allocator, font.*);
        }

        const first_std_font_id: ObjectId = 3;
        var next_id: ObjectId = first_std_font_id + @as(ObjectId, @intCast(font_list.items.len));

        // Reserve IDs for embedded fonts
        // CID fonts need: Type0 + CIDFont + FontDescriptor + FontFile + ToUnicode = 5 objects
        // WinAnsi fonts need: Font + FontDescriptor + FontFile + ToUnicode = 4 objects
        var emb_font_base_ids = std.ArrayListUnmanaged(ObjectId){};
        defer emb_font_base_ids.deinit(self.allocator);
        for (self.embedded_fonts.items) |emb_font| {
            try emb_font_base_ids.append(self.allocator, next_id);
            if (emb_font.encoding == .identity) {
                next_id += 5; // CID font objects
            } else {
                next_id += 4; // WinAnsi font objects
            }
        }

        // Reserve IDs for images
        // Each image needs: XObject stream (1 object)
        // PNG with alpha needs: +1 for SMask stream
        // Images with ICC profile need: +1 for ICC profile stream
        var image_base_ids = std.ArrayListUnmanaged(ObjectId){};
        defer image_base_ids.deinit(self.allocator);
        var image_smask_ids = std.ArrayListUnmanaged(?ObjectId){};
        defer image_smask_ids.deinit(self.allocator);
        var image_icc_ids = std.ArrayListUnmanaged(?ObjectId){};
        defer image_icc_ids.deinit(self.allocator);
        for (self.loaded_images.items) |image| {
            try image_base_ids.append(self.allocator, next_id);
            next_id += 1;
            if (image.alpha_data != null) {
                try image_smask_ids.append(self.allocator, next_id);
                next_id += 1;
            } else {
                try image_smask_ids.append(self.allocator, null);
            }
            if (image.icc_profile != null) {
                try image_icc_ids.append(self.allocator, next_id);
                next_id += 1;
            } else {
                try image_icc_ids.append(self.allocator, null);
            }
        }

        // Reserve IDs for SVGs (Form XObjects - 1 object each)
        var svg_base_ids = std.ArrayListUnmanaged(ObjectId){};
        defer svg_base_ids.deinit(self.allocator);
        for (self.loaded_svgs.items) |_| {
            try svg_base_ids.append(self.allocator, next_id);
            next_id += 1;
        }

        // Reserve IDs for outlines (1 root + N items)
        var outlines_root_id: ?ObjectId = null;
        if (self.outlines.items.len > 0) {
            outlines_root_id = next_id;
            next_id += 1; // root object
            // Assign object IDs to each outline item
            for (self.outlines.items) |outline| {
                outline.object_id = next_id;
                next_id += 1;
            }
        }

        // Reserve ID for page labels (1 object with number tree)
        var page_labels_id: ?ObjectId = null;
        if (self.page_labels.items.len > 0) {
            page_labels_id = next_id;
            next_id += 1;
        }

        const first_page_id = next_id;

        // Write header
        try w.writeHeader();

        // Write catalog
        try w.beginObject(catalog_id);
        var catalog_dict = Dict.init(self.allocator);
        defer catalog_dict.deinit();
        try catalog_dict.put("Type", Value.name("Catalog"));
        try catalog_dict.put("Pages", Value.ref(.{ .id = pages_root_id }));
        if (outlines_root_id) |id| {
            try catalog_dict.put("Outlines", Value.ref(.{ .id = id }));
        }
        if (page_labels_id) |id| {
            try catalog_dict.put("PageLabels", Value.ref(.{ .id = id }));
        }
        try w.writeDict(catalog_dict);
        try w.endObject();

        // Write pages root
        try w.beginObject(pages_root_id);
        var pages_dict = Dict.init(self.allocator);
        defer pages_dict.deinit();
        try pages_dict.put("Type", Value.name("Pages"));
        try pages_dict.put("Count", Value.int(@intCast(self.pages.items.len)));

        // Build Kids array (accounting for annotations per page)
        var kids = Array.init(self.allocator);
        defer kids.deinit();
        var page_id = first_page_id;
        for (self.pages.items) |page| {
            try kids.append(Value.ref(.{ .id = page_id }));
            // Each page uses: page dict + content stream + annotation objects
            page_id += 2 + @as(ObjectId, @intCast(page.annotations.items.len));
        }
        try pages_dict.put("Kids", .{ .array_val = &kids });

        try w.writeDict(pages_dict);
        try w.endObject();

        // Write standard font dictionaries
        for (font_list.items, 0..) |font, idx| {
            const font_id = first_std_font_id + @as(ObjectId, @intCast(idx));
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
        const subset_start = std.time.milliTimestamp();
        for (self.embedded_fonts.items) |emb_font| {
            try emb_font.generateSubset();
        }
        last_output_timing.subset_ms = std.time.milliTimestamp() - subset_start;

        // Render deferred commands to content bytes (AFTER subsetting so glyph IDs are remapped)
        const render_start = std.time.milliTimestamp();
        for (self.pages.items) |*page| {
            try self.renderPageCommands(page);
        }
        last_output_timing.render_ms = std.time.milliTimestamp() - render_start;

        // Write embedded font objects
        const font_write_start = std.time.milliTimestamp();
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
                    try w.writeStreamCompressed(&stream_dict, font_data);
                }
                try w.endObject();

                // 5. ToUnicode CMap stream
                try w.beginObject(tounicode_id);
                {
                    var tounicode_dict = Dict.init(self.allocator);
                    defer tounicode_dict.deinit();
                    try w.writeStreamCompressed(&tounicode_dict, tounicode_cmap);
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
                    try w.writeStreamCompressed(&stream_dict, font_data);
                }
                try w.endObject();

                // 4. ToUnicode CMap stream
                try w.beginObject(tounicode_id);
                {
                    var tounicode_dict = Dict.init(self.allocator);
                    defer tounicode_dict.deinit();
                    try w.writeStreamCompressed(&tounicode_dict, tounicode_cmap);
                }
                try w.endObject();
            }
        }
        last_output_timing.font_write_ms = std.time.milliTimestamp() - font_write_start;

        // Write image XObjects
        for (self.loaded_images.items, 0..) |image, i| {
            const img_id = image_base_ids.items[i];
            const smask_id = image_smask_ids.items[i];
            const icc_id = image_icc_ids.items[i];

            // Write ICC profile stream if present
            if (icc_id) |iid| {
                try w.beginObject(iid);
                var icc_dict = Dict.init(self.allocator);
                defer icc_dict.deinit();
                // N = number of color components (3 for RGB, 1 for Gray, 4 for CMYK)
                try icc_dict.put("N", Value.int(image.color_space.components()));
                try icc_dict.put("Alternate", Value.name(image.color_space.pdfName()));
                try w.writeStreamCompressed(&icc_dict, image.icc_profile.?);
                try w.endObject();
            }

            // Write SMask first if present (PNG with alpha)
            if (smask_id) |sid| {
                try w.beginObject(sid);
                var smask_dict = Dict.init(self.allocator);
                defer smask_dict.deinit();
                try smask_dict.put("Type", Value.name("XObject"));
                try smask_dict.put("Subtype", Value.name("Image"));
                try smask_dict.put("Width", Value.int(@intCast(image.width)));
                try smask_dict.put("Height", Value.int(@intCast(image.height)));
                try smask_dict.put("ColorSpace", Value.name("DeviceGray"));
                try smask_dict.put("BitsPerComponent", Value.int(8));
                // Alpha data is already compressed
                try smask_dict.put("Filter", Value.name("FlateDecode"));
                try w.writeStream(&smask_dict, image.alpha_data.?);
                try w.endObject();
            }

            // Write main image XObject
            try w.beginObject(img_id);
            var img_dict = Dict.init(self.allocator);
            defer img_dict.deinit();
            try img_dict.put("Type", Value.name("XObject"));
            try img_dict.put("Subtype", Value.name("Image"));
            try img_dict.put("Width", Value.int(@intCast(image.width)));
            try img_dict.put("Height", Value.int(@intCast(image.height)));

            // Color space array for ICCBased (must stay in scope until writeStream)
            var cs_array = Array.init(self.allocator);
            defer cs_array.deinit();

            // Color space: use ICCBased if we have an ICC profile, otherwise use device color space
            if (icc_id) |iid| {
                // ICCBased color space: [/ICCBased <ref>]
                try cs_array.append(Value.name("ICCBased"));
                try cs_array.append(Value.ref(.{ .id = iid }));
                try img_dict.put("ColorSpace", .{ .array_val = &cs_array });
            } else {
                try img_dict.put("ColorSpace", Value.name(image.color_space.pdfName()));
            }
            try img_dict.put("BitsPerComponent", Value.int(image.bits_per_component));

            // Filter and data handling
            switch (image.format) {
                .jpeg => {
                    try img_dict.put("Filter", Value.name("DCTDecode"));
                    // JPEG data is embedded directly
                    try w.writeStream(&img_dict, image.data);
                },
                .png => {
                    try img_dict.put("Filter", Value.name("FlateDecode"));
                    // PNG data is already re-compressed
                    if (smask_id) |sid| {
                        try img_dict.put("SMask", Value.ref(.{ .id = sid }));
                    }
                    try w.writeStream(&img_dict, image.data);
                },
            }
            try w.endObject();
        }

        // Write SVG Form XObjects
        for (self.loaded_svgs.items, 0..) |s, i| {
            const svg_id = svg_base_ids.items[i];

            // Generate PDF content stream from SVG
            const svg_content = try s.toPdfContent(self.allocator);
            defer self.allocator.free(svg_content);

            try w.beginObject(svg_id);
            var form_dict = Dict.init(self.allocator);
            defer form_dict.deinit();
            try form_dict.put("Type", Value.name("XObject"));
            try form_dict.put("Subtype", Value.name("Form"));

            // BBox: [0 0 width height]
            var bbox = Array.init(self.allocator);
            defer bbox.deinit();
            try bbox.append(Value.int(0));
            try bbox.append(Value.int(0));
            try bbox.append(Value.real(s.width));
            try bbox.append(Value.real(s.height));
            try form_dict.put("BBox", .{ .array_val = &bbox });

            // Build resources dictionary (may include ExtGState, Font, or both)
            const has_transparency = s.opacity_states.items.len > 0;
            const has_text = s.used_fonts.items.len > 0;

            if (has_transparency or has_text) {
                var resources = Dict.init(self.allocator);
                defer resources.deinit();

                // Add ExtGState for transparency
                var extgstate = Dict.init(self.allocator);
                defer extgstate.deinit();
                var gs_dicts: []Dict = &.{};
                defer {
                    for (gs_dicts) |*d| d.deinit();
                    if (gs_dicts.len > 0) self.allocator.free(gs_dicts);
                }

                if (has_transparency) {
                    gs_dicts = try self.allocator.alloc(Dict, s.opacity_states.items.len);
                    for (s.opacity_states.items, 0..) |state, idx| {
                        gs_dicts[idx] = Dict.init(self.allocator);
                        try gs_dicts[idx].put("Type", Value.name("ExtGState"));
                        try gs_dicts[idx].put("ca", Value.real(state.fill_opacity));
                        try gs_dicts[idx].put("CA", Value.real(state.stroke_opacity));
                        try extgstate.put(extgstateResourceName(idx), .{ .dict_val = &gs_dicts[idx] });
                    }
                    try resources.put("ExtGState", .{ .dict_val = &extgstate });
                }

                // Add Font resources for SVG text elements
                var font_res = Dict.init(self.allocator);
                defer font_res.deinit();
                var font_dicts: []Dict = &.{};
                defer {
                    for (font_dicts) |*d| d.deinit();
                    if (font_dicts.len > 0) self.allocator.free(font_dicts);
                }

                if (has_text) {
                    // Static font names for Form XObject resources (F1-F16)
                    const svg_font_names = [_][]const u8{
                        "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8",
                        "F9", "F10", "F11", "F12", "F13", "F14", "F15", "F16",
                    };

                    font_dicts = try self.allocator.alloc(Dict, s.used_fonts.items.len);
                    for (s.used_fonts.items, 0..) |used_font, idx| {
                        // Create inline font dict: << /Type /Font /Subtype /Type1 /BaseFont /FontName >>
                        font_dicts[idx] = Dict.init(self.allocator);
                        try font_dicts[idx].put("Type", Value.name("Font"));
                        try font_dicts[idx].put("Subtype", Value.name("Type1"));
                        try font_dicts[idx].put("BaseFont", Value.name(used_font.toPdfName()));

                        // Font name: /F1, /F2, etc. (use static names to avoid buffer reuse)
                        const font_name = if (idx < svg_font_names.len) svg_font_names[idx] else "F99";
                        try font_res.put(font_name, .{ .dict_val = &font_dicts[idx] });
                    }
                    try resources.put("Font", .{ .dict_val = &font_res });
                }

                try form_dict.put("Resources", .{ .dict_val = &resources });
                try w.writeStreamCompressed(&form_dict, svg_content);
            } else {
                // No resources needed
                try w.writeStreamCompressed(&form_dict, svg_content);
            }
            try w.endObject();
        }

        // Write each page
        const page_write_start = std.time.milliTimestamp();
        next_id = first_page_id;
        for (self.pages.items, 0..) |page, page_idx| {
            const pg_id = next_id;
            const content_id = next_id + 1;
            const first_annot_id = next_id + 2;
            const annot_count = page.annotations.items.len;
            next_id += 2 + @as(ObjectId, @intCast(annot_count));
            _ = page_idx; // Used for internal link destinations

            // Page dictionary
            try w.beginObject(pg_id);
            var page_dict = Dict.init(self.allocator);
            defer page_dict.deinit();
            try page_dict.put("Type", Value.name("Page"));
            try page_dict.put("Parent", Value.ref(.{ .id = pages_root_id }));

            // MediaBox (use page's own size)
            var media_box = Array.init(self.allocator);
            defer media_box.deinit();
            try media_box.append(Value.int(0));
            try media_box.append(Value.int(0));
            try media_box.append(Value.real(page.size.width));
            try media_box.append(Value.real(page.size.height));
            try page_dict.put("MediaBox", .{ .array_val = &media_box });

            try page_dict.put("Contents", Value.ref(.{ .id = content_id }));

            // Font resources (must stay in scope until writeDict completes)
            var font_res = Dict.init(self.allocator);
            defer font_res.deinit();
            var xobject_res = Dict.init(self.allocator);
            defer xobject_res.deinit();
            var shading_res = Dict.init(self.allocator);
            defer shading_res.deinit();
            var shading_strs = std.ArrayListUnmanaged([]u8){};
            defer {
                for (shading_strs.items) |s| self.allocator.free(s);
                shading_strs.deinit(self.allocator);
            }
            var resources = Dict.init(self.allocator);
            defer resources.deinit();

            var has_fonts = false;
            var has_xobjects = false;

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

            // Add image XObject resources
            for (page.used_images.items) |img| {
                // Find index of this image
                for (self.loaded_images.items, 0..) |doc_img, idx| {
                    if (doc_img == img) {
                        const img_obj_id = image_base_ids.items[idx];
                        try xobject_res.put(imageResourceName(idx), Value.ref(.{ .id = img_obj_id }));
                        has_xobjects = true;
                        break;
                    }
                }
            }

            // Add SVG XObject resources
            for (page.used_svgs.items) |s| {
                // Find index of this SVG
                for (self.loaded_svgs.items, 0..) |doc_svg, idx| {
                    if (doc_svg == s) {
                        const svg_obj_id = svg_base_ids.items[idx];
                        try xobject_res.put(svgResourceName(idx), Value.ref(.{ .id = svg_obj_id }));
                        has_xobjects = true;
                        break;
                    }
                }
            }

            // Check if page uses shadings
            const has_shadings = page.used_gradients.count() > 0;

            if (has_fonts or has_xobjects or has_shadings) {
                if (has_fonts) {
                    try resources.put("Font", .{ .dict_val = &font_res });
                }
                if (has_xobjects) {
                    try resources.put("XObject", .{ .dict_val = &xobject_res });
                }
                if (has_shadings) {
                    // Write inline shading dictionaries
                    var iter = page.used_gradients.keyIterator();
                    while (iter.next()) |grad_idx_ptr| {
                        const grad_idx = grad_idx_ptr.*;
                        if (grad_idx < self.gradients.items.len) {
                            const grad_def = self.gradients.items[grad_idx];

                            // Build shading dict with inline function
                            var shading_buf: [2048]u8 = undefined;
                            var shading_fbs = std.io.fixedBufferStream(&shading_buf);
                            const shading_writer = shading_fbs.writer();

                            switch (grad_def) {
                                .linear => |lg| {
                                    const pdf_y0 = self.page_size.height - lg.y0;
                                    const pdf_y1 = self.page_size.height - lg.y1;
                                    try shading_writer.print("<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [{d:.2} {d:.2} {d:.2} {d:.2}] /Extend [{s} {s}] /Function ", .{
                                        lg.x0,
                                        pdf_y0,
                                        lg.x1,
                                        pdf_y1,
                                        if (lg.extend_before) "true" else "false",
                                        if (lg.extend_after) "true" else "false",
                                    });
                                    try gradient.writeFunctionDict(lg.stops, shading_writer);
                                    try shading_writer.writeAll(" >>");
                                },
                                .radial => |rg| {
                                    const pdf_y0 = self.page_size.height - rg.y0;
                                    const pdf_y1 = self.page_size.height - rg.y1;
                                    try shading_writer.print("<< /ShadingType 3 /ColorSpace /DeviceRGB /Coords [{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2}] /Extend [{s} {s}] /Function ", .{
                                        rg.x0,
                                        pdf_y0,
                                        rg.r0,
                                        rg.x1,
                                        pdf_y1,
                                        rg.r1,
                                        if (rg.extend_before) "true" else "false",
                                        if (rg.extend_after) "true" else "false",
                                    });
                                    try gradient.writeFunctionDict(rg.stops, shading_writer);
                                    try shading_writer.writeAll(" >>");
                                },
                            }

                            const shading_name = shadingResourceName(grad_idx);
                            // Dupe string since stack buffer goes out of scope
                            const shading_str = try self.allocator.dupe(u8, shading_fbs.getWritten());
                            try shading_strs.append(self.allocator, shading_str);
                            try shading_res.put(shading_name, Value.literal(shading_str));
                        }
                    }
                    try resources.put("Shading", .{ .dict_val = &shading_res });
                }
                try page_dict.put("Resources", .{ .dict_val = &resources });
            }

            // Add annotations array if page has links
            var annots_array = Array.init(self.allocator);
            defer annots_array.deinit();
            if (annot_count > 0) {
                for (0..annot_count) |i| {
                    const annot_id = first_annot_id + @as(ObjectId, @intCast(i));
                    try annots_array.append(Value.ref(.{ .id = annot_id }));
                }
                try page_dict.put("Annots", .{ .array_val = &annots_array });
            }

            try w.writeDict(page_dict);
            try w.endObject();

            // Content stream (compressed)
            try w.beginObject(content_id);
            var content_dict = Dict.init(self.allocator);
            defer content_dict.deinit();
            try w.writeStreamCompressed(&content_dict, page.content.items);
            try w.endObject();

            // Write annotation objects
            for (page.annotations.items, 0..) |annot, i| {
                const annot_id = first_annot_id + @as(ObjectId, @intCast(i));
                try w.beginObject(annot_id);
                var annot_dict = Dict.init(self.allocator);
                defer annot_dict.deinit();

                try annot_dict.put("Type", Value.name("Annot"));
                try annot_dict.put("Subtype", Value.name("Link"));

                // Rect: [x1 y1 x2 y2] in PDF coordinates (y from bottom)
                const rect = switch (annot) {
                    .internal => |a| a.rect,
                    .external => |a| a.rect,
                };
                var rect_array = Array.init(self.allocator);
                defer rect_array.deinit();
                // Convert from top-down to bottom-up coordinates
                const y1 = page.size.height - rect.y - rect.height;
                const y2 = page.size.height - rect.y;
                try rect_array.append(Value.real(rect.x));
                try rect_array.append(Value.real(y1));
                try rect_array.append(Value.real(rect.x + rect.width));
                try rect_array.append(Value.real(y2));
                try annot_dict.put("Rect", .{ .array_val = &rect_array });

                // Border: [0 0 0] = no visible border
                var border_array = Array.init(self.allocator);
                defer border_array.deinit();
                try border_array.append(Value.int(0));
                try border_array.append(Value.int(0));
                try border_array.append(Value.int(0));
                try annot_dict.put("Border", .{ .array_val = &border_array });

                // Destination array or action dict (must stay in scope until writeDict)
                var dest_array = Array.init(self.allocator);
                defer dest_array.deinit();
                var action_dict = Dict.init(self.allocator);
                defer action_dict.deinit();

                switch (annot) {
                    .internal => |a| {
                        // /Dest [page_ref /XYZ left top zoom]
                        // Get the page object ID for the destination
                        var dest_page_id = first_page_id;
                        for (self.pages.items[0..a.dest.page_index]) |p| {
                            dest_page_id += 2 + @as(ObjectId, @intCast(p.annotations.items.len));
                        }
                        const dest_page_size = self.pages.items[a.dest.page_index].size;
                        try dest_array.append(Value.ref(.{ .id = dest_page_id }));
                        try dest_array.append(Value.name("XYZ"));
                        try dest_array.append(Value.int(0)); // left (null = unchanged)
                        // Convert y from top-down to bottom-up
                        try dest_array.append(Value.real(dest_page_size.height - a.dest.y));
                        try dest_array.append(Value.int(0)); // zoom (0 = unchanged)
                        try annot_dict.put("Dest", .{ .array_val = &dest_array });
                    },
                    .external => |a| {
                        // /A << /S /URI /URI (url) >>
                        try action_dict.put("S", Value.name("URI"));
                        try action_dict.put("URI", Value.string(a.url));
                        try annot_dict.put("A", .{ .dict_val = &action_dict });
                    },
                }

                try w.writeDict(annot_dict);
                try w.endObject();
            }
        }
        last_output_timing.page_write_ms = std.time.milliTimestamp() - page_write_start;

        // Write Info dictionary if metadata is set
        var info_id: ?ObjectId = null;
        if (self.metadata.hasAnyField()) {
            info_id = next_id;
            next_id += 1;

            try w.beginObject(info_id.?);
            var info_dict = Dict.init(self.allocator);
            defer info_dict.deinit();

            if (self.metadata.title) |title| {
                try info_dict.put("Title", Value.string(title));
            }
            if (self.metadata.author) |author| {
                try info_dict.put("Author", Value.string(author));
            }
            if (self.metadata.subject) |subject| {
                try info_dict.put("Subject", Value.string(subject));
            }
            if (self.metadata.keywords) |keywords| {
                try info_dict.put("Keywords", Value.string(keywords));
            }
            if (self.metadata.creator) |creator| {
                try info_dict.put("Creator", Value.string(creator));
            }
            if (self.metadata.producer) |producer| {
                try info_dict.put("Producer", Value.string(producer));
            }

            // Auto-generate dates if not explicitly set
            var date_buf: [24]u8 = undefined; // "D:YYYYMMDDHHmmSS+00'00'"
            const date_str = if (self.metadata.creation_date) |date|
                date
            else
                formatPdfDate(&date_buf);

            try info_dict.put("CreationDate", Value.string(date_str));

            const mod_date_str = if (self.metadata.mod_date) |date|
                date
            else
                date_str; // Same as creation date if not set

            try info_dict.put("ModDate", Value.string(mod_date_str));

            try w.writeDict(info_dict);
            try w.endObject();
        }

        // Write outlines if present
        if (outlines_root_id) |root_id| {
            // Find first and last top-level outline items
            var first_top_level: ?*Outline = null;
            var last_top_level: ?*Outline = null;
            var total_count: i32 = 0;

            for (self.outlines.items) |outline| {
                if (outline.parent == null) {
                    if (first_top_level == null) {
                        first_top_level = outline;
                    }
                    last_top_level = outline;
                }
                total_count += 1;
            }

            // Write outlines root
            try w.beginObject(root_id);
            var outlines_dict = Dict.init(self.allocator);
            defer outlines_dict.deinit();
            try outlines_dict.put("Type", Value.name("Outlines"));
            if (first_top_level) |first| {
                try outlines_dict.put("First", Value.ref(.{ .id = first.object_id }));
            }
            if (last_top_level) |last| {
                try outlines_dict.put("Last", Value.ref(.{ .id = last.object_id }));
            }
            try outlines_dict.put("Count", Value.int(total_count));
            try w.writeDict(outlines_dict);
            try w.endObject();

            // Write each outline item
            for (self.outlines.items) |outline| {
                try w.beginObject(outline.object_id);
                var item_dict = Dict.init(self.allocator);
                defer item_dict.deinit();

                try item_dict.put("Title", Value.string(outline.title));

                // Parent reference
                if (outline.parent) |parent| {
                    try item_dict.put("Parent", Value.ref(.{ .id = parent.object_id }));
                } else {
                    try item_dict.put("Parent", Value.ref(.{ .id = root_id }));
                }

                // Sibling references
                if (outline.prev) |prev| {
                    try item_dict.put("Prev", Value.ref(.{ .id = prev.object_id }));
                }
                if (outline.next) |nx| {
                    try item_dict.put("Next", Value.ref(.{ .id = nx.object_id }));
                }

                // Child references
                if (outline.first_child) |first| {
                    try item_dict.put("First", Value.ref(.{ .id = first.object_id }));
                }
                if (outline.last_child) |last| {
                    try item_dict.put("Last", Value.ref(.{ .id = last.object_id }));
                }

                // Count (positive = expanded, negative = collapsed)
                if (outline.count != 0) {
                    try item_dict.put("Count", Value.int(outline.count));
                }

                // Destination: [page_ref /XYZ left top zoom]
                var dest_array = Array.init(self.allocator);
                defer dest_array.deinit();
                // Get the page object ID for the destination
                var dest_page_id = first_page_id;
                for (self.pages.items[0..outline.dest.page_index]) |p| {
                    dest_page_id += 2 + @as(ObjectId, @intCast(p.annotations.items.len));
                }
                const dest_page_size = self.pages.items[outline.dest.page_index].size;
                try dest_array.append(Value.ref(.{ .id = dest_page_id }));
                try dest_array.append(Value.name("XYZ"));
                try dest_array.append(Value.int(0)); // left
                try dest_array.append(Value.real(dest_page_size.height - outline.dest.y));
                try dest_array.append(Value.int(0)); // zoom
                try item_dict.put("Dest", .{ .array_val = &dest_array });

                try w.writeDict(item_dict);
                try w.endObject();
            }
        }

        // Write page labels if present
        if (page_labels_id) |labels_id| {
            try w.beginObject(labels_id);
            var labels_dict = Dict.init(self.allocator);
            defer labels_dict.deinit();

            // Build /Nums array: [page_index1 dict1 page_index2 dict2 ...]
            var nums_array = Array.init(self.allocator);
            defer nums_array.deinit();

            // Store label dicts to keep them in scope
            var label_dicts = try self.allocator.alloc(Dict, self.page_labels.items.len);
            defer {
                for (label_dicts) |*ld| ld.deinit();
                self.allocator.free(label_dicts);
            }

            for (self.page_labels.items, 0..) |entry, i| {
                try nums_array.append(Value.int(@intCast(entry.page_index)));

                // Build label dictionary
                label_dicts[i] = Dict.init(self.allocator);
                const label = entry.label;

                // /S - numbering style
                if (label.style.pdfCode()) |code| {
                    try label_dicts[i].put("S", Value.name(code));
                }

                // /P - prefix
                if (label.prefix) |prefix| {
                    try label_dicts[i].put("P", Value.string(prefix));
                }

                // /St - starting number (only if not 1)
                if (label.start != 1) {
                    try label_dicts[i].put("St", Value.int(@intCast(label.start)));
                }

                try nums_array.append(.{ .dict_val = &label_dicts[i] });
            }

            try labels_dict.put("Nums", .{ .array_val = &nums_array });
            try w.writeDict(labels_dict);
            try w.endObject();
        }

        // Finish with xref and trailer
        const finish_start = std.time.milliTimestamp();
        const result = try w.finish(.{
            .catalog_ref = .{ .id = catalog_id },
            .info_ref = if (info_id) |id| .{ .id = id } else null,
        });
        last_output_timing.finish_ms = std.time.milliTimestamp() - finish_start;
        return result;
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Format current UTC time as PDF date string: D:YYYYMMDDHHmmSSZ
/// Returns a slice into the provided buffer.
fn formatPdfDate(buf: *[24]u8) []const u8 {
    const timestamp = std.time.timestamp();
    const epoch_secs: u64 = @intCast(timestamp);
    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch.getDaySeconds();

    _ = std.fmt.bufPrint(buf, "D:{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch unreachable;

    return buf[0..17]; // "D:YYYYMMDDHHmmSSZ"
}

/// Strip soft-hyphens (U+00AD) from text.
/// Soft-hyphens are invisible formatting characters that only appear as visible
/// hyphens when text breaks at that point. Returns allocated copy without soft-hyphens.
fn stripSoftHyphens(allocator: std.mem.Allocator, str: []const u8) ![]u8 {
    // Fast path: check if any soft-hyphens exist (0xC2 0xAD in UTF-8)
    // Most strings don't have soft-hyphens, so avoid the byte-by-byte scan
    if (std.mem.indexOf(u8, str, "\xC2\xAD") == null) {
        return allocator.dupe(u8, str);
    }

    // Slow path: count non-soft-hyphen bytes
    var count: usize = 0;
    var i: usize = 0;
    while (i < str.len) {
        if (i + 1 < str.len and str[i] == 0xC2 and str[i + 1] == 0xAD) {
            i += 2; // Skip soft-hyphen
        } else {
            count += 1;
            i += 1;
        }
    }

    // Copy without soft-hyphens
    const result = try allocator.alloc(u8, count);
    var j: usize = 0;
    i = 0;
    while (i < str.len) {
        if (i + 1 < str.len and str[i] == 0xC2 and str[i + 1] == 0xAD) {
            i += 2; // Skip soft-hyphen
        } else {
            result[j] = str[i];
            j += 1;
            i += 1;
        }
    }
    return result;
}

/// Strip soft-hyphens to a provided buffer. Returns slice of buffer used.
fn stripSoftHyphensTo(str: []const u8, buf: []u8) []const u8 {
    // Fast path: no soft-hyphens
    if (std.mem.indexOf(u8, str, "\xC2\xAD") == null) {
        const len = @min(str.len, buf.len);
        @memcpy(buf[0..len], str[0..len]);
        return buf[0..len];
    }

    // Strip soft-hyphens
    var j: usize = 0;
    var i: usize = 0;
    while (i < str.len and j < buf.len) {
        if (i + 1 < str.len and str[i] == 0xC2 and str[i + 1] == 0xAD) {
            i += 2; // Skip soft-hyphen
        } else {
            buf[j] = str[i];
            j += 1;
            i += 1;
        }
    }
    return buf[0..j];
}

/// Check if text contains any soft-hyphens.
fn containsSoftHyphens(str: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < str.len) : (i += 1) {
        if (str[i] == 0xC2 and str[i + 1] == 0xAD) {
            return true;
        }
    }
    return false;
}
